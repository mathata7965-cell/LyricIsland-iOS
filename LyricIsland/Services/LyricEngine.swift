import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
final class LyricEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = LyricEngine()

    @Published var sourceMode: PlaybackSourceMode = .spotify
    @Published var currentTrack: LyricTrack?
    @Published var currentArtwork: UIImage?
    @Published var accentColorRGB: (red: Double, green: Double, blue: Double) = ArtworkAppearance.defaultAccent
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var activeLineIndex: Int?
    @Published var syncOffset: TimeInterval = 0
    @Published var isIslandEnabled: Bool = false
    @Published var displayStyle: IslandDisplayStyle = .compactLyrics
    @Published var isBackgroundKeepAliveEnabled: Bool = true
    @Published var appleMusicAuthStatus: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()
    @Published var isFetchingLyrics: Bool = false
    @Published var statusToast: String?
    @Published var localTracks: [LyricTrack] = []
    @Published var isSystemBridgeActive: Bool = false

    let pipManager = PiPLyricOverlayManager()
    let spotifyService = SpotifySyncService.shared

    private let keepAliveService = BackgroundKeepAliveService()
    private let activityCoordinator = LiveActivityCoordinator()
    private let systemPlayer = MPMusicPlayerController.systemMusicPlayer
    private let mediaBridge = SystemMediaRemoteBridge.shared

    private var localAudioPlayer: AVAudioPlayer?
    private var tickerTimer: Timer?
    private var spotifyPollTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var lyricsFetchTask: Task<Void, Never>?
    private var activityPushTask: Task<Void, Never>?

    private var cachedThumbData: Data?
    private var lastObservedSystemPersistentID: MPMediaEntityPersistentID = 0
    private var lastObservedExternalTrackKey: String = ""

    private var companionAnchorDate: Date?
    private var companionAnchorElapsed: TimeInterval = 0

    private var spotifyAnchorDate: Date?
    private var spotifyAnchorElapsed: TimeInterval = 0
    private var lastSpotifyRateLimitUntil: Date = .distantPast

    private var observers: [NSObjectProtocol] = []

    private enum DefaultsKey {
        static let displayStyle = "lyricisland.displayStyle"
        static let keepAlive = "lyricisland.keepAlive"
        static let sourceMode = "lyricisland.sourceMode"
    }

    private struct LocalTrackManifestEntry: Codable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let audioFileName: String
        let lrcFileName: String?
    }

    private var localLibraryDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("LyricIslandLibrary", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var manifestURL: URL {
        localLibraryDir.appendingPathComponent("library.json")
    }

    private override init() {
        super.init()
        loadPreferences()
        loadSavedLocalTracks()
        wirePiPCallbacks()
        activityCoordinator.restoreExistingIfAny()
        isIslandEnabled = activityCoordinator.hasActiveActivity
        setupSystemMusicObserver()
        startTicker()

        if sourceMode == .appleMusic {
            refreshAppleMusicIfAuthorized(autoPrompt: false)
        } else if sourceMode == .spotify {
            startSpotifyOrBridgeSyncLoop()
        }
        pushPiPFrame()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        spotifyPollTask?.cancel()
    }

    private func wirePiPCallbacks() {
        pipManager.onTogglePlayTapped = { [weak self] in
            self?.togglePlayPause()
        }
        pipManager.onSkipBackwardTapped = { [weak self] in
            guard let self else { return }
            self.nudgeOffset(by: -0.5)
            self.pipManager.showTransientBadge(String(format: "偏移 %+.1fs", self.syncOffset))
        }
        pipManager.onSkipForwardTapped = { [weak self] in
            guard let self else { return }
            self.nudgeOffset(by: 0.5)
            self.pipManager.showTransientBadge(String(format: "偏移 %+.1fs", self.syncOffset))
        }
    }

    // MARK: - Preferences

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let rawStyle = defaults.string(forKey: DefaultsKey.displayStyle),
           let parsed = IslandDisplayStyle(rawValue: rawStyle) {
            displayStyle = parsed
        }
        if defaults.object(forKey: DefaultsKey.keepAlive) != nil {
            isBackgroundKeepAliveEnabled = defaults.bool(forKey: DefaultsKey.keepAlive)
        }
        if let rawSource = defaults.string(forKey: DefaultsKey.sourceMode),
           let parsedSource = PlaybackSourceMode(rawValue: rawSource) {
            sourceMode = parsedSource
        }
    }

    func setDisplayStyle(_ style: IslandDisplayStyle) {
        displayStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: DefaultsKey.displayStyle)
        pushOutputs(forceRestartIsland: false)
    }

    func setBackgroundKeepAlive(_ enabled: Bool) {
        isBackgroundKeepAliveEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.keepAlive)
        updateKeepAliveState()
    }

    func switchSourceMode(_ mode: PlaybackSourceMode) {
        if mode == sourceMode { return }
        stopLocalAudioIfNeeded()
        spotifyPollTask?.cancel()
        if mode != .companion {
            companionAnchorDate = nil
        }
        if mode != .spotify {
            spotifyAnchorDate = nil
        }

        sourceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.sourceMode)

        switch mode {
        case .spotify:
            lastObservedExternalTrackKey = ""
            startSpotifyOrBridgeSyncLoop()
        case .appleMusic:
            lastObservedSystemPersistentID = 0
            refreshAppleMusicIfAuthorized(autoPrompt: true)
        case .companion:
            isPlaying = false
            updateKeepAliveState()
            if currentTrack == nil {
                loadQuickTestSample(autoplay: false)
            } else {
                currentTrack?.sourceLabel = PlaybackSourceMode.companion.shortBadge
                companionAnchorElapsed = currentTime
                pushOutputs(forceRestartIsland: false)
            }
        case .localAudio:
            isPlaying = false
            updateKeepAliveState()
            if let firstLocal = localTracks.first {
                playLocalTrack(firstLocal, autoplay: false)
            } else {
                showToast("請點左下「搜詞或匯入」加入本機音訊檔案")
            }
        }
    }

    // MARK: - Live Activity & PiP Floating Controls

    func toggleDynamicIsland() {
        if isIslandEnabled {
            disableDynamicIsland()
        } else {
            enableDynamicIsland()
        }
    }

    func enableDynamicIsland() {
        ensurePlayableContentIfNeeded(autoplayCompanion: true)
        isIslandEnabled = true
        updateKeepAliveState()
        pushOutputs(forceRestartIsland: true)
    }

    func disableDynamicIsland() {
        isIslandEnabled = false
        updateKeepAliveState()
        Task {
            await activityCoordinator.endAll()
        }
    }

    func toggleFloatingPiP() {
        if !pipManager.isPiPActive {
            ensurePlayableContentIfNeeded(autoplayCompanion: true)
        }
        pipManager.togglePiP()
        updateKeepAliveState()
        pushPiPFrame()
    }

    private func ensurePlayableContentIfNeeded(autoplayCompanion: Bool) {
        if currentTrack == nil {
            if sourceMode == .spotify && spotifyService.isConnected {
                Task { await pollSpotifyAndMediaRemoteOnce() }
            } else {
                loadQuickTestSample(autoplay: true)
            }
            return
        }
        if autoplayCompanion && !isPlaying && (sourceMode == .companion || (sourceMode == .spotify && !spotifyService.isConnected && !isSystemBridgeActive)) {
            if currentTime >= max(duration - 0.3, 0) {
                currentTime = 0
            }
            companionAnchorElapsed = currentTime
            companionAnchorDate = Date()
            isPlaying = true
            recomputeActiveLine()
        }
    }

    func handleLiveCommand(_ command: LyricLiveCommand) {
        switch command {
        case .togglePlay:
            togglePlayPause()
        case .previous:
            skipPrevious()
        case .next:
            skipNext()
        case .nudgeBackward:
            nudgeOffset(by: -0.5)
        case .nudgeForward:
            nudgeOffset(by: 0.5)
        }
    }

    // MARK: - Deep Link URL Scheme (`lyricisland://`)

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "lyricisland" else { return }
        let host = (url.host ?? "").lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func param(_ name: String) -> String? {
            queryItems.first(where: { $0.name.lowercased() == name })?.value
        }

        switch host {
        case "spotify-callback":
            Task {
                do {
                    try await spotifyService.handleCallbackURL(url)
                    sourceMode = .spotify
                    startSpotifyOrBridgeSyncLoop()
                    showToast("Spotify 帳號已連線")
                } catch {
                    showToast(error.localizedDescription)
                }
            }
        case "start":
            enableDynamicIsland()
        case "pip":
            if !pipManager.isPiPActive { toggleFloatingPiP() }
        case "stop":
            disableDynamicIsland()
            pipManager.stopPiP()
        case "sync", "search":
            let q = param("q") ?? [param("artist"), param("title")].compactMap { $0 }.joined(separator: " ")
            let autoplay = param("autoplay") != "0"
            guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                enableDynamicIsland()
                return
            }
            Task {
                await resolveAndLoadQuery(q, autoplay: autoplay, activateIsland: true)
            }
        default:
            break
        }
    }

    // MARK: - Spotify Sync (Web API + MediaRemote + Share Links)

    func connectSpotify(clientId: String) async throws {
        try await spotifyService.authorize(clientId: clientId)
        sourceMode = .spotify
        UserDefaults.standard.set(PlaybackSourceMode.spotify.rawValue, forKey: DefaultsKey.sourceMode)
        lastObservedExternalTrackKey = ""
        startSpotifyOrBridgeSyncLoop()
        showToast("已連結 Spotify，正在同步曲目…")
    }

    func disconnectSpotify() {
        spotifyService.disconnect()
        spotifyAnchorDate = nil
        showToast("已登出 Spotify")
    }

    func importSpotifyShareLink(_ rawInput: String, activatePiP: Bool = false) {
        Task {
            isFetchingLyrics = true
            defer { isFetchingLyrics = false }
            guard let meta = await spotifyService.resolveShareLink(rawInput) else {
                showToast("無法解析此 Spotify 連結，請確認為單曲分享連結")
                return
            }
            let query = [meta.artist, meta.title].filter { !$0.isEmpty }.joined(separator: " ")
            let results = await LyricsLookupService.shared.searchInteractive(query: query)
            if var best = results.first {
                if best.artworkURL == nil { best.artworkURL = meta.artworkURL }
                loadSearchCandidate(best, autoplay: true, activateIsland: true, activatePiP: activatePiP)
                showToast("已載入 Spotify 曲目：\(best.trackName)")
            } else {
                showToast("已辨識「\(meta.title)」，但 LRCLIB 尚無時間軸歌詞")
            }
        }
    }

    private func startSpotifyOrBridgeSyncLoop() {
        spotifyPollTask?.cancel()
        spotifyPollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.sourceMode == .spotify {
                await self.pollSpotifyAndMediaRemoteOnce()
                let intervalNs: UInt64 = self.isPlaying ? 1_800_000_000 : 3_200_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    func pollSpotifyAndMediaRemoteOnce() async {
        // 1. Prefer Spotify Web API when authenticated (accurate millisecond sync)
        if spotifyService.isConnected, Date() >= lastSpotifyRateLimitUntil {
            let result = await spotifyService.pollCurrentlyPlaying()
            switch result {
            case .playing(let snap):
                applySpotifySnapshot(snap)
                return
            case .nothingPlaying:
                if currentTrack?.id.hasPrefix("sp-") == true {
                    isPlaying = false
                    spotifyAnchorDate = nil
                    updateKeepAliveState()
                    pushOutputs(forceRestartIsland: false)
                }
            case .rateLimited(let retryAfter):
                lastSpotifyRateLimitUntil = Date().addingTimeInterval(retryAfter)
            case .unauthorized, .failed:
                break
            }
        }

        // 2. Fallback: System MediaRemote dynamic probe (works on TrollStore / unsandboxed runtimes)
        if mediaBridge.isSupportedBinaryLoaded,
           let sysSnap = await mediaBridge.fetchNowPlayingInfo() {
            isSystemBridgeActive = true
            applySystemBridgeSnapshot(sysSnap)
        } else {
            isSystemBridgeActive = false
        }
    }

    private func applySpotifySnapshot(_ snap: SpotifyPlaybackSnapshot) {
        let trackKey = "sp-\(snap.trackId)"
        let elapsedSinceCapture = snap.isPlaying ? max(0, Date().timeIntervalSince(snap.capturedAt)) : 0
        let liveProgress = min(snap.progress + elapsedSinceCapture, snap.duration)

        if trackKey != lastObservedExternalTrackKey {
            lastObservedExternalTrackKey = trackKey
            duration = snap.duration
            currentTime = liveProgress
            spotifyAnchorElapsed = liveProgress
            spotifyAnchorDate = snap.isPlaying ? Date() : nil
            isPlaying = snap.isPlaying
            syncOffset = 0

            currentTrack = LyricTrack(
                id: trackKey,
                title: snap.title,
                artist: snap.artist,
                album: snap.album,
                duration: snap.duration,
                lines: [],
                hasTimestamps: false,
                artworkURL: snap.artworkURL,
                localAudioURL: nil,
                sourceLabel: "Spotify"
            )
            applyArtworkImage(nil)
            if let artURL = snap.artworkURL {
                loadRemoteArtwork(from: artURL)
            }
            recomputeActiveLine()
            updateKeepAliveState()
            pushOutputs(forceRestartIsland: false)

            lyricsFetchTask?.cancel()
            lyricsFetchTask = Task {
                isFetchingLyrics = true
                let fetched = await LyricsLookupService.shared.autoFetchSyncedLyrics(
                    title: snap.title,
                    artist: snap.artist,
                    duration: snap.duration
                )
                guard !Task.isCancelled else { return }
                isFetchingLyrics = false
                if let fetched {
                    let parsed = LRCParser.parse(fetched.lrc)
                    if var track = currentTrack, track.id == trackKey {
                        track.lines = parsed.lines
                        track.hasTimestamps = parsed.hasTimestamps
                        currentTrack = track
                        recomputeActiveLine()
                        pushOutputs(forceRestartIsland: false)
                    }
                }
            }
        } else {
            duration = snap.duration
            let predicted = spotifyAnchorDate.map { spotifyAnchorElapsed + Date().timeIntervalSince($0) } ?? currentTime
            if abs(predicted - liveProgress) > 0.7 || snap.isPlaying != isPlaying {
                currentTime = liveProgress
                spotifyAnchorElapsed = liveProgress
                spotifyAnchorDate = snap.isPlaying ? Date() : nil
            }
            if snap.isPlaying != isPlaying {
                isPlaying = snap.isPlaying
                updateKeepAliveState()
            }
            recomputeActiveLine()
            pushOutputs(forceRestartIsland: false)
        }
    }

    private func applySystemBridgeSnapshot(_ snap: SystemNowPlayingSnapshot) {
        let trackKey = "mr-\(snap.title)-\(snap.artist)"
        if trackKey != lastObservedExternalTrackKey {
            lastObservedExternalTrackKey = trackKey
            duration = snap.duration
            currentTime = snap.elapsedTime
            spotifyAnchorElapsed = snap.elapsedTime
            spotifyAnchorDate = snap.isPlaying ? Date() : nil
            isPlaying = snap.isPlaying
            syncOffset = 0

            currentTrack = LyricTrack(
                id: trackKey,
                title: snap.title,
                artist: snap.artist,
                album: snap.album,
                duration: snap.duration,
                lines: [],
                hasTimestamps: false,
                artworkURL: nil,
                localAudioURL: nil,
                sourceLabel: "Spotify"
            )

            if let data = snap.artworkData, let img = UIImage(data: data) {
                applyArtworkImage(img)
            } else {
                applyArtworkImage(nil)
            }

            recomputeActiveLine()
            updateKeepAliveState()
            pushOutputs(forceRestartIsland: false)

            lyricsFetchTask?.cancel()
            lyricsFetchTask = Task {
                isFetchingLyrics = true
                let fetched = await LyricsLookupService.shared.autoFetchSyncedLyrics(
                    title: snap.title,
                    artist: snap.artist,
                    duration: snap.duration
                )
                guard !Task.isCancelled else { return }
                isFetchingLyrics = false
                if let fetched {
                    let parsed = LRCParser.parse(fetched.lrc)
                    if var track = currentTrack, track.id == trackKey {
                        track.lines = parsed.lines
                        track.hasTimestamps = parsed.hasTimestamps
                        currentTrack = track
                        recomputeActiveLine()
                        pushOutputs(forceRestartIsland: false)
                    }
                    if currentArtwork == nil, let artURL = fetched.artworkURL {
                        loadRemoteArtwork(from: artURL)
                    }
                }
            }
        } else {
            let predicted = spotifyAnchorDate.map { spotifyAnchorElapsed + Date().timeIntervalSince($0) } ?? currentTime
            if abs(predicted - snap.elapsedTime) > 0.7 || snap.isPlaying != isPlaying {
                currentTime = snap.elapsedTime
                spotifyAnchorElapsed = snap.elapsedTime
                spotifyAnchorDate = snap.isPlaying ? Date() : nil
            }
            if snap.isPlaying != isPlaying {
                isPlaying = snap.isPlaying
                updateKeepAliveState()
            }
            recomputeActiveLine()
            pushOutputs(forceRestartIsland: false)
        }
    }

    // MARK: - Transport Controls

    func togglePlayPause() {
        switch sourceMode {
        case .spotify:
            if spotifyService.isConnected {
                let targetPlaying = !isPlaying
                isPlaying = targetPlaying
                spotifyAnchorElapsed = currentTime
                spotifyAnchorDate = targetPlaying ? Date() : nil
                Task {
                    let ok = await spotifyService.sendPlaybackAction(targetPlaying ? "play" : "pause")
                    if !ok {
                        showToast("Spotify 裝置播放控制需 Spotify Premium 或直接於 Spotify 內操作")
                    }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await pollSpotifyAndMediaRemoteOnce()
                }
            } else if isSystemBridgeActive {
                mediaBridge.sendCommand(.togglePlayPause)
                isPlaying.toggle()
                spotifyAnchorElapsed = currentTime
                spotifyAnchorDate = isPlaying ? Date() : nil
            } else {
                toggleCompanionTimer()
            }
        case .appleMusic:
            if systemPlayer.playbackState == .playing {
                systemPlayer.pause()
                isPlaying = false
            } else {
                systemPlayer.play()
                isPlaying = true
            }
        case .companion:
            toggleCompanionTimer()
        case .localAudio:
            guard let player = localAudioPlayer else {
                if let track = currentTrack, track.localAudioURL != nil {
                    playLocalTrack(track, autoplay: true)
                }
                return
            }
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                configureSoloAudioSession()
                player.play()
                isPlaying = true
            }
        }
        recomputeActiveLine()
        updateKeepAliveState()
        pushOutputs(forceRestartIsland: false)
    }

    private func toggleCompanionTimer() {
        if currentTrack == nil {
            loadQuickTestSample(autoplay: true)
            return
        }
        if isPlaying {
            commitCompanionTime()
            isPlaying = false
            companionAnchorDate = nil
        } else {
            if currentTime >= max(duration - 0.3, 0) {
                currentTime = 0
            }
            companionAnchorElapsed = currentTime
            companionAnchorDate = Date()
            isPlaying = true
        }
    }

    func seek(to targetTime: TimeInterval) {
        let clamped = min(max(targetTime, 0), max(duration, 1))
        currentTime = clamped

        switch sourceMode {
        case .spotify:
            if spotifyService.isConnected {
                spotifyAnchorElapsed = clamped
                if isPlaying { spotifyAnchorDate = Date() }
                let ms = Int(clamped * 1000)
                Task {
                    _ = await spotifyService.sendPlaybackAction("seek", queryItems: [URLQueryItem(name: "position_ms", value: String(ms))])
                }
            } else {
                companionAnchorElapsed = clamped
                if isPlaying { companionAnchorDate = Date() }
            }
        case .appleMusic:
            systemPlayer.currentPlaybackTime = clamped
        case .companion:
            companionAnchorElapsed = clamped
            if isPlaying { companionAnchorDate = Date() }
        case .localAudio:
            localAudioPlayer?.currentTime = clamped
        }

        recomputeActiveLine()
        pushOutputs(forceRestartIsland: false)
    }

    func jumpToLine(_ line: LyricLine) {
        if let track = currentTrack, !track.hasTimestamps {
            if let idx = track.lines.firstIndex(where: { $0.id == line.id }) {
                activeLineIndex = idx
                currentTime = line.time
                pushOutputs(forceRestartIsland: false)
            }
            return
        }
        let target = max(0, line.time - syncOffset)
        seek(to: target)
    }

    func anchorLineToCurrentMoment(_ line: LyricLine) {
        guard let track = currentTrack, track.hasTimestamps else { return }
        syncOffset = line.time - currentTime
        recomputeActiveLine()
        pushOutputs(forceRestartIsland: false)
        showToast(String(format: "已對準這一句（偏移 %+.1fs）", syncOffset))
    }

    func nudgeOffset(by delta: TimeInterval) {
        syncOffset = max(-15, min(15, syncOffset + delta))
        recomputeActiveLine()
        pushOutputs(forceRestartIsland: false)
    }

    func resetOffset() {
        syncOffset = 0
        recomputeActiveLine()
        pushOutputs(forceRestartIsland: false)
    }

    func skipPrevious() {
        switch sourceMode {
        case .spotify:
            if spotifyService.isConnected {
                Task {
                    _ = await spotifyService.sendPlaybackAction("previous", method: "POST")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await pollSpotifyAndMediaRemoteOnce()
                }
            } else if isSystemBridgeActive {
                mediaBridge.sendCommand(.previousTrack)
            } else {
                stepLyricLine(delta: -1)
            }
        case .appleMusic:
            if currentTime > 4 {
                seek(to: 0)
            } else {
                systemPlayer.skipToPreviousItem()
            }
        case .companion:
            stepLyricLine(delta: -1)
        case .localAudio:
            if let current = currentTrack,
               let idx = localTracks.firstIndex(where: { $0.id == current.id }),
               currentTime <= 3,
               localTracks.count > 1 {
                let prevIdx = (idx - 1 + localTracks.count) % localTracks.count
                playLocalTrack(localTracks[prevIdx], autoplay: isPlaying)
            } else {
                stepLyricLine(delta: -1)
            }
        }
    }

    func skipNext() {
        switch sourceMode {
        case .spotify:
            if spotifyService.isConnected {
                Task {
                    _ = await spotifyService.sendPlaybackAction("next", method: "POST")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await pollSpotifyAndMediaRemoteOnce()
                }
            } else if isSystemBridgeActive {
                mediaBridge.sendCommand(.nextTrack)
            } else {
                stepLyricLine(delta: 1)
            }
        case .appleMusic:
            systemPlayer.skipToNextItem()
        case .companion:
            stepLyricLine(delta: 1)
        case .localAudio:
            if let current = currentTrack,
               let idx = localTracks.firstIndex(where: { $0.id == current.id }),
               localTracks.count > 1 {
                let nextIdx = (idx + 1) % localTracks.count
                playLocalTrack(localTracks[nextIdx], autoplay: isPlaying)
            } else {
                stepLyricLine(delta: 1)
            }
        }
    }

    private func stepLyricLine(delta: Int) {
        guard let track = currentTrack, !track.lines.isEmpty else { return }
        let currentIdx = activeLineIndex ?? (delta > 0 ? -1 : 0)
        let targetIdx = min(max(currentIdx + delta, 0), track.lines.count - 1)
        jumpToLine(track.lines[targetIdx])
    }

    // MARK: - Loading Tracks & Lyrics

    func resolveAndLoadQuery(_ query: String, autoplay: Bool, activateIsland: Bool) async {
        isFetchingLyrics = true
        let results = await LyricsLookupService.shared.searchInteractive(query: query)
        isFetchingLyrics = false
        if let best = results.first {
            loadSearchCandidate(best, autoplay: autoplay, activateIsland: activateIsland)
        } else {
            showToast("找不到相符歌詞：\(query)")
        }
    }

    func loadSearchCandidate(
        _ candidate: LRCSearchCandidate,
        autoplay: Bool,
        activateIsland: Bool = false,
        activatePiP: Bool = false
    ) {
        stopLocalAudioIfNeeded()
        spotifyPollTask?.cancel()
        if sourceMode != .companion {
            sourceMode = .companion
            UserDefaults.standard.set(PlaybackSourceMode.companion.rawValue, forKey: DefaultsKey.sourceMode)
        }

        let rawLyrics = candidate.syncedLyrics ?? candidate.plainLyrics ?? ""
        let parsed = LRCParser.parse(rawLyrics)
        let effectiveDuration = max(candidate.duration, (parsed.lines.last?.time ?? 0) + 12, 180)

        let track = LyricTrack(
            id: "lrclib-\(candidate.id)",
            title: candidate.trackName,
            artist: candidate.artistName,
            album: candidate.albumName,
            duration: effectiveDuration,
            lines: parsed.lines,
            hasTimestamps: parsed.hasTimestamps,
            artworkURL: candidate.artworkURL,
            localAudioURL: nil,
            sourceLabel: PlaybackSourceMode.companion.shortBadge
        )

        syncOffset = 0
        currentTrack = track
        duration = effectiveDuration
        currentTime = 0
        companionAnchorElapsed = 0
        companionAnchorDate = autoplay ? Date() : nil
        isPlaying = autoplay
        activeLineIndex = LRCParser.activeLineIndex(in: track.lines, at: 0)

        if let url = candidate.artworkURL {
            loadRemoteArtwork(from: url)
        } else {
            applyArtworkImage(nil)
        }

        if activateIsland { isIslandEnabled = true }
        if activatePiP { pipManager.startPiP() }
        updateKeepAliveState()
        pushOutputs(forceRestartIsland: activateIsland)
    }

    func applyCustomLyrics(_ rawText: String, title: String? = nil, artist: String? = nil) {
        let parsed = LRCParser.parse(rawText)
        guard !parsed.lines.isEmpty else {
            showToast("歌詞內容為空，請確認格式")
            return
        }

        let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? parsed.titleTag ?? currentTrack?.title ?? "自訂歌詞"
        let resolvedArtist = (artist?.isEmpty == false ? artist : nil) ?? parsed.artistTag ?? currentTrack?.artist ?? ""

        if var existing = currentTrack {
            existing.lines = parsed.lines
            existing.hasTimestamps = parsed.hasTimestamps
            if title?.isEmpty == false { existing.title = resolvedTitle }
            if artist?.isEmpty == false { existing.artist = resolvedArtist }
            currentTrack = existing
            Task {
                await LyricsLookupService.shared.saveCachedLyrics(rawText, title: existing.title, artist: existing.artist)
            }
        } else {
            sourceMode = .companion
            let estDuration = max((parsed.lines.last?.time ?? 0) + 15, 180)
            currentTrack = LyricTrack(
                id: "custom-\(UUID().uuidString)",
                title: resolvedTitle,
                artist: resolvedArtist,
                album: parsed.albumTag ?? "",
                duration: estDuration,
                lines: parsed.lines,
                hasTimestamps: parsed.hasTimestamps,
                artworkURL: nil,
                localAudioURL: nil,
                sourceLabel: PlaybackSourceMode.companion.shortBadge
            )
            duration = estDuration
            currentTime = 0
            companionAnchorElapsed = 0
            isPlaying = false
        }

        syncOffset = 0
        recomputeActiveLine()
        pushOutputs(forceRestartIsland: false)
        showToast(parsed.hasTimestamps ? "已載入 \(parsed.lines.count) 句時間軸歌詞" : "已載入 \(parsed.lines.count) 句純文字歌詞")
    }

    func loadQuickTestSample(autoplay: Bool = true) {
        stopLocalAudioIfNeeded()
        spotifyPollTask?.cancel()
        sourceMode = .companion
        UserDefaults.standard.set(PlaybackSourceMode.companion.rawValue, forKey: DefaultsKey.sourceMode)

        let sampleLRC = """
        [00:00.00]靈動歌詞已就緒
        [00:00.00]開啟「懸浮歌詞」即可直接疊加在 Spotify 上方
        [00:03.20]支援 Spotify 帳號直連與分享連結秒抓詞
        [00:06.80]同時支援 Apple Music 原生時間軸自動同步
        [00:10.50]鎖定畫面與靈動島長按皆可控制播放與對軸
        [00:14.20]輕點懸浮窗前進後退鍵可直接微調 ±0.5 秒
        [00:18.00]雙語 LRC 時間軸將會自動疊合翻譯行
        [00:22.00]點左下角搜尋任意歌曲或匯入本機 .lrc 與音訊
        [00:26.50]輕觸歌詞任意一行即可立刻跳轉同步位置
        """
        let parsed = LRCParser.parse(sampleLRC)
        currentTrack = LyricTrack(
            id: "sample-test",
            title: "靈動島同步測試",
            artist: "詞島 · LyricIsland",
            album: "即時動態示範",
            duration: 32,
            lines: parsed.lines,
            hasTimestamps: true,
            artworkURL: nil,
            localAudioURL: nil,
            sourceLabel: "即時測試"
        )
        applyArtworkImage(nil)
        syncOffset = 0
        duration = 32
        currentTime = 0
        companionAnchorElapsed = 0
        companionAnchorDate = autoplay ? Date() : nil
        isPlaying = autoplay
        activeLineIndex = 0
        updateKeepAliveState()
        pushOutputs(forceRestartIsland: false)
    }

    // MARK: - File Import (Audio & LRC)

    func importFiles(urls: [URL]) {
        Task {
            var importedAudioURLs: [URL] = []
            var importedLRCURLs: [URL] = []

            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }

                let ext = url.pathExtension.lowercased()
                let destURL = uniqueDestinationURL(for: url.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: url, to: destURL)
                    if ["lrc", "txt"].contains(ext) {
                        importedLRCURLs.append(destURL)
                    } else {
                        importedAudioURLs.append(destURL)
                    }
                } catch {
                    showToast("匯入失敗：\(error.localizedDescription)")
                }
            }

            if !importedAudioURLs.isEmpty {
                for audioURL in importedAudioURLs {
                    let stem = audioURL.deletingPathExtension().lastPathComponent
                    let matchingLRC = importedLRCURLs.first {
                        $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
                    }
                    await registerLocalAudio(audioURL, pairedLRCURL: matchingLRC)
                }
                if let latest = localTracks.last {
                    playLocalTrack(latest, autoplay: true)
                }
            } else if let lrcURL = importedLRCURLs.first,
                      let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                applyCustomLyrics(raw)
            }
        }
    }

    private func registerLocalAudio(_ audioURL: URL, pairedLRCURL: URL?) async {
        let asset = AVURLAsset(url: audioURL)
        var title = audioURL.deletingPathExtension().lastPathComponent
        var artist = "本機音訊"
        var album = ""
        var assetDuration: TimeInterval = 0
        var embeddedArtwork: UIImage?
        var embeddedLyrics: String?

        if let dur = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(dur)
            if secs.isFinite && secs > 0 { assetDuration = secs }
        }
        if let meta = try? await asset.load(.commonMetadata) {
            for item in meta {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                case .commonKeyAlbumName:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { album = v }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue), let img = UIImage(data: data) {
                        embeddedArtwork = img
                    }
                default:
                    break
                }
            }
        }
        if let rawLyrics = try? await asset.load(.lyrics), !rawLyrics.isEmpty {
            embeddedLyrics = rawLyrics
        }

        var lrcContent: String?
        if let pairedLRCURL, let raw = try? String(contentsOf: pairedLRCURL, encoding: .utf8) {
            lrcContent = raw
        } else if let embeddedLyrics {
            lrcContent = embeddedLyrics
        } else if let fetched = await LyricsLookupService.shared.autoFetchSyncedLyrics(title: title, artist: artist == "本機音訊" ? "" : artist, duration: assetDuration) {
            lrcContent = fetched.lrc
        }

        let parsed = lrcContent.map { LRCParser.parse($0) }
        let trackID = "local-\(audioURL.lastPathComponent)"
        let track = LyricTrack(
            id: trackID,
            title: title,
            artist: artist,
            album: album,
            duration: max(assetDuration, 1),
            lines: parsed?.lines ?? [],
            hasTimestamps: parsed?.hasTimestamps ?? false,
            artworkURL: nil,
            localAudioURL: audioURL,
            sourceLabel: PlaybackSourceMode.localAudio.shortBadge
        )

        if let existingIdx = localTracks.firstIndex(where: { $0.id == trackID }) {
            localTracks[existingIdx] = track
        } else {
            localTracks.append(track)
        }
        if let embeddedArtwork {
            applyArtworkImage(embeddedArtwork)
        }
        persistLocalManifest(pairedLRCFileName: pairedLRCURL?.lastPathComponent, forTrackID: trackID, lrcContent: lrcContent)
    }

    func playLocalTrack(_ track: LyricTrack, autoplay: Bool) {
        guard let url = track.localAudioURL else { return }
        stopLocalAudioIfNeeded()
        spotifyPollTask?.cancel()
        sourceMode = .localAudio
        UserDefaults.standard.set(PlaybackSourceMode.localAudio.rawValue, forKey: DefaultsKey.sourceMode)
        companionAnchorDate = nil
        spotifyAnchorDate = nil

        do {
            configureSoloAudioSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            localAudioPlayer = player
            currentTrack = track
            duration = player.duration > 0 ? player.duration : track.duration
            currentTime = 0
            syncOffset = 0

            if autoplay {
                player.play()
                isPlaying = true
            } else {
                isPlaying = false
            }
            Task { await refreshEmbeddedArtwork(for: url) }
            recomputeActiveLine()
            updateKeepAliveState()
            pushOutputs(forceRestartIsland: false)
        } catch {
            showToast("無法播放音訊：\(error.localizedDescription)")
        }
    }

    private func refreshEmbeddedArtwork(for url: URL) async {
        let asset = AVURLAsset(url: url)
        var loadedImg: UIImage?
        if let meta = try? await asset.load(.commonMetadata) {
            for item in meta where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let img = UIImage(data: data) {
                    loadedImg = img
                    break
                }
            }
        }
        applyArtworkImage(loadedImg)
        pushOutputs(forceRestartIsland: false)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.sourceMode == .localAudio else { return }
            if self.localTracks.count > 1,
               let current = self.currentTrack,
               let idx = self.localTracks.firstIndex(where: { $0.id == current.id }) {
                let nextIdx = (idx + 1) % self.localTracks.count
                self.playLocalTrack(self.localTracks[nextIdx], autoplay: true)
            } else {
                self.isPlaying = false
                self.currentTime = 0
                self.recomputeActiveLine()
                self.pushOutputs(forceRestartIsland: false)
            }
        }
    }

    // MARK: - Apple Music Integration

    func requestAppleMusicAccess() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.appleMusicAuthStatus = status
                if status == .authorized {
                    self.sourceMode = .appleMusic
                    UserDefaults.standard.set(PlaybackSourceMode.appleMusic.rawValue, forKey: DefaultsKey.sourceMode)
                    self.lastObservedSystemPersistentID = 0
                    self.syncFromAppleMusic()
                } else {
                    self.showToast("未取得 Apple Music 權限，可切換至 Spotify 或伴侶對時模式")
                }
            }
        }
    }

    private func refreshAppleMusicIfAuthorized(autoPrompt: Bool) {
        let status = MPMediaLibrary.authorizationStatus()
        appleMusicAuthStatus = status
        if status == .authorized {
            syncFromAppleMusic()
        } else if status == .notDetermined && autoPrompt {
            requestAppleMusicAccess()
        }
    }

    private func setupSystemMusicObserver() {
        systemPlayer.beginGeneratingPlaybackNotifications()
        let itemObs = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: systemPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sourceMode == .appleMusic else { return }
                self.syncFromAppleMusic()
            }
        }
        let stateObs = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: systemPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sourceMode == .appleMusic else { return }
                self.syncAppleMusicPlaybackStateOnly()
            }
        }
        observers = [itemObs, stateObs]
    }

    private func syncAppleMusicPlaybackStateOnly() {
        let playing = (systemPlayer.playbackState == .playing)
        if isPlaying != playing {
            isPlaying = playing
            updateKeepAliveState()
        }
        let sysTime = systemPlayer.currentPlaybackTime
        if sysTime.isFinite && sysTime >= 0 {
            currentTime = sysTime
        }
        recomputeActiveLine()
        pushOutputs(forceRestartIsland: false)
    }

    private func syncFromAppleMusic() {
        guard appleMusicAuthStatus == .authorized else { return }
        guard let item = systemPlayer.nowPlayingItem else {
            if currentTrack?.id.hasPrefix("am-") == true {
                isPlaying = false
                updateKeepAliveState()
                pushOutputs(forceRestartIsland: false)
            }
            return
        }

        let pid = item.persistentID
        let playing = (systemPlayer.playbackState == .playing)
        let sysTime = systemPlayer.currentPlaybackTime
        if sysTime.isFinite && sysTime >= 0 {
            currentTime = sysTime
        }
        isPlaying = playing

        if pid == lastObservedSystemPersistentID && currentTrack?.id == "am-\(pid)" {
            recomputeActiveLine()
            updateKeepAliveState()
            pushOutputs(forceRestartIsland: false)
            return
        }

        lastObservedSystemPersistentID = pid
        let title = item.title ?? "未知曲目"
        let artist = item.artist ?? ""
        let album = item.albumTitle ?? ""
        let dur = max(item.playbackDuration, 1)

        duration = dur
        syncOffset = 0

        if let artworkImg = item.artwork?.image(at: CGSize(width: 320, height: 320)) {
            applyArtworkImage(artworkImg)
        } else {
            applyArtworkImage(nil)
        }

        var initialLines: [LyricLine] = []
        var initialHasTimestamps = false
        if let embedded = item.lyrics, !embedded.isEmpty {
            let parsed = LRCParser.parse(embedded)
            initialLines = parsed.lines
            initialHasTimestamps = parsed.hasTimestamps
        }

        currentTrack = LyricTrack(
            id: "am-\(pid)",
            title: title,
            artist: artist,
            album: album,
            duration: dur,
            lines: initialLines,
            hasTimestamps: initialHasTimestamps,
            artworkURL: nil,
            localAudioURL: nil,
            sourceLabel: PlaybackSourceMode.appleMusic.shortBadge
        )
        recomputeActiveLine()
        updateKeepAliveState()
        pushOutputs(forceRestartIsland: false)

        if !initialHasTimestamps {
            lyricsFetchTask?.cancel()
            lyricsFetchTask = Task {
                isFetchingLyrics = true
                let result = await LyricsLookupService.shared.autoFetchSyncedLyrics(
                    title: title,
                    artist: artist,
                    duration: dur
                )
                guard !Task.isCancelled else { return }
                isFetchingLyrics = false

                if let result {
                    let parsed = LRCParser.parse(result.lrc)
                    if var track = currentTrack, track.id == "am-\(pid)" {
                        track.lines = parsed.lines
                        track.hasTimestamps = parsed.hasTimestamps
                        track.artworkURL = result.artworkURL
                        currentTrack = track
                        recomputeActiveLine()
                        pushOutputs(forceRestartIsland: false)
                    }
                    if currentArtwork == nil, let artURL = result.artworkURL {
                        loadRemoteArtwork(from: artURL)
                    }
                }
            }
        }
    }

    // MARK: - Ticker & State Sync

    private func startTicker() {
        tickerTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickerTimer = timer
    }

    private func onTick() {
        switch sourceMode {
        case .spotify:
            if spotifyService.isConnected || isSystemBridgeActive {
                if isPlaying, let anchor = spotifyAnchorDate {
                    let elapsed = spotifyAnchorElapsed + Date().timeIntervalSince(anchor)
                    currentTime = duration > 0 ? min(elapsed, duration) : elapsed
                }
            } else {
                advanceCompanionClock()
            }
        case .appleMusic:
            guard appleMusicAuthStatus == .authorized else { return }
            let sysPlaying = (systemPlayer.playbackState == .playing)
            if sysPlaying != isPlaying {
                isPlaying = sysPlaying
                updateKeepAliveState()
                pushOutputs(forceRestartIsland: false)
            }
            if sysPlaying {
                let t = systemPlayer.currentPlaybackTime
                if t.isFinite && t >= 0 {
                    currentTime = t
                }
            }
        case .companion:
            advanceCompanionClock()
        case .localAudio:
            if let player = localAudioPlayer, player.isPlaying {
                currentTime = player.currentTime
            }
        }

        let prevActive = activeLineIndex
        recomputeActiveLine()
        if prevActive != activeLineIndex {
            pushOutputs(forceRestartIsland: false)
        } else if pipManager.isPiPActive && isPlaying {
            pushPiPFrame()
        }
    }

    private func advanceCompanionClock() {
        if isPlaying, let anchor = companionAnchorDate {
            let elapsed = companionAnchorElapsed + Date().timeIntervalSince(anchor)
            if duration > 0 && elapsed >= duration {
                currentTime = duration
                isPlaying = false
                companionAnchorDate = nil
                updateKeepAliveState()
                pushOutputs(forceRestartIsland: false)
            } else {
                currentTime = elapsed
            }
        }
    }

    private func recomputeActiveLine() {
        guard let track = currentTrack, !track.lines.isEmpty else {
            activeLineIndex = nil
            return
        }
        guard track.hasTimestamps else {
            if activeLineIndex == nil { activeLineIndex = 0 }
            return
        }
        activeLineIndex = LRCParser.activeLineIndex(in: track.lines, at: currentTime + syncOffset)
    }

    private func commitCompanionTime() {
        if let anchor = companionAnchorDate {
            currentTime = min(max(companionAnchorElapsed + Date().timeIntervalSince(anchor), 0), max(duration, 1))
            companionAnchorElapsed = currentTime
        }
    }

    // MARK: - Outputs (Dynamic Island Live Activity + PiP Floating Capsule)

    func buildCurrentContentState() -> LyricActivityAttributes.ContentState {
        let track = currentTrack
        let lines = track?.lines ?? []
        let idx = activeLineIndex

        let currentText: String
        let secondaryText: String
        let isTranslation: Bool

        if let idx, lines.indices.contains(idx) {
            let line = lines[idx]
            currentText = line.text
            if let tr = line.translation, !tr.isEmpty {
                secondaryText = tr
                isTranslation = true
            } else if lines.indices.contains(idx + 1) {
                secondaryText = lines[idx + 1].text
                isTranslation = false
            } else {
                secondaryText = ""
                isTranslation = false
            }
        } else if let first = lines.first {
            currentText = track?.title ?? "等待歌詞"
            secondaryText = first.text
            isTranslation = false
        } else {
            currentText = track?.title ?? "詞島已待機"
            secondaryText = isFetchingLyrics ? "正在匹配時間軸歌詞…" : "點此搜尋歌詞或連結 Spotify"
            isTranslation = false
        }

        return LyricActivityAttributes.ContentState(
            trackTitle: track?.title ?? "未載入曲目",
            artistName: track?.artist ?? "詞島 LyricIsland",
            currentLine: currentText,
            secondaryLine: secondaryText,
            isSecondaryTranslation: isTranslation,
            isPlaying: isPlaying,
            elapsedSeconds: currentTime,
            durationSeconds: max(duration, 1),
            referenceTimestamp: Date().timeIntervalSince1970,
            accentRed: accentColorRGB.red,
            accentGreen: accentColorRGB.green,
            accentBlue: accentColorRGB.blue,
            artworkThumb: cachedThumbData,
            sourceLabel: track?.sourceLabel ?? sourceMode.shortBadge,
            displayStyle: displayStyle,
            offsetSeconds: syncOffset
        )
    }

    private func pushOutputs(forceRestartIsland: Bool) {
        pushPiPFrame()
        if isIslandEnabled {
            pushLiveActivityUpdate(forceRestart: forceRestartIsland)
        }
    }

    private func pushPiPFrame() {
        let state = buildCurrentContentState()
        let showSecondary = !state.secondaryLine.isEmpty && (displayStyle != .compactLyrics || state.isSecondaryTranslation)
        pipManager.updateContent(
            trackTitle: state.trackTitle,
            artist: state.artistName,
            sourceLabel: state.sourceLabel,
            currentLine: state.currentLine,
            secondaryLine: showSecondary ? state.secondaryLine : "",
            artwork: currentArtwork,
            accentRGB: accentColorRGB,
            isPlaying: state.isPlaying,
            elapsed: state.elapsedSeconds,
            duration: state.durationSeconds
        )
    }

    private func pushLiveActivityUpdate(forceRestart: Bool) {
        guard isIslandEnabled else { return }
        let snapshot = buildCurrentContentState()
        activityPushTask?.cancel()
        activityPushTask = Task {
            if let errorMsg = await activityCoordinator.startOrUpdate(state: snapshot, forceRestart: forceRestart) {
                isIslandEnabled = false
                updateKeepAliveState()
                showToast(errorMsg)
            }
        }
    }

    // MARK: - Audio & Keep-Alive Management

    private func updateKeepAliveState() {
        let needsSilentKeepAlive = sourceMode != .localAudio && (
            (isIslandEnabled && isBackgroundKeepAliveEnabled && isPlaying) || pipManager.isPiPActive
        )
        keepAliveService.setKeepAliveActive(needsSilentKeepAlive)
    }

    private func configureSoloAudioSession() {
        keepAliveService.setKeepAliveActive(false)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch { }
    }

    private func stopLocalAudioIfNeeded() {
        localAudioPlayer?.stop()
        localAudioPlayer = nil
    }

    // MARK: - Artwork Helpers

    private func loadRemoteArtwork(from url: URL) {
        artworkTask?.cancel()
        artworkTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let img = UIImage(data: data) else { return }
                applyArtworkImage(img)
                pushOutputs(forceRestartIsland: false)
            } catch { }
        }
    }

    private func applyArtworkImage(_ image: UIImage?) {
        if let image {
            let appearance = ArtworkColorExtractor.process(image)
            currentArtwork = appearance.image
            cachedThumbData = appearance.thumbnailData
            accentColorRGB = (appearance.accentRed, appearance.accentGreen, appearance.accentBlue)
        } else {
            currentArtwork = nil
            cachedThumbData = nil
            accentColorRGB = ArtworkAppearance.defaultAccent
        }
    }

    // MARK: - Persistence & Toast

    private func uniqueDestinationURL(for fileName: String) -> URL {
        localLibraryDir.appendingPathComponent(fileName)
    }

    private func persistLocalManifest(pairedLRCFileName: String?, forTrackID trackID: String, lrcContent: String?) {
        if let lrcContent, let track = localTracks.first(where: { $0.id == trackID }) {
            Task {
                await LyricsLookupService.shared.saveCachedLyrics(lrcContent, title: track.title, artist: track.artist)
            }
        }
        let entries = localTracks.compactMap { track -> LocalTrackManifestEntry? in
            guard let audioURL = track.localAudioURL else { return nil }
            let lrcName = track.id == trackID ? pairedLRCFileName : nil
            return LocalTrackManifestEntry(
                id: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                audioFileName: audioURL.lastPathComponent,
                lrcFileName: lrcName
            )
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func loadSavedLocalTracks() {
        guard let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([LocalTrackManifestEntry].self, from: data) else {
            return
        }
        localTracks = entries.compactMap { entry in
            let audioURL = localLibraryDir.appendingPathComponent(entry.audioFileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
            return LyricTrack(
                id: entry.id,
                title: entry.title,
                artist: entry.artist,
                album: entry.album,
                duration: entry.duration,
                lines: [],
                hasTimestamps: false,
                artworkURL: nil,
                localAudioURL: audioURL,
                sourceLabel: PlaybackSourceMode.localAudio.shortBadge
            )
        }
        Task {
            for idx in localTracks.indices {
                let t = localTracks[idx]
                if let cached = await LyricsLookupService.shared.cachedLyrics(title: t.title, artist: t.artist) {
                    let parsed = LRCParser.parse(cached)
                    localTracks[idx].lines = parsed.lines
                    localTracks[idx].hasTimestamps = parsed.hasTimestamps
                }
            }
        }
    }

    func showToast(_ message: String) {
        statusToast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled {
                statusToast = nil
            }
        }
    }
}

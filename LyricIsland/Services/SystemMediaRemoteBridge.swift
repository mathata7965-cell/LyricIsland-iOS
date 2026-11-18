import Darwin
import Foundation

struct SystemNowPlayingSnapshot: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let isPlaying: Bool
    let artworkData: Data?
}

private final class OnceContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: value)
    }
}

/// Optional runtime bridge to MediaRemote.framework.
/// Works automatically on TrollStore / unsandboxed runtimes without linking private symbols or entitlements.
/// On standard sandboxed iOS where MediaRemote returns nil, safely degrades with zero side effects.
final class SystemMediaRemoteBridge {
    static let shared = SystemMediaRemoteBridge()

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private let getInfoFn: GetInfoFn?
    private let sendCommandFn: SendCommandFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        if let handle = dlopen(path, RTLD_LAZY) {
            if let infoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
                self.getInfoFn = unsafeBitCast(infoSym, to: GetInfoFn.self)
            } else {
                self.getInfoFn = nil
            }
            if let cmdSym = dlsym(handle, "MRMediaRemoteSendCommand") {
                self.sendCommandFn = unsafeBitCast(cmdSym, to: SendCommandFn.self)
            } else {
                self.sendCommandFn = nil
            }
        } else {
            self.getInfoFn = nil
            self.sendCommandFn = nil
        }
    }

    var isSupportedBinaryLoaded: Bool {
        getInfoFn != nil
    }

    func fetchNowPlayingInfo() async -> SystemNowPlayingSnapshot? {
        guard let getInfoFn else { return nil }

        return await withCheckedContinuation { continuation in
            let box = OnceContinuationBox(continuation)

            getInfoFn(.global(qos: .userInitiated)) { cfDict in
                guard let dict = cfDict as? [String: Any],
                      let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    box.resumeOnce(nil)
                    return
                }

                let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
                let album = (dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? ""
                let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double) ?? 0
                let baseElapsed = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double) ?? 0
                let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
                let isPlaying = rate > 0.05
                let timestamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
                let liveElapsed: TimeInterval
                if isPlaying, let timestamp {
                    liveElapsed = max(0, baseElapsed + max(0, Date().timeIntervalSince(timestamp)))
                } else {
                    liveElapsed = max(0, baseElapsed)
                }
                let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

                box.resumeOnce(SystemNowPlayingSnapshot(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: max(duration, 1),
                    elapsedTime: liveElapsed,
                    isPlaying: isPlaying,
                    artworkData: artworkData
                ))
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                box.resumeOnce(nil)
            }
        }
    }

    enum RemoteCommand: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    @discardableResult
    func sendCommand(_ command: RemoteCommand) -> Bool {
        guard let sendCommandFn else { return false }
        return sendCommandFn(command.rawValue, nil)
    }
}

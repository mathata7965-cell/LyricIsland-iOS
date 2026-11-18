import MediaPlayer
import SwiftUI

struct MainStageView: View {
    @EnvironmentObject private var engine: LyricEngine
    @ObservedObject private var spotify = SpotifySyncService.shared

    @State private var showSearchSheet = false
    @State private var showSettingsSheet = false
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var accent: Color {
        AcousticTheme.accentColor(from: engine.accentColorRGB)
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : engine.currentTime
    }

    var body: some View {
        ZStack {
            backgroundStage

            VStack(spacing: 0) {
                IslandPreviewCard()

                Divider().overlay(AcousticTheme.hairline)

                trackStrip

                if engine.sourceMode == .spotify && !spotify.isConnected && !engine.isSystemBridgeActive {
                    Divider().overlay(AcousticTheme.hairline)
                    spotifyQuickStrip
                }

                Divider().overlay(AcousticTheme.hairline)

                lyricsStage

                Divider().overlay(AcousticTheme.hairline)

                transportDock
            }

            if let toast = engine.statusToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AcousticTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(AcousticTheme.elevatedSurface, in: Capsule())
                        .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.9))
                        .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                        .padding(.bottom, 138)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.statusToast)
        .sheet(isPresented: $showSearchSheet) {
            SearchLyricsSheet()
                .environmentObject(engine)
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsSourceSheet()
                .environmentObject(engine)
        }
    }

    private var backgroundStage: some View {
        ZStack {
            AcousticTheme.oledBlack.ignoresSafeArea()
            RadialGradient(
                colors: [
                    accent.opacity(engine.isPlaying ? 0.14 : 0.07),
                    Color.clear
                ],
                center: .top,
                startRadius: 10,
                endRadius: 420
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: accent)
        }
    }

    // MARK: - Track Strip

    private var trackStrip: some View {
        HStack(spacing: 12) {
            Group {
                if let art = engine.currentArtwork {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        AcousticTheme.carbonSurface
                        Image(systemName: "music.note")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(accent)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AcousticTheme.hairline, lineWidth: 0.8)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(engine.currentTrack?.title ?? "尚未載入曲目")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AcousticTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if engine.isFetchingLyrics {
                        ProgressView()
                            .scaleEffect(0.65)
                            .tint(accent)
                        Text("正在同步時間軸歌詞…")
                            .font(.caption)
                            .foregroundStyle(AcousticTheme.textSecondary)
                    } else {
                        Text(engine.currentTrack?.displaySubtitle.isEmpty == false
                             ? (engine.currentTrack?.displaySubtitle ?? "")
                             : engine.sourceMode.detailDescription)
                            .font(.caption)
                            .foregroundStyle(AcousticTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                showSettingsSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: engine.sourceMode.systemImage)
                        .font(.caption2.weight(.bold))
                    Text(engine.sourceMode.shortBadge)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(AcousticTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AcousticTheme.carbonSurface, in: Capsule())
                .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var spotifyQuickStrip: some View {
        HStack(spacing: 8) {
            Button {
                showSettingsSheet = true
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(red: 0.114, green: 0.725, blue: 0.329))
                        .frame(width: 6, height: 6)
                    Text("連結 Spotify 帳號自動同步")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(AcousticTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AcousticTheme.carbonSurface, in: Capsule())
                .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.8))
            }

            Spacer()

            Button {
                if let clip = UIPasteboard.general.string, SpotifySyncService.looksLikeSpotifyLink(clip) {
                    engine.importSpotifyShareLink(clip, activatePiP: true)
                } else {
                    showSearchSheet = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.caption2.weight(.bold))
                    Text("貼上分享連結")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(AcousticTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AcousticTheme.carbonSurface, in: Capsule())
                .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(AcousticTheme.oledBlack)
    }

    // MARK: - Lyrics Stage

    private var lyricsStage: some View {
        Group {
            if let track = engine.currentTrack, !track.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            Spacer().frame(height: 20)

                            ForEach(Array(track.lines.enumerated()), id: \.element.id) { index, line in
                                lyricRow(line: line, index: index, activeIndex: engine.activeLineIndex)
                                    .id(line.id)
                            }

                            Spacer().frame(height: 120)
                        }
                        .padding(.horizontal, 20)
                    }
                    .onChange(of: engine.activeLineIndex) { _, newIdx in
                        guard let newIdx, track.lines.indices.contains(newIdx) else { return }
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            proxy.scrollTo(track.lines[newIdx].id, anchor: .center)
                        }
                    }
                }
            } else {
                emptyStageView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricRow(line: LyricLine, index: Int, activeIndex: Int?) -> some View {
        let isCurrent = index == activeIndex
        let isPast = activeIndex.map { index < $0 } ?? false

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            engine.jumpToLine(line)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isCurrent ? accent : Color.clear)
                    .frame(width: 3, height: isCurrent ? 22 : 12)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(line.text)
                        .font(.system(size: isCurrent ? 23 : 18, weight: isCurrent ? .bold : .semibold))
                        .foregroundStyle(
                            isCurrent
                                ? AcousticTheme.textPrimary
                                : (isPast ? AcousticTheme.textMuted : AcousticTheme.textSecondary)
                        )
                        .multilineTextAlignment(.leading)

                    if let translation = line.translation, !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: isCurrent ? 14.5 : 13, weight: .medium))
                            .foregroundStyle(
                                isCurrent
                                    ? AcousticTheme.textSecondary
                                    : AcousticTheme.textMuted
                            )
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if engine.currentTrack?.hasTimestamps == true {
                Button {
                    engine.anchorLineToCurrentMoment(line)
                } label: {
                    Label("以此句作為現在時間點對軸", systemImage: "scope")
                }
            }
            Button {
                UIPasteboard.general.string = line.text
                engine.showToast("已複製歌詞")
            } label: {
                Label("複製這一句", systemImage: "doc.on.doc")
            }
        }
    }

    private var emptyStageView: some View {
        VStack(spacing: 14) {
            Text(emptyHintText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AcousticTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            VStack(spacing: 10) {
                if engine.sourceMode == .spotify && !spotify.isConnected {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Label("連結 Spotify 帳號即時同步", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 245)
                            .padding(.vertical, 11)
                            .background(AcousticTheme.textPrimary, in: Capsule())
                    }
                } else if engine.sourceMode == .appleMusic && engine.appleMusicAuthStatus != .authorized {
                    Button {
                        engine.requestAppleMusicAccess()
                    } label: {
                        Label("授權讀取 Apple Music", systemImage: "music.note")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 245)
                            .padding(.vertical, 11)
                            .background(AcousticTheme.textPrimary, in: Capsule())
                    }
                }

                Button {
                    showSearchSheet = true
                } label: {
                    Label("搜尋歌詞 / 貼上 Spotify 連結", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AcousticTheme.textPrimary)
                        .frame(width: 245)
                        .padding(.vertical, 11)
                        .background(AcousticTheme.carbonSurface, in: Capsule())
                        .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.9))
                }

                Button {
                    engine.loadQuickTestSample(autoplay: true)
                    engine.toggleFloatingPiP()
                } label: {
                    Label("一鍵測試懸浮歌詞窗", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var emptyHintText: String {
        switch engine.sourceMode {
        case .spotify:
            if spotify.isConnected {
                return "正在等待 Spotify 播放曲目…"
            }
            return "連結 Spotify 即時同步進度，或開啟右上「懸浮歌詞」直接疊加顯示於 Spotify 上方"
        case .appleMusic:
            return engine.appleMusicAuthStatus != .authorized
                ? "授權讀取 Apple Music，或直接搜尋歌詞上島"
                : "正在偵測 Apple Music 播放曲目…"
        default:
            return "尚未讀取到歌詞時間軸"
        }
    }

    // MARK: - Transport & Calibration Dock

    private var transportDock: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let total = max(engine.duration, 1)
                    let progress = min(max(displayedTime / total, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: isScrubbing ? 6 : 3.5)

                        Capsule()
                            .fill(AcousticTheme.textPrimary)
                            .frame(width: max(4, geo.size.width * progress), height: isScrubbing ? 6 : 3.5)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isScrubbing = true
                                let ratio = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                                scrubTime = ratio * total
                            }
                            .onEnded { value in
                                let ratio = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                                engine.seek(to: ratio * total)
                                isScrubbing = false
                            }
                    )
                }
                .frame(height: 18)

                HStack {
                    Text(LRCParser.formatTime(displayedTime))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AcousticTheme.textSecondary)

                    Spacer()

                    HStack(spacing: 0) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            engine.nudgeOffset(by: -0.5)
                        } label: {
                            Text("−0.5s")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                        }

                        Button {
                            engine.resetOffset()
                        } label: {
                            Text(String(format: "%+.1fs", engine.syncOffset))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(abs(engine.syncOffset) > 0.05 ? accent : AcousticTheme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            engine.nudgeOffset(by: 0.5)
                        } label: {
                            Text("+0.5s")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                        }
                    }
                    .foregroundStyle(AcousticTheme.textPrimary)
                    .background(AcousticTheme.carbonSurface, in: Capsule())
                    .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.8))

                    Spacer()

                    Text(LRCParser.formatTime(engine.duration))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AcousticTheme.textSecondary)
                }
            }

            HStack {
                Button {
                    showSearchSheet = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AcousticTheme.textSecondary)
                        .frame(width: 44, height: 44)
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    engine.skipPrevious()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(AcousticTheme.textPrimary)
                        .frame(width: 46, height: 46)
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 54, height: 54)
                        .background(AcousticTheme.textPrimary, in: Circle())
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    engine.skipNext()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(AcousticTheme.textPrimary)
                        .frame(width: 46, height: 46)
                }

                Spacer()

                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AcousticTheme.textSecondary)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(AcousticTheme.oledBlack)
    }
}

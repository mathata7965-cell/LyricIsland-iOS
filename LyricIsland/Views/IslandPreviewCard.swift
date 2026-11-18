import SwiftUI

struct IslandPreviewCard: View {
    @EnvironmentObject private var engine: LyricEngine
    @ObservedObject private var pipManager: PiPLyricOverlayManager
    @State private var previewExpanded = false

    init() {
        _pipManager = ObservedObject(wrappedValue: LyricEngine.shared.pipManager)
    }

    private var accent: Color {
        AcousticTheme.accentColor(from: engine.accentColorRGB)
    }

    private var statusText: String {
        if pipManager.isPiPActive && engine.isIslandEnabled {
            return "懸浮窗 + 靈動島"
        } else if pipManager.isPiPActive {
            return "懸浮歌詞運行中"
        } else if engine.isIslandEnabled {
            return "靈動島運行中"
        } else {
            return "即時詞島待命"
        }
    }

    var body: some View {
        let state = engine.buildCurrentContentState()

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    // Live AVSampleBufferDisplayLayer host (must remain visible in hierarchy for iOS PiP)
                    PiPBufferHostView(displayLayer: pipManager.displayLayer)
                        .frame(width: 52, height: 19)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                pipManager.isPiPActive ? accent.opacity(0.85) : Color.white.opacity(0.16),
                                lineWidth: 0.9
                            )
                        )

                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            (pipManager.isPiPActive || engine.isIslandEnabled)
                                ? AcousticTheme.textPrimary
                                : AcousticTheme.textSecondary
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // PiP Floating Pill Toggle (overlay on top of Spotify / Home Screen)
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    engine.toggleFloatingPiP()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(pipManager.isPiPActive ? "懸浮開" : "懸浮歌詞")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(pipManager.isPiPActive ? AcousticTheme.textPrimary : Color.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        pipManager.isPiPActive
                            ? AnyShapeStyle(AcousticTheme.elevatedSurface)
                            : AnyShapeStyle(AcousticTheme.textPrimary),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            pipManager.isPiPActive ? accent.opacity(0.75) : Color.clear,
                            lineWidth: 1
                        )
                    )
                }

                // ActivityKit Dynamic Island / Lock Screen Toggle
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    engine.toggleDynamicIsland()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(engine.isIslandEnabled ? accent : AcousticTheme.textMuted)
                            .frame(width: 5.5, height: 5.5)
                        Text(engine.isIslandEnabled ? "鎖屏開" : "靈動島")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(AcousticTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AcousticTheme.elevatedSurface, in: Capsule())
                    .overlay(
                        Capsule().stroke(
                            engine.isIslandEnabled ? accent.opacity(0.75) : AcousticTheme.hairline,
                            lineWidth: 1
                        )
                    )
                }
            }

            Group {
                if previewExpanded {
                    expandedSimulator(state: state)
                } else {
                    compactSimulator(state: state)
                }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    previewExpanded.toggle()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func compactSimulator(state: LyricActivityAttributes.ContentState) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                thumbnailView(size: 18, corner: 5)
                if state.displayStyle == .instrument {
                    Text(LRCParser.formatTime(max(0, state.durationSeconds - state.elapsedSeconds)))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AcousticTheme.textSecondary)
                } else {
                    SignalBarsView(isActive: state.isPlaying, color: accent)
                }
            }

            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 58, height: 14)

            Text(state.currentLine)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AcousticTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black, in: Capsule())
        .overlay(
            Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.9)
        )
        .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
    }

    private func expandedSimulator(state: LyricActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                thumbnailView(size: 38, corner: 9)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.trackTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AcousticTheme.textPrimary)
                        .lineLimit(1)
                    Text(state.artistName.isEmpty ? state.sourceLabel : state.artistName)
                        .font(.caption2)
                        .foregroundStyle(AcousticTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 5) {
                    SignalBarsView(isActive: state.isPlaying, color: accent)
                    Text(state.sourceLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent.opacity(0.14), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.currentLine)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(AcousticTheme.textPrimary)
                    .lineLimit(2)

                if state.displayStyle != .compactLyrics, !state.secondaryLine.isEmpty {
                    Text(state.secondaryLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AcousticTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(4, geo.size.width * state.progressFraction))
                }
            }
            .frame(height: 3)
        }
        .padding(14)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 14, y: 6)
    }

    @ViewBuilder
    private func thumbnailView(size: CGFloat, corner: CGFloat) -> some View {
        if let artwork = engine.currentArtwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(accent.opacity(0.22))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(accent)
                )
        }
    }
}

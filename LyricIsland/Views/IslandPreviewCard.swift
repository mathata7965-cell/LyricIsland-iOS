import SwiftUI

struct IslandPreviewCard: View {
    @EnvironmentObject private var engine: LyricEngine
    @State private var previewExpanded = false

    private var accent: Color {
        AcousticTheme.accentColor(from: engine.accentColorRGB)
    }

    var body: some View {
        let state = engine.buildCurrentContentState()

        VStack(spacing: 10) {
            // Top minimal header strip
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isIslandEnabled ? accent : AcousticTheme.textMuted)
                        .frame(width: 6, height: 6)
                    Text(engine.isIslandEnabled ? "即時動態運行中" : "靈動島待機")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(engine.isIslandEnabled ? AcousticTheme.textPrimary : AcousticTheme.textSecondary)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        previewExpanded.toggle()
                    }
                } label: {
                    Text(previewExpanded ? "收合預覽" : "展開預覽")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AcousticTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(AcousticTheme.elevatedSurface, in: Capsule())
                        .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.8))
                }

                Button {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    engine.toggleDynamicIsland()
                } label: {
                    Text(engine.isIslandEnabled ? "關閉島上歌詞" : "啟動靈動島")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(engine.isIslandEnabled ? AcousticTheme.textPrimary : Color.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            engine.isIslandEnabled ? AnyShapeStyle(AcousticTheme.elevatedSurface) : AnyShapeStyle(AcousticTheme.textPrimary),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                engine.isIslandEnabled ? accent.opacity(0.65) : Color.clear,
                                lineWidth: 1
                            )
                        )
                }
            }

            // Hardware-proportioned Dynamic Island simulator
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

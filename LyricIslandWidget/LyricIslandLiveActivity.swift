import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct LyricIslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricActivityAttributes.self) { context in
            lockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let accent = accentColor(from: state)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    artworkView(data: state.artworkThumb, accent: accent, size: 42, corner: 10)
                        .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if let range = state.liveTimerInterval {
                            Text(timerInterval: range, countsDown: true)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.65))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 46, alignment: .trailing)
                        } else {
                            Text(state.isPlaying ? state.sourceLabel : "已暫停")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(.trailing, 2)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 3) {
                        Text(state.artistName.isEmpty ? state.trackTitle : "\(state.trackTitle) · \(state.artistName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)

                        Text(state.currentLine)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.84)

                        if !state.secondaryLine.isEmpty && (state.displayStyle != .compactLyrics || state.isSecondaryTranslation) {
                            Text(state.secondaryLine)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.56))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        progressBar(state: state, accent: accent)
                        controlsRow(state: state, accent: accent)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                compactLeadingView(state: state, accent: accent)
            } compactTrailing: {
                Text(state.currentLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .trailing)
            } minimal: {
                compactLeadingView(state: state, accent: accent)
            }
            .keylineTint(accent)
        }
    }

    // MARK: - Lock Screen Presentation

    @ViewBuilder
    private func lockScreenView(state: LyricActivityAttributes.ContentState) -> some View {
        let accent = accentColor(from: state)

        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                artworkView(data: state.artworkThumb, accent: accent, size: 36, corner: 8)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(state.trackTitle)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(state.artistName.isEmpty ? state.sourceLabel : state.artistName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if state.displayStyle == .instrument, let range = state.liveTimerInterval {
                    Text(timerInterval: range, countsDown: true)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48, alignment: .trailing)
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.isPlaying ? accent : Color.white.opacity(0.35))
                            .frame(width: 5.5, height: 5.5)
                        Text(state.sourceLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 3.5) {
                Text(state.currentLine)
                    .font(.system(size: 16.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)

                if !state.secondaryLine.isEmpty && (state.displayStyle != .compactLyrics || state.isSecondaryTranslation) {
                    Text(state.secondaryLine)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                }
            }

            VStack(spacing: 8) {
                progressBar(state: state, accent: accent)
                controlsRow(state: state, accent: accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func compactLeadingView(state: LyricActivityAttributes.ContentState, accent: Color) -> some View {
        if let data = state.artworkThumb, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: state.isPlaying ? "waveform" : "music.note")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private func artworkView(data: Data?, accent: Color, size: CGFloat, corner: CGFloat) -> some View {
        if let data, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                )
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(accent.opacity(0.2))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.44, weight: .bold))
                        .foregroundStyle(accent)
                )
        }
    }

    @ViewBuilder
    private func progressBar(state: LyricActivityAttributes.ContentState, accent: Color) -> some View {
        if let range = state.liveTimerInterval {
            ProgressView(
                timerInterval: range,
                countsDown: false,
                label: { EmptyView() },
                currentValueLabel: { EmptyView() }
            )
            .tint(accent)
            .scaleEffect(x: 1, y: 0.72, anchor: .center)
        } else {
            ProgressView(value: state.progressFraction)
                .tint(accent.opacity(0.75))
                .scaleEffect(x: 1, y: 0.72, anchor: .center)
        }
    }

    private func controlsRow(state: LyricActivityAttributes.ContentState, accent: Color) -> some View {
        HStack(spacing: 10) {
            Button(intent: NudgeLyricsBackwardIntent()) {
                Text("−0.5s")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(intent: PreviousLyricItemIntent()) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)

            Button(intent: ToggleLyricPlayIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 26)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Button(intent: NextLyricItemIntent()) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(intent: NudgeLyricsForwardIntent()) {
                Text("+0.5s")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func accentColor(from state: LyricActivityAttributes.ContentState) -> Color {
        Color(red: state.accentRed, green: state.accentGreen, blue: state.accentBlue)
    }
}

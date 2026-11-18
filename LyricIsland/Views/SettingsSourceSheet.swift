import MediaPlayer
import SwiftUI

struct SettingsSourceSheet: View {
    @EnvironmentObject private var engine: LyricEngine
    @Environment(\.dismiss) private var dismiss

    private var accent: Color {
        AcousticTheme.accentColor(from: engine.accentColorRGB)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("同步來源") {
                    ForEach(PlaybackSourceMode.allCases) { mode in
                        Button {
                            engine.switchSourceMode(mode)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: mode.systemImage)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(engine.sourceMode == mode ? accent : AcousticTheme.textSecondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AcousticTheme.textPrimary)
                                    Text(mode.detailDescription)
                                        .font(.caption)
                                        .foregroundStyle(AcousticTheme.textSecondary)
                                }

                                Spacer()

                                if engine.sourceMode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(accent)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .listRowBackground(AcousticTheme.carbonSurface)
                    }

                    if engine.sourceMode == .appleMusic && engine.appleMusicAuthStatus != .authorized {
                        Button {
                            engine.requestAppleMusicAccess()
                        } label: {
                            HStack {
                                Text("授權讀取「媒體與 Apple Music」")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(accent)
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.caption)
                                    .foregroundStyle(accent)
                            }
                        }
                        .listRowBackground(AcousticTheme.carbonSurface)
                    }
                }

                Section("靈動島樣式") {
                    ForEach(IslandDisplayStyle.allCases) { style in
                        Button {
                            engine.setDisplayStyle(style)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AcousticTheme.textPrimary)
                                    Text(style.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(AcousticTheme.textSecondary)
                                }
                                Spacer()
                                if engine.displayStyle == style {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(accent)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(AcousticTheme.carbonSurface)
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { engine.isBackgroundKeepAliveEnabled },
                        set: { engine.setBackgroundKeepAlive($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("背景靜音保活（混音）")
                                .font(.subheadline.weight(.semibold))
                            Text("切出 App 時維持時間軸推進，不打斷 Spotify 或 Apple Music 音訊。")
                                .font(.caption)
                                .foregroundStyle(AcousticTheme.textSecondary)
                        }
                    }
                    .tint(accent)
                    .listRowBackground(AcousticTheme.carbonSurface)
                } header: {
                    Text("背景與系統")
                }

                Section("iOS 快捷指令自動化 URL") {
                    urlCopyRow(
                        title: "一鍵啟動靈動歌詞",
                        url: "lyricisland://start"
                    )
                    urlCopyRow(
                        title: "帶入歌名搜尋並上島",
                        url: "lyricisland://sync?title=晴天&artist=周杰倫&autoplay=1"
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(AcousticTheme.oledBlack)
            .navigationTitle("來源與島上樣式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(AcousticTheme.textPrimary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func urlCopyRow(title: String, url: String) -> some View {
        Button {
            UIPasteboard.general.string = url
            engine.showToast("已複製：\(url)")
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AcousticTheme.textPrimary)
                    Spacer()
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(AcousticTheme.textMuted)
                }
                Text(url)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AcousticTheme.textSecondary)
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(AcousticTheme.carbonSurface)
    }
}

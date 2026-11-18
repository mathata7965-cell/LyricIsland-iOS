import MediaPlayer
import SwiftUI

struct SettingsSourceSheet: View {
    @EnvironmentObject private var engine: LyricEngine
    @ObservedObject private var spotify = SpotifySyncService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var clientIdInput: String = SpotifySyncService.shared.clientId
    @State private var isConnectingSpotify = false
    @State private var spotifyError: String?

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

                Section {
                    if spotify.isConnected {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已連結 Spotify 帳號")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AcousticTheme.textPrimary)
                                Text(spotify.accountDisplayName.isEmpty ? "即時同步播放進度與切歌" : spotify.accountDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(Color(red: 0.114, green: 0.725, blue: 0.329))
                            }
                            Spacer()
                            Button("中斷連結") {
                                engine.disconnectSpotify()
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        }
                        .listRowBackground(AcousticTheme.carbonSurface)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Spotify 帳號直連（免費 PKCE API）")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AcousticTheme.textPrimary)

                            TextField("貼上 Spotify App Client ID", text: $clientIdInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 13, design: .monospaced))
                                .padding(10)
                                .background(AcousticTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                            HStack(spacing: 8) {
                                Button {
                                    UIPasteboard.general.string = SpotifySyncService.redirectURI
                                    engine.showToast("已複製 Redirect URI")
                                } label: {
                                    Text("複製回調 URI")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AcousticTheme.textPrimary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(AcousticTheme.elevatedSurface, in: Capsule())
                                }

                                Link("開啟 Spotify 控制台", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AcousticTheme.textSecondary)
                            }

                            Button {
                                startSpotifyConnect()
                            } label: {
                                HStack {
                                    if isConnectingSpotify {
                                        ProgressView().tint(.black)
                                    } else {
                                        Text("授權登入 Spotify")
                                            .font(.subheadline.weight(.bold))
                                    }
                                }
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(red: 0.114, green: 0.725, blue: 0.329), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .disabled(clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnectingSpotify)

                            if let spotifyError {
                                Text(spotifyError)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(AcousticTheme.carbonSurface)
                    }
                } header: {
                    Text("Spotify 同步設定")
                } footer: {
                    Text("於 developer.spotify.com 建立 App，將 Redirect URI 設為 \(SpotifySyncService.redirectURI)，即可直接讀取 Spotify 播放曲目與毫秒進度。或直接在「搜尋歌詞」貼上 Spotify 分享連結使用。")
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
                        title: "開啟懸浮歌詞窗",
                        url: "lyricisland://pip"
                    )
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

    private func startSpotifyConnect() {
        spotifyError = nil
        isConnectingSpotify = true
        Task {
            do {
                try await engine.connectSpotify(clientId: clientIdInput)
                isConnectingSpotify = false
                dismiss()
            } catch {
                spotifyError = error.localizedDescription
                isConnectingSpotify = false
            }
        }
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

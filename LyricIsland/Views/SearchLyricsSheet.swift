import SwiftUI
import UniformTypeIdentifiers

private enum SearchTab: String, CaseIterable, Identifiable {
    case online = "線上搜詞"
    case paste = "貼上 LRC"
    case local = "本機檔案"

    var id: String { rawValue }
}

struct SearchLyricsSheet: View {
    @EnvironmentObject private var engine: LyricEngine
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SearchTab = .online
    @State private var queryText: String = ""
    @State private var isSearching = false
    @State private var results: [LRCSearchCandidate] = []
    @State private var hasSearched = false

    @State private var customTitle: String = ""
    @State private var customArtist: String = ""
    @State private var customLyricsText: String = ""

    @State private var showFileImporter = false

    private var accent: Color {
        AcousticTheme.accentColor(from: engine.accentColorRGB)
    }

    private var allowedFileTypes: [UTType] {
        let lrcType = UTType(filenameExtension: "lrc") ?? .plainText
        return [.audio, lrcType, .plainText]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AcousticTheme.oledBlack.ignoresSafeArea()

                VStack(spacing: 14) {
                    Picker("載入方式", selection: $selectedTab) {
                        ForEach(SearchTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    switch selectedTab {
                    case .online:
                        onlineSearchContent
                    case .paste:
                        pasteLRCContent
                    case .local:
                        localFilesContent
                    }
                }
                .padding(.top, 8)
            }
            .navigationTitle("搜詞與匯入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(AcousticTheme.textPrimary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if queryText.isEmpty, let track = engine.currentTrack, track.id != "sample-test" {
                queryText = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: allowedFileTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                engine.importFiles(urls: urls)
                dismiss()
            case .failure(let error):
                engine.showToast("匯入失敗：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Online LRCLIB + Spotify Share Link + iTunes Search

    private var onlineSearchContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(AcousticTheme.textSecondary)
                    TextField("輸入歌名、歌手或貼上 Spotify 連結", text: $queryText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    if !queryText.isEmpty {
                        Button {
                            queryText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AcousticTheme.textMuted)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AcousticTheme.carbonSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AcousticTheme.hairline, lineWidth: 0.8)
                )

                Button {
                    runSearch()
                } label: {
                    Text("搜尋")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(AcousticTheme.textPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, 16)

            if isSearching {
                Spacer()
                ProgressView("正在檢索時間軸歌詞…")
                    .tint(AcousticTheme.textPrimary)
                Spacer()
            } else if results.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Text(hasSearched
                         ? "找不到相符歌詞，請嘗試精簡關鍵字"
                         : "輸入歌名搜尋，或直接貼上 Spotify「分享 → 複製連結」")
                        .font(.subheadline)
                        .foregroundStyle(AcousticTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if !hasSearched {
                        HStack(spacing: 10) {
                            Button {
                                if let clip = UIPasteboard.general.string, SpotifySyncService.looksLikeSpotifyLink(clip) {
                                    engine.importSpotifyShareLink(clip, activatePiP: true)
                                    dismiss()
                                } else {
                                    engine.showToast("剪貼簿內沒有 Spotify 單曲連結")
                                }
                            } label: {
                                Label("貼上 Spotify 連結", systemImage: "link")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AcousticTheme.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(AcousticTheme.elevatedSurface, in: Capsule())
                                    .overlay(Capsule().stroke(AcousticTheme.hairline, lineWidth: 0.8))
                            }

                            Button {
                                engine.loadQuickTestSample(autoplay: true)
                                engine.toggleFloatingPiP()
                                dismiss()
                            } label: {
                                Label("測試懸浮歌詞", systemImage: "bolt.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(AcousticTheme.textPrimary, in: Capsule())
                            }
                        }
                    }
                }
                Spacer()
            } else {
                List {
                    ForEach(results) { item in
                        Button {
                            engine.loadSearchCandidate(item, autoplay: true, activateIsland: true, activatePiP: engine.pipManager.isPiPActive)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: item.artworkURL) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    } else {
                                        ZStack {
                                            AcousticTheme.elevatedSurface
                                            Image(systemName: "music.note")
                                                .foregroundStyle(AcousticTheme.textMuted)
                                        }
                                    }
                                }
                                .frame(width: 46, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(item.trackName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(AcousticTheme.textPrimary)
                                            .lineLimit(1)

                                        Text(item.isSynced ? "逐句" : "純文")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(item.isSynced ? accent : AcousticTheme.textMuted)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                (item.isSynced ? accent : AcousticTheme.textMuted).opacity(0.14),
                                                in: Capsule()
                                            )
                                    }

                                    Text([item.artistName, item.duration > 0 ? LRCParser.formatTime(item.duration) : nil]
                                        .compactMap { $0 }
                                        .joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(AcousticTheme.textSecondary)
                                        .lineLimit(1)

                                    Text(item.previewLine)
                                        .font(.caption2)
                                        .foregroundStyle(AcousticTheme.textMuted)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AcousticTheme.textMuted)
                            }
                            .padding(.vertical, 3)
                        }
                        .listRowBackground(AcousticTheme.carbonSurface)
                        .listRowSeparatorTint(AcousticTheme.hairline)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Paste LRC

    private var pasteLRCContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("曲名（可選）", text: $customTitle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AcousticTheme.carbonSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                TextField("歌手（可選）", text: $customArtist)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AcousticTheme.carbonSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .font(.subheadline)
            .padding(.horizontal, 16)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $customLyricsText)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(AcousticTheme.carbonSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AcousticTheme.hairline, lineWidth: 0.8)
                    )

                if customLyricsText.isEmpty {
                    Text("[00:12.30]貼上標準 LRC 或純文字歌詞…")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(AcousticTheme.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Button {
                    if let clip = UIPasteboard.general.string {
                        customLyricsText = clip
                    }
                } label: {
                    Label("從剪貼簿貼上", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AcousticTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AcousticTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button {
                    engine.applyCustomLyrics(customLyricsText, title: customTitle, artist: customArtist)
                    dismiss()
                } label: {
                    Text("套用歌詞")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AcousticTheme.textPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(customLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Local Files

    private var localFilesContent: some View {
        VStack(spacing: 14) {
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("從「檔案」匯入音訊或 .lrc")
                            .font(.subheadline.weight(.bold))
                        Text("支援 mp3 / m4a / flac / wav 與同名 .lrc 自動配對")
                            .font(.caption)
                            .foregroundStyle(AcousticTheme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AcousticTheme.textMuted)
                }
                .foregroundStyle(AcousticTheme.textPrimary)
                .padding(14)
                .background(AcousticTheme.carbonSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AcousticTheme.hairline, lineWidth: 0.9)
                )
            }
            .padding(.horizontal, 16)

            if engine.localTracks.isEmpty {
                Spacer()
                Text("尚未匯入本機音訊")
                    .font(.subheadline)
                    .foregroundStyle(AcousticTheme.textMuted)
                Spacer()
            } else {
                List {
                    ForEach(engine.localTracks) { track in
                        Button {
                            engine.playLocalTrack(track, autoplay: true)
                            engine.enableDynamicIsland()
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AcousticTheme.textPrimary)
                                    Text("\(track.artist) · \(LRCParser.formatTime(track.duration))")
                                        .font(.caption)
                                        .foregroundStyle(AcousticTheme.textSecondary)
                                }
                                Spacer()
                                if engine.currentTrack?.id == track.id {
                                    SignalBarsView(isActive: engine.isPlaying, color: accent)
                                }
                            }
                        }
                        .listRowBackground(AcousticTheme.carbonSurface)
                        .listRowSeparatorTint(AcousticTheme.hairline)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func runSearch() {
        let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        if SpotifySyncService.looksLikeSpotifyLink(q) {
            engine.importSpotifyShareLink(q, activatePiP: true)
            dismiss()
            return
        }

        isSearching = true
        hasSearched = true
        Task {
            let found = await LyricsLookupService.shared.searchInteractive(query: q)
            results = found
            isSearching = false
        }
    }
}

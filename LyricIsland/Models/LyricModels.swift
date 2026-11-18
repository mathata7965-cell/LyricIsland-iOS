import Foundation

enum PlaybackSourceMode: String, CaseIterable, Identifiable, Codable {
    case appleMusic = "apple_music"
    case companion = "companion"
    case localAudio = "local_audio"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .companion: return "外播伴侶"
        case .localAudio: return "本機音訊"
        }
    }

    var shortBadge: String {
        switch self {
        case .appleMusic: return "AM 即時"
        case .companion: return "伴侶同步"
        case .localAudio: return "本機播放"
        }
    }

    var systemImage: String {
        switch self {
        case .appleMusic: return "music.note"
        case .companion: return "waveform.badge.magnifyingglass"
        case .localAudio: return "folder.badge.gearshape"
        }
    }

    var detailDescription: String {
        switch self {
        case .appleMusic:
            return "自動讀取系統 Apple Music 的曲目、封面與即時進度軸。"
        case .companion:
            return "搭配 Spotify / YouTube Music / KKBOX 使用，由詞島在背景維持同步時間軸。"
        case .localAudio:
            return "直接播放匯入的本機音訊檔與內嵌或外掛 LRC 歌詞。"
        }
    }
}

struct LyricLine: Identifiable, Hashable, Codable {
    let id: UUID
    let time: TimeInterval
    var text: String
    var translation: String?

    init(id: UUID = UUID(), time: TimeInterval, text: String, translation: String? = nil) {
        self.id = id
        self.time = max(0, time)
        self.text = text
        self.translation = translation
    }
}

struct LyricTrack: Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var lines: [LyricLine]
    var hasTimestamps: Bool
    var artworkURL: URL?
    var localAudioURL: URL?
    var sourceLabel: String

    var displaySubtitle: String {
        if artist.isEmpty { return album }
        return artist
    }
}

struct LRCSearchCandidate: Identifiable, Hashable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: TimeInterval
    let syncedLyrics: String?
    let plainLyrics: String?
    var artworkURL: URL?

    var isSynced: Bool {
        guard let syncedLyrics else { return false }
        return !syncedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var previewLine: String {
        if let syncedLyrics, !syncedLyrics.isEmpty {
            let parsed = LRCParser.parse(syncedLyrics)
            if let first = parsed.lines.first(where: { !$0.text.isEmpty }) {
                return first.text
            }
        }
        if let plainLyrics {
            let first = plainLyrics
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let first { return first }
        }
        return "純音樂或暫無預覽"
    }
}

import ActivityKit
import Foundation

public enum IslandDisplayStyle: String, Codable, Hashable, CaseIterable, Identifiable {
    case compactLyrics = "compact"
    case bilingual = "bilingual"
    case instrument = "instrument"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compactLyrics: return "極簡詞島"
        case .bilingual: return "雙行歌詞"
        case .instrument: return "聲學儀表"
        }
    }

    public var subtitle: String {
        switch self {
        case .compactLyrics: return "單行高對比主詞，島上最俐落"
        case .bilingual: return "同時顯示翻譯或下一句預告"
        case .instrument: return "附帶精準剩餘倒數與訊號指示"
        }
    }
}

public struct LyricActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var trackTitle: String
        public var artistName: String
        public var currentLine: String
        public var secondaryLine: String
        public var isSecondaryTranslation: Bool
        public var isPlaying: Bool
        public var elapsedSeconds: Double
        public var durationSeconds: Double
        public var referenceTimestamp: Double
        public var accentRed: Double
        public var accentGreen: Double
        public var accentBlue: Double
        public var artworkThumb: Data?
        public var sourceLabel: String
        public var displayStyle: IslandDisplayStyle
        public var offsetSeconds: Double

        public init(
            trackTitle: String,
            artistName: String,
            currentLine: String,
            secondaryLine: String,
            isSecondaryTranslation: Bool,
            isPlaying: Bool,
            elapsedSeconds: Double,
            durationSeconds: Double,
            referenceTimestamp: Double,
            accentRed: Double,
            accentGreen: Double,
            accentBlue: Double,
            artworkThumb: Data?,
            sourceLabel: String,
            displayStyle: IslandDisplayStyle,
            offsetSeconds: Double
        ) {
            self.trackTitle = String(trackTitle.prefix(80))
            self.artistName = String(artistName.prefix(60))
            self.currentLine = String(currentLine.prefix(120))
            self.secondaryLine = String(secondaryLine.prefix(120))
            self.isSecondaryTranslation = isSecondaryTranslation
            self.isPlaying = isPlaying
            self.elapsedSeconds = max(0, elapsedSeconds)
            self.durationSeconds = max(1, durationSeconds)
            self.referenceTimestamp = referenceTimestamp
            self.accentRed = accentRed
            self.accentGreen = accentGreen
            self.accentBlue = accentBlue
            // ActivityKit enforces a strict 4KB payload budget; cap artwork under 1.5KB.
            if let artworkThumb, artworkThumb.count <= 1500 {
                self.artworkThumb = artworkThumb
            } else {
                self.artworkThumb = nil
            }
            self.sourceLabel = String(sourceLabel.prefix(24))
            self.displayStyle = displayStyle
            self.offsetSeconds = offsetSeconds
        }

        public var liveTimerInterval: ClosedRange<Date>? {
            guard isPlaying else { return nil }
            let safeDuration = max(durationSeconds, 1.0)
            let clampedElapsed = min(max(elapsedSeconds, 0), safeDuration - 0.5)
            let start = Date(timeIntervalSince1970: referenceTimestamp - clampedElapsed)
            let end = start.addingTimeInterval(safeDuration)
            let now = Date()
            guard start < end, end > now else { return nil }
            return start...end
        }

        public var progressFraction: Double {
            guard durationSeconds > 0 else { return 0 }
            return min(max(elapsedSeconds / durationSeconds, 0), 1)
        }
    }

    public var activityId: String

    public init(activityId: String = "primary") {
        self.activityId = activityId
    }
}

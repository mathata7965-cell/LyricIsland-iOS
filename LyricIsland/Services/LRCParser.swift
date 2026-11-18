import Foundation

struct ParsedLyricsResult {
    let lines: [LyricLine]
    let hasTimestamps: Bool
    let titleTag: String?
    let artistTag: String?
    let albumTag: String?
}

enum LRCParser {
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )
    private static let inlineWordTagRegex = try! NSRegularExpression(
        pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#
    )
    private static let metaTagRegex = try! NSRegularExpression(
        pattern: #"^\[(ti|ar|al|by|offset|re|ve|length):(.*)\]$"#,
        options: [.caseInsensitive]
    )

    static func parse(_ raw: String) -> ParsedLyricsResult {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var titleTag: String?
        var artistTag: String?
        var albumTag: String?
        var globalOffsetSeconds: TimeInterval = 0
        var entries: [(time: TimeInterval, text: String)] = []

        for rawLine in normalized.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let nsLine = trimmed as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            if let metaMatch = metaTagRegex.firstMatch(in: trimmed, range: fullRange) {
                let key = nsLine.substring(with: metaMatch.range(at: 1)).lowercased()
                let value = nsLine.substring(with: metaMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "ti":
                    if !value.isEmpty { titleTag = value }
                case "ar":
                    if !value.isEmpty { artistTag = value }
                case "al":
                    if !value.isEmpty { albumTag = value }
                case "offset":
                    if let ms = Double(value) {
                        // LRC spec: positive offset shifts lyrics earlier (subtract from timestamp)
                        globalOffsetSeconds = -ms / 1000.0
                    }
                default:
                    break
                }
                continue
            }

            let matches = timestampRegex.matches(in: trimmed, range: fullRange)
            guard !matches.isEmpty else { continue }

            var textPart = timestampRegex.stringByReplacingMatches(in: trimmed, range: fullRange, withTemplate: "")
            let textNS = textPart as NSString
            textPart = inlineWordTagRegex.stringByReplacingMatches(
                in: textPart,
                range: NSRange(location: 0, length: textNS.length),
                withTemplate: ""
            )
            let cleanedText = textPart
                .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if cleanedText.isEmpty { continue }

            for match in matches {
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                let fracRange = match.range(at: 3)

                guard let minutes = Double(minStr), let seconds = Double(secStr) else { continue }
                var frac: Double = 0
                if fracRange.location != NSNotFound {
                    let fracStr = nsLine.substring(with: fracRange)
                    if let fracVal = Double(fracStr) {
                        switch fracStr.count {
                        case 1: frac = fracVal / 10.0
                        case 2: frac = fracVal / 100.0
                        default: frac = fracVal / 1000.0
                        }
                    }
                }
                let time = max(0, minutes * 60.0 + seconds + frac + globalOffsetSeconds)
                entries.append((time: time, text: cleanedText))
            }
        }

        if !entries.isEmpty {
            entries.sort { $0.time < $1.time }
            var merged: [LyricLine] = []
            for entry in entries {
                if let last = merged.last, abs(last.time - entry.time) <= 0.08 {
                    if last.translation == nil && last.text != entry.text {
                        merged[merged.count - 1].translation = entry.text
                    }
                } else {
                    merged.append(LyricLine(time: entry.time, text: entry.text))
                }
            }
            return ParsedLyricsResult(
                lines: merged,
                hasTimestamps: true,
                titleTag: titleTag,
                artistTag: artistTag,
                albumTag: albumTag
            )
        }

        // Plain-text lyrics fallback (manual step navigation supported)
        let plainLines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { idx, line in
                LyricLine(time: TimeInterval(idx) * 3.5, text: line)
            }

        return ParsedLyricsResult(
            lines: plainLines,
            hasTimestamps: false,
            titleTag: titleTag,
            artistTag: artistTag,
            albumTag: albumTag
        )
    }

    static func activeLineIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var result: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time + 0.08 {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

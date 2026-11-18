import AppIntents
import Foundation

public enum LyricLiveCommand: Sendable {
    case togglePlay
    case previous
    case next
    case nudgeBackward
    case nudgeForward
}

@MainActor
public enum LiveActivityCommandBridge {
    public static var handler: (@MainActor (LyricLiveCommand) -> Void)?
}

public struct ToggleLyricPlayIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "播放或暫停歌詞"
    public static let isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            LiveActivityCommandBridge.handler?(.togglePlay)
        }
        return .result()
    }
}

public struct PreviousLyricItemIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "上一首或上一句"
    public static let isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            LiveActivityCommandBridge.handler?(.previous)
        }
        return .result()
    }
}

public struct NextLyricItemIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "下一首或下一句"
    public static let isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            LiveActivityCommandBridge.handler?(.next)
        }
        return .result()
    }
}

public struct NudgeLyricsBackwardIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "歌詞延後 0.5 秒"
    public static let isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            LiveActivityCommandBridge.handler?(.nudgeBackward)
        }
        return .result()
    }
}

public struct NudgeLyricsForwardIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "歌詞提前 0.5 秒"
    public static let isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            LiveActivityCommandBridge.handler?(.nudgeForward)
        }
        return .result()
    }
}

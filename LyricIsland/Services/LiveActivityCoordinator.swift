import ActivityKit
import Foundation

@MainActor
final class LiveActivityCoordinator {
    private var currentActivity: Activity<LyricActivityAttributes>?
    private var lastSentState: LyricActivityAttributes.ContentState?
    private var lastUpdateDate: Date = .distantPast

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var hasActiveActivity: Bool {
        if let currentActivity {
            return currentActivity.activityState == .active || currentActivity.activityState == .stale
        }
        return !Activity<LyricActivityAttributes>.activities.isEmpty
    }

    func restoreExistingIfAny() {
        currentActivity = Activity<LyricActivityAttributes>.activities.first
    }

    func startOrUpdate(state: LyricActivityAttributes.ContentState, forceRestart: Bool = false) async -> String? {
        guard areActivitiesEnabled else {
            return "請至 iOS「設定 > 靈動歌詞」開啟「即時動態」權限。"
        }

        if forceRestart {
            await endAll()
        }

        if currentActivity == nil || currentActivity?.activityState == .ended || currentActivity?.activityState == .dismissed {
            await endAll()
            let attributes = LyricActivityAttributes(activityId: "lyric-island-primary")
            let content = ActivityContent(state: state, staleDate: computeStaleDate(for: state))
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                currentActivity = activity
                lastSentState = state
                lastUpdateDate = Date()
                return nil
            } catch {
                return "無法啟動靈動島：\(error.localizedDescription)"
            }
        }

        guard let activity = currentActivity else { return nil }
        guard shouldPushUpdate(newState: state) else { return nil }

        let content = ActivityContent(state: state, staleDate: computeStaleDate(for: state))
        await activity.update(content)
        lastSentState = state
        lastUpdateDate = Date()
        return nil
    }

    func endAll() async {
        for activity in Activity<LyricActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        lastSentState = nil
    }

    private func computeStaleDate(for state: LyricActivityAttributes.ContentState) -> Date {
        if state.isPlaying {
            let remaining = max(state.durationSeconds - state.elapsedSeconds, 10)
            return Date().addingTimeInterval(min(remaining + 30, 3600))
        }
        return Date().addingTimeInterval(1800)
    }

    private func shouldPushUpdate(newState: LyricActivityAttributes.ContentState) -> Bool {
        guard let prev = lastSentState else { return true }

        if prev.trackTitle != newState.trackTitle ||
            prev.artistName != newState.artistName ||
            prev.currentLine != newState.currentLine ||
            prev.secondaryLine != newState.secondaryLine ||
            prev.isSecondaryTranslation != newState.isSecondaryTranslation ||
            prev.isPlaying != newState.isPlaying ||
            prev.displayStyle != newState.displayStyle ||
            prev.sourceLabel != newState.sourceLabel ||
            abs(prev.offsetSeconds - newState.offsetSeconds) > 0.05 ||
            (prev.artworkThumb == nil && newState.artworkThumb != nil) {
            return true
        }

        // Detect manual seek / timeline jump (> 1.4s drift from predicted wall-clock elapsed)
        let dt = newState.referenceTimestamp - prev.referenceTimestamp
        let predictedElapsed = prev.isPlaying ? (prev.elapsedSeconds + max(0, dt)) : prev.elapsedSeconds
        if abs(predictedElapsed - newState.elapsedSeconds) > 1.4 {
            return true
        }

        return false
    }
}

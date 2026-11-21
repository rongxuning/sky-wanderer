import ActivityKit
import Foundation

/// Lock screen and Dynamic Island for the workout in progress. Updates come from `LiveSession` while the process is running.
@MainActor
final class WorkoutLiveActivityCenter: LiveActivitySink {
    static let shared = WorkoutLiveActivityCenter()

    private var activity: Activity<WorkoutActivityAttributes>?
    private var retryAfter = Date.distantPast

    func noteLive(
        sportTitle: String,
        elapsed: TimeInterval,
        distanceMeters: Double,
        paceSecPerKm: Double,
        heartRate: Double,
        paused: Bool
    ) {
        let state = WorkoutActivityAttributes.ContentState(
            elapsed: elapsed,
            distanceMeters: distanceMeters,
            paceSecPerKm: paceSecPerKm,
            heartRate: heartRate,
            paused: paused
        )
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard Date() >= retryAfter else { return }
        do {
            activity = try Activity.request(
                attributes: WorkoutActivityAttributes(sportTitle: sportTitle),
                content: content,
                pushType: nil
            )
        } catch {
            retryAfter = Date().addingTimeInterval(30)
        }
    }

    func endLive() {
        let current = activity
        activity = nil
        retryAfter = .distantPast
        Task {
            await current?.end(nil, dismissalPolicy: .immediate)
            for existing in Activity<WorkoutActivityAttributes>.activities where existing.id != current?.id {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

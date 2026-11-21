import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WorkoutLiveWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveWidget()
    }
}

struct WorkoutLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            lockScreen(context)
                .padding(14)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandTime(context.state, stale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    islandDistance(context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(LiveActivityText.pace(context.state.paceSecPerKm))  心率 \(LiveActivityText.heart(context.state.heartRate))")
                        .font(.caption)
                        .lineLimit(1)
                }
            } compactLeading: {
                islandTime(context.state, stale: context.isStale)
            } compactTrailing: {
                islandDistance(context.state)
            } minimal: {
                Image(systemName: "figure.run")
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.attributes.sportTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LiveActivityText.ink)
            HStack(alignment: .top, spacing: 16) {
                metric("总时间", timeValue(context.state, stale: context.isStale))
                metric("总距离", Text(LiveActivityText.kilometers(context.state.distanceMeters)), unit: "公里")
            }
            HStack(alignment: .top, spacing: 16) {
                metric("配速", Text(LiveActivityText.pace(context.state.paceSecPerKm)), unit: "每公里")
                metric("心率", Text(LiveActivityText.heart(context.state.heartRate)), unit: context.state.heartRate > 0 ? "次/分" : "无来源")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: Text, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(LiveActivityText.secondary)
            value
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(LiveActivityText.primary)
                .lineLimit(1)
            if let unit {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(LiveActivityText.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeValue(_ state: WorkoutActivityAttributes.ContentState, stale: Bool) -> Text {
        if state.paused || stale {
            return Text(LiveActivityText.clock(state.elapsed)).monospacedDigit()
        }
        return Text(Date().addingTimeInterval(-max(0, state.elapsed)), style: .timer).monospacedDigit()
    }

    private func islandTime(_ state: WorkoutActivityAttributes.ContentState, stale: Bool) -> some View {
        timeValue(state, stale: stale)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
    }

    private func islandDistance(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        Text(LiveActivityText.kilometers(state.distanceMeters))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
    }
}

private enum LiveActivityText {
    static let primary = Color(red: 30 / 255, green: 136 / 255, blue: 254 / 255)
    static let ink = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    static func kilometers(_ meters: Double) -> String {
        String(format: "%.2f", max(0, meters) / 1000)
    }

    static func pace(_ secondsPerKm: Double) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0, secondsPerKm < 3_600 else { return "—" }
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d'%02d\"", total / 60, total % 60)
    }

    static func heart(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return String(Int(value.rounded()))
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

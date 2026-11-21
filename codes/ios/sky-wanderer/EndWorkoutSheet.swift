import SwiftUI

/// End of a workout. Metrics, then the choice to keep the track as a route. No share action.
struct EndWorkoutSheet: View {
    var record: WorkoutRecord
    var onDone: (Bool) -> Void
    @State private var keepRoute = false

    var body: some View {
        VStack(alignment: .leading, spacing: SkyTheme.Spacing.section) {
            Text(record.sport.title)
                .font(SkyTheme.Font.title)
                .foregroundStyle(SkyTheme.Color.ink)
            HStack(alignment: .top, spacing: 12) {
                column("总时间", Format.clock(record.trainingDuration))
                column("总距离", Format.kilometers(record.distanceMeters), unit: "公里")
            }
            HStack(alignment: .top, spacing: 8) {
                column("配速", Format.pace(record.averagePaceSecPerKm), unit: "每公里")
                column(
                    "心率",
                    Format.integer(record.resolvedAverageHeartRate),
                    unit: record.resolvedAverageHeartRate > 0 ? "次/分" : "无来源"
                )
                column("步频", Format.integer(record.averageCadence), unit: "步/分")
            }
            if let climb {
                Text(climb)
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.ink)
            }
            Button {
                keepRoute.toggle()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: keepRoute ? "checkmark.square.fill" : "square")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(canKeep ? SkyTheme.Color.primary : SkyTheme.Color.tertiary)
                    Text("是否保留本次运动轨迹作为路线")
                        .font(SkyTheme.Font.body)
                        .foregroundStyle(canKeep ? SkyTheme.Color.ink : SkyTheme.Color.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canKeep)
            .accessibilityAddTraits(keepRoute ? .isSelected : [])
            Spacer(minLength: 0)
            Button {
                onDone(keepRoute && canKeep)
            } label: {
                Text("完成")
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
                    .background(SkyTheme.Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(SkyTheme.Spacing.screenInset)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SkyTheme.Color.grouped)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var canKeep: Bool { record.route.count >= 2 }

    private var climb: String? {
        let meters = Int(record.elevationGainMeters.rounded())
        guard meters >= 1 else { return nil }
        return "爬升 \(meters) 米"
    }

    private func column(_ title: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
            Text(value)
                .font(SkyTheme.Font.title2)
                .monospacedDigit()
                .foregroundStyle(SkyTheme.Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let unit {
                Text(unit)
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

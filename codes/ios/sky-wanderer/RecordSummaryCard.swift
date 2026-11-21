import SwiftUI

/// White record card. Sport and date on top, distance and training time
/// across the middle, pace / heart rate / load / score along the bottom.
/// The motivation line and cadence are not drawn.
struct RecordSummaryCard: View {
    var workout: WorkoutRecord
    var explainSpace: String
    var onExplainMetrics: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CGFloat(RecordListCardLayout.corner), style: .continuous)
    }

    /// Default content size keeps the 90pt line boxes. Larger sizes grow.
    private var usesStandardMetrics: Bool { dynamicTypeSize == .large }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            metrics
                .padding(.leading, CGFloat(RecordListCardLayout.contentLeading))
                .padding(.vertical, CGFloat(RecordListCardLayout.contentInsetVertical))
                .frame(
                    maxWidth: CGFloat(RecordListCardLayout.informationWidth + RecordListCardLayout.contentLeading),
                    alignment: .leading
                )
            Spacer(minLength: CGFloat(RecordListCardLayout.minimumMapGap))
            RecordRouteThumbnail(route: workout.route)
                .padding(.trailing, CGFloat(RecordListCardLayout.mapTrailing))
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: CGFloat(RecordListCardLayout.standardHeight), alignment: .center)
        .frame(height: usesStandardMetrics ? CGFloat(RecordListCardLayout.standardHeight) : nil)
        .background(SkyTheme.Color.card, in: cardShape)
        .clipShape(cardShape)
        .background(alignment: .bottom) {
            RecordCardShadow()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("指标说明")) {
            onExplainMetrics()
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: CGFloat(RecordListCardLayout.topToMiddle)) {
            titleRow
            VStack(alignment: .leading, spacing: CGFloat(RecordListCardLayout.middleToBottom)) {
                HStack(spacing: CGFloat(RecordListCardLayout.columnGap)) {
                    metric(distanceText, distanceFont, SkyTheme.Color.Metric.distance)
                    metric(RecordListCardText.clock(workout.trainingDuration), durationFont, SkyTheme.Color.Metric.duration)
                }
                .modifier(RecordRowBox(height: RecordListCardLayout.upperLine, enabled: usesStandardMetrics))
                HStack(spacing: CGFloat(RecordListCardLayout.columnGap)) {
                    metric(RecordListCardText.pace(workout.averagePaceSecPerKm), lowerFont, SkyTheme.Color.Metric.pace)
                    metric(RecordListCardText.heartRate(workout.resolvedAverageHeartRate), lowerFont, SkyTheme.Color.Metric.heartRate)
                    explainable(RecordListCardText.load(workout.sessionLoad), SkyTheme.Color.Metric.load)
                    explainable(RecordListCardText.score, SkyTheme.Color.Metric.score)
                }
                .modifier(RecordRowBox(height: RecordListCardLayout.lowerLine, enabled: usesStandardMetrics))
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: SkyTheme.Spacing.related) {
            Text(workout.sport.title)
                .font(sportFont)
                .foregroundStyle(SkyTheme.Color.ink)
                .lineLimit(1)
                .layoutPriority(1)
            Text(RecordListCardText.started(workout.start))
                .font(dateFont)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(usesStandardMetrics ? 1 : 3)
                .minimumScaleFactor(usesStandardMetrics ? 0.65 : 0.85)
                .allowsTightening(true)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .modifier(RecordRowBox(height: RecordListCardLayout.titleLine, enabled: usesStandardMetrics))
    }

    private func metric(_ text: String, _ font: Font, _ color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(figureColor(text, color))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(usesStandardMetrics ? 0.6 : 0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Load and score open the explanation. The clear control above this cell,
    /// outside the row's navigation link, takes the tap.
    private func explainable(_ text: String, _ color: Color) -> some View {
        Button(action: onExplainMetrics) {
            Text(text)
                .font(lowerFont)
                .foregroundStyle(figureColor(text, color))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(usesStandardMetrics ? 0.6 : 0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RecordExplainFramesKey.self,
                    value: [proxy.frame(in: .named(explainSpace))]
                )
            }
        }
        .accessibilityHidden(true)
    }

    private var sportFont: Font {
        .system(size: 12, weight: .semibold, relativeTo: .caption)
    }

    private var dateFont: Font {
        .system(size: 11, weight: .regular, relativeTo: .caption2)
    }

    private var distanceFont: Font {
        .system(size: 20, weight: .bold, relativeTo: .title3)
    }

    private var durationFont: Font {
        .system(size: 18, weight: .bold, relativeTo: .headline)
    }

    private var lowerFont: Font {
        .system(size: 14, weight: .bold, relativeTo: .subheadline)
    }

    private var distanceText: String {
        RecordListCardText.distance(workout.distanceMeters)
    }

    private func figureColor(_ text: String, _ color: Color) -> Color {
        text == "—" ? SkyTheme.Color.secondary : color
    }

    private var accessibilitySummary: String {
        let heart = RecordListCardText.heartRate(workout.resolvedAverageHeartRate)
        let spokenHeart = heart == "—" ? heart : "\(heart)次每分"
        let map = workout.route.count >= 2
            ? "有轨迹，\(SkyBasemapCenter.shared.caption)"
            : "这次没有轨迹"
        return [
            workout.sport.title,
            RecordListCardText.started(workout.start),
            "距离 \(distanceText)",
            "训练时间 \(RecordListCardText.clock(workout.trainingDuration))",
            "平均配速 \(RecordListCardText.pace(workout.averagePaceSecPerKm))",
            "平均心率 \(spokenHeart)",
            "训练负荷 \(RecordListCardText.load(workout.sessionLoad))",
            "训练评分 \(RecordListCardText.score)",
            map
        ].joined(separator: "，")
    }
}

/// Downward shadow approximating
/// `0 5pt 8pt -3pt rgba(0,0,0,0.18), 0 2pt 3pt -1pt rgba(0,0,0,0.10)`.
/// The source is only the bottom band, inset by the negative spread, so the
/// card does not pick up a dark halo on the top and sides.
private struct RecordCardShadow: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(RecordListCardLayout.corner), style: .continuous)
        ZStack(alignment: .bottom) {
            shape
                .fill(Color.black.opacity(0.18))
                .padding(.horizontal, 3)
                .frame(height: 22)
                .blur(radius: 4)
                .offset(y: 6)
            shape
                .fill(Color.black.opacity(0.10))
                .padding(.horizontal, 1)
                .frame(height: 10)
                .blur(radius: 1.5)
                .offset(y: 3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RecordRowBox: ViewModifier {
    var height: Double
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.frame(height: CGFloat(height), alignment: .center)
        } else {
            content
        }
    }
}

struct RecordExplainFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

struct RecordMetricHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: SkyTheme.Spacing.related) {
                Text(RecordMetricHelp.title)
                    .font(SkyTheme.Font.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(SkyTheme.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SkyTheme.Spacing.related)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SkyTheme.Color.nickname)
                        .frame(width: SkyTheme.Spacing.touchMin, height: SkyTheme.Spacing.touchMin)
                        .background(SkyTheme.Color.grouped, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            section(RecordMetricHelp.loadTitle, RecordMetricHelp.loadBody)
            section(RecordMetricHelp.scoreTitle, RecordMetricHelp.scoreBody)
            Text(RecordMetricHelp.missing)
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SkyTheme.Color.card)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(SkyTheme.Color.ink)
            Text(body)
                .font(.system(size: 14, weight: .regular, relativeTo: .subheadline))
                .foregroundStyle(SkyTheme.Color.nickname)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
    }
}

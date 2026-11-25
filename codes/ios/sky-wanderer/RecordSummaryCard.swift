import SwiftUI

/// Full-width record card. Map or sport-color plate on the left; sport chip with
/// start time, distance / duration, and secondary metrics with units on the right.
/// Missing secondary values are omitted. Cadence and the motivation line stay off.
struct RecordSummaryCard: View {
    var workout: WorkoutRecord
    var explainSpace: String
    var onExplainMetrics: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var sportSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var dateSize: CGFloat = 13
    @ScaledMetric(relativeTo: .title2) private var distanceSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var durationSize: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var lowerSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var unitSize: CGFloat = 11
    @State private var metricsHeight: CGFloat = CGFloat(RecordListCardLayout.mapSide)

    /// Default content size keeps the measured line boxes. Larger sizes grow.
    private var usesStandardMetrics: Bool { dynamicTypeSize == .large }

    private var secondaryMetrics: [RecordListSecondaryMetric] {
        RecordListSecondaryMetric.visible(in: workout)
    }

    private var mapHeight: CGFloat {
        max(metricsHeight, CGFloat(RecordListCardLayout.mapSide))
    }

    var body: some View {
        HStack(alignment: .top, spacing: CGFloat(RecordListCardLayout.mapToContent)) {
            visual
                .frame(width: CGFloat(RecordListCardLayout.mapSide), height: mapHeight)
            metrics
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: RecordMetricsHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .padding(.leading, CGFloat(RecordListCardLayout.mapLeading))
        .padding(.trailing, CGFloat(RecordListCardLayout.contentTrailing))
        .padding(.vertical, CGFloat(RecordListCardLayout.contentInsetVertical))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: CGFloat(RecordListCardLayout.standardHeight), alignment: .top)
        .background(SkyTheme.Color.card)
        .onPreferenceChange(RecordMetricsHeightKey.self) { height in
            if abs(height - metricsHeight) > 0.5 {
                metricsHeight = height
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("指标说明")) {
            onExplainMetrics()
        }
    }

    @ViewBuilder
    private var visual: some View {
        if workout.route.count >= 2 {
            RecordRouteThumbnail(
                workoutID: workout.id,
                route: workout.route,
                width: CGFloat(RecordListCardLayout.mapSide),
                height: mapHeight
            )
        } else {
            RecordSportSwatch(sport: workout.sport)
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            Spacer()
                .frame(height: CGFloat(RecordListCardLayout.titleToMiddle))
            HStack(spacing: 0) {
                if showsRouteMetrics {
                    primaryMetric(distanceText, distanceFont, SkyTheme.Color.recordDistance)
                } else {
                    primaryMetric(energyText, distanceFont, SkyTheme.Color.Metric.energy)
                }
                primaryMetric(
                    RecordListCardText.clock(workout.trainingDuration),
                    durationFont,
                    SkyTheme.Color.sport(workout.sport)
                )
            }
            .modifier(RecordRowBox(height: RecordListCardLayout.upperLine, enabled: usesStandardMetrics))
            Spacer()
                .frame(height: CGFloat(RecordListCardLayout.middleToBottom))
            if !secondaryMetrics.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(secondaryMetrics) { item in
                        secondaryCell(item)
                    }
                }
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(workout.sport.title)
                .font(sportFont)
                .foregroundStyle(SkyTheme.Color.onPrimary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    SkyTheme.Color.sport(workout.sport),
                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                )
                .fixedSize(horizontal: true, vertical: true)
            Text(RecordListCardText.started(workout.start))
                .font(dateFont)
                .foregroundStyle(SkyTheme.Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RecordRowBox(height: RecordListCardLayout.titleLine, enabled: usesStandardMetrics))
    }

    private func primaryMetric(_ text: String, _ font: Font, _ color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(figureColor(text, color))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(usesStandardMetrics ? 0.6 : 0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func secondaryCell(_ item: RecordListSecondaryMetric) -> some View {
        let content = VStack(alignment: .leading, spacing: CGFloat(RecordListCardLayout.lowerUnitGap)) {
            HStack(spacing: 4) {
                RecordListMetricIcon(column: item.column)
                Text(item.value)
                    .font(lowerFont)
                    .foregroundStyle(SkyTheme.Color.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(usesStandardMetrics ? 0.6 : 0.8)
            }
            Text(item.unit)
                .font(unitFont)
                .foregroundStyle(SkyTheme.Color.secondary)
                .padding(.leading, 18)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if item.column == .load || item.column == .score {
            Button(action: onExplainMetrics) {
                content
            }
            .buttonStyle(.borderless)
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
        } else {
            content
        }
    }

    private var sportFont: Font {
        .system(size: sportSize, weight: .semibold)
    }

    private var dateFont: Font {
        .system(size: dateSize, weight: .regular)
    }

    private var distanceFont: Font {
        .system(size: distanceSize, weight: .bold)
    }

    private var durationFont: Font {
        .system(size: durationSize, weight: .bold)
    }

    private var lowerFont: Font {
        .system(size: lowerSize, weight: .medium)
    }

    private var unitFont: Font {
        .system(size: unitSize, weight: .regular)
    }

    private var distanceText: String {
        RecordListCardText.distance(workout.distanceMeters)
    }

    private var energyText: String {
        RecordListCardText.energy(workout.energyKilocalories)
    }

    private var showsRouteMetrics: Bool { workout.sport.listShowsRouteMetrics }

    private func figureColor(_ text: String, _ color: Color) -> Color {
        text == "—" ? SkyTheme.Color.secondary : color
    }

    private var accessibilitySummary: String {
        let heart = RecordListCardText.heartRate(workout.resolvedAverageHeartRate)
        let spokenHeart = heart == "—" ? heart : "\(heart)次每分"
        var parts: [String] = [
            workout.sport.title,
            RecordListCardText.started(workout.start)
        ]
        if showsRouteMetrics {
            parts.append("距离 \(distanceText)")
        } else {
            parts.append("消耗 \(energyText)")
        }
        parts.append("训练时间 \(RecordListCardText.clock(workout.trainingDuration))")
        for item in secondaryMetrics {
            switch item.column {
            case .heartRate:
                parts.append("平均心率 \(spokenHeart)")
            case .pace:
                parts.append("平均配速 \(item.value)")
            case .load:
                parts.append("训练负荷 \(item.value)")
            case .score:
                parts.append("训练评分 \(item.value)")
            }
        }
        if workout.route.count >= 2 {
            parts.append("有轨迹")
        }
        return parts.joined(separator: "，")
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

private struct RecordMetricsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RecordExplainFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

/// Leading glyph for a secondary list metric.
struct RecordListMetricIcon: View {
    var column: RecordListMetricColumn

    var body: some View {
        Group {
            switch column {
            case .heartRate:
                Image(systemName: "heart.fill")
                    .foregroundStyle(SkyTheme.Color.Metric.heartRate)
            case .pace:
                Image(systemName: "bolt.fill")
                    .foregroundStyle(SkyTheme.Color.recordPaceIcon)
            case .load:
                ZStack {
                    Image(systemName: "triangle.fill")
                        .foregroundStyle(SkyTheme.Color.recordLoadIcon)
                    VStack(spacing: 1) {
                        Capsule()
                            .fill(SkyTheme.Color.onPrimary)
                            .frame(width: 1.6, height: 4.2)
                        Circle()
                            .fill(SkyTheme.Color.onPrimary)
                            .frame(width: 1.9, height: 1.9)
                    }
                    .offset(y: 0.6)
                }
            case .score:
                ZStack {
                    Circle()
                        .stroke(SkyTheme.Color.recordScoreIcon.opacity(0.22), lineWidth: 2.2)
                    Circle()
                        .trim(from: 0.08, to: 0.78)
                        .stroke(
                            SkyTheme.Color.recordScoreIcon,
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

struct RecordMetricHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .subheadline) private var bodySize: CGFloat = 14

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
                .font(.system(size: bodySize, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.ink)
            Text(body)
                .font(.system(size: bodySize, weight: .regular))
                .foregroundStyle(SkyTheme.Color.nickname)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
    }
}

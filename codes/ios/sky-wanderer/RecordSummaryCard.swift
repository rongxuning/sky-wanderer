import SwiftUI

/// Full-width record card. Fixed map square on the left — track, start pin, or
/// the full-color Sky empty mark when there is no coordinate. 力量训练 /
/// 综合训练 still map a start fix when one exists; without a fix they use the
/// same empty mark as other sports. The metrics stack keeps the same fixed
/// height as the map (`RecordListCardLayout.mapSide`). Date sits on the right
/// of the title row. Secondary metrics are the value only; load appends TL.
/// Missing values are omitted.
struct RecordSummaryCard: View {
    var workout: WorkoutRecord
    var explainSpace: String
    var onExplainMetrics: () -> Void

    @ScaledMetric(relativeTo: .callout) private var sportSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var dateSize: CGFloat = 13
    /// Two points smaller than the previous 27pt primary figure.
    @ScaledMetric(relativeTo: .title) private var distanceSize: CGFloat = 25
    @ScaledMetric(relativeTo: .subheadline) private var lowerSize: CGFloat = 14

    /// Always one point larger than the date/time on the title row.
    private var durationSize: CGFloat { dateSize + 1 }

    private var secondaryMetrics: [RecordListSecondaryMetric] {
        RecordListSecondaryMetric.visible(in: workout)
    }

    private var mapSide: CGFloat { CGFloat(RecordListCardLayout.mapSide) }

    var body: some View {
        HStack(alignment: .top, spacing: CGFloat(RecordListCardLayout.mapToContent)) {
            visual
                .frame(width: mapSide, height: mapSide)
            metrics
                .frame(
                    maxWidth: .infinity,
                    minHeight: mapSide,
                    maxHeight: mapSide,
                    alignment: .topLeading
                )
        }
        .padding(.leading, CGFloat(RecordListCardLayout.mapLeading))
        .padding(.trailing, CGFloat(RecordListCardLayout.contentTrailing))
        .padding(.vertical, CGFloat(RecordListCardLayout.contentInsetVertical))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: CGFloat(RecordListCardLayout.standardHeight), alignment: .top)
        .background(SkyTheme.Color.card)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("指标说明")) {
            onExplainMetrics()
        }
    }

    @ViewBuilder
    private var visual: some View {
        let kind = RecordListThumbnailKind.resolve(routeCount: workout.listThumbnailPointCount)
        // No usable coordinate — full-color Sky empty mark for every sport,
        // including 力量 / 综合 that would otherwise keep a blank map plate.
        if kind == .swatch {
            RecordSportSwatch(side: mapSide)
        } else {
            RecordRouteThumbnail(
                workoutID: workout.id,
                route: workout.listThumbnailRoute,
                width: mapSide,
                height: mapSide,
                routePointCount: workout.listThumbnailPointCount
            )
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            Spacer()
                .frame(height: CGFloat(RecordListCardLayout.titleToMiddle))
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                if showsRouteMetrics {
                    primaryMetric(
                        distanceText,
                        distanceFont,
                        SkyTheme.Color.ink,
                        alignment: .leading
                    )
                } else {
                    primaryMetric(
                        energyText,
                        distanceFont,
                        SkyTheme.Color.ink,
                        alignment: .leading
                    )
                }
                primaryMetric(
                    RecordListCardText.clock(workout.trainingDuration),
                    durationFont,
                    SkyTheme.Color.secondary,
                    alignment: .trailing
                )
            }
            .frame(height: CGFloat(RecordListCardLayout.upperLine), alignment: .bottom)
            Spacer()
                .frame(height: CGFloat(RecordListCardLayout.middleToBottom))
            // Equal-width columns. First leading, middle centered, last trailing
            // so gaps read evenly and the last cell shares duration’s right edge.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(secondaryMetrics.enumerated()), id: \.element.id) { index, item in
                    secondaryCell(
                        item,
                        alignment: Self.frameAlignment(
                            RecordListSecondaryColumnAlign.resolve(
                                index: index,
                                count: secondaryMetrics.count
                            )
                        )
                    )
                }
            }
            .frame(height: CGFloat(RecordListCardLayout.lowerBlock), alignment: .top)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(workout.sport.title)
                .font(sportFont)
                .foregroundStyle(SkyTheme.Color.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
            Text(RecordListCardText.started(workout.start))
                .font(dateFont)
                .foregroundStyle(SkyTheme.Color.starryGray)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RecordRowBox(height: RecordListCardLayout.titleLine))
    }

    private func primaryMetric(
        _ text: String,
        _ font: Font,
        _ color: Color,
        alignment: Alignment
    ) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(figureColor(text, color))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private static func frameAlignment(_ align: RecordListSecondaryColumnAlign) -> Alignment {
        switch align {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    @ViewBuilder
    private func secondaryCell(_ item: RecordListSecondaryMetric, alignment: Alignment) -> some View {
        let content = HStack(alignment: .center, spacing: 4) {
            RecordListMetricIcon(column: item.column)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.value)
                    .font(lowerFont)
                    .foregroundStyle(SkyTheme.Color.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if item.column == .load {
                    Text(item.unit)
                        .font(lowerFont)
                        .foregroundStyle(SkyTheme.Color.ink)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)

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
        .system(size: durationSize, weight: .regular)
    }

    private var lowerFont: Font {
        .system(size: lowerSize, weight: .medium)
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
                parts.append("训练负荷 \(item.value) \(item.unit)")
            case .score:
                parts.append("训练评分 \(item.value)")
            }
        }
        switch RecordListThumbnailKind.resolve(routeCount: workout.listThumbnailPointCount) {
        case .track:
            parts.append("有轨迹")
        case .startPoint:
            parts.append("有训练地点")
        case .swatch:
            break
        }
        return parts.joined(separator: "，")
    }
}

private struct RecordRowBox: ViewModifier {
    var height: Double

    func body(content: Content) -> some View {
        content.frame(height: CGFloat(height), alignment: .center)
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

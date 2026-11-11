import SwiftUI

/// Analysis tab body. The period control feeds `AnalysisPageFrame`, which changes
/// training stats only. The score card stays on `AnalysisScorePlaceholder`.
struct AnalysisBoard: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var window: StatsWindow = .week
    /// Fixed when the page appears, so a period tap cannot move the score sample.
    @State private var scoreClock = Date()

    private var snapshot: AnalysisPageSnapshot {
        AnalysisPageFrame.snapshot(workouts: app.workouts, window: window, now: scoreClock)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SkyTheme.Spacing.section) {
                statsCard(snapshot.stats)
                AnalysisScoreCardView(model: snapshot.score)
            }
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, SkyTheme.Spacing.related)
            .padding(.bottom, SkyTheme.Spacing.section)
        }
        .scrollIndicators(.hidden)
        .background(SkyTheme.Color.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statsCard(_ stats: TrainingStats) -> some View {
        HStack(alignment: .center, spacing: AnalysisStatsMetrics.gap) {
            periodColumn
                .frame(width: AnalysisStatsMetrics.periodWidth)
            statsGrid(stats)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            // The line sits in the gap. It is a background so it takes the row's height
            // without stretching the card the way a flexible Rectangle in the HStack would.
            HStack(spacing: 0) {
                Color.clear.frame(width: AnalysisStatsMetrics.periodWidth)
                Rectangle()
                    .fill(SkyTheme.Color.tertiary)
                    .frame(width: 1)
                    .padding(.leading, AnalysisStatsMetrics.gap / 2)
                Spacer(minLength: 0)
            }
        }
        .analysisCardSurface()
    }

    private var periodColumn: some View {
        VStack(spacing: 4) {
            ForEach(StatsWindow.allCases) { item in
                let selected = window == item
                Button {
                    window = item
                } label: {
                    Text(item.rawValue)
                        .font(SkyTheme.Font.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(selected ? SkyTheme.Color.onPrimary : SkyTheme.Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
                        .background {
                            if selected {
                                Capsule().fill(SkyTheme.Color.primary)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.easeInOut(duration: 0.18), value: window)
    }

    private func statsGrid(_ stats: TrainingStats) -> some View {
        let cells: [(String, String)] = [
            ("总距离", distanceText(stats)),
            ("平均配速", Format.pace(stats.averagePaceSecPerKm)),
            ("平均心率", Format.integer(stats.averageHeartRate)),
            ("总爬升", metersText(stats.elevationGainMeters)),
            ("平均步频", Format.integer(stats.averageCadence)),
            ("平均步幅", strideText(stats)),
            ("总负荷", loadText(stats)),
            ("训练评分", scoreText(stats))
        ]
        return VStack(alignment: .leading, spacing: SkyTheme.Spacing.screenInset) {
            ForEach(0..<4, id: \.self) { row in
                HStack(alignment: .top, spacing: 12) {
                    statCell(cells[row * 2].0, cells[row * 2].1)
                    statCell(cells[row * 2 + 1].0, cells[row * 2 + 1].1)
                }
            }
        }
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(SkyTheme.Font.title3)
                .fontWeight(.bold)
                .foregroundStyle(SkyTheme.Color.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func distanceText(_ stats: TrainingStats) -> String {
        guard stats.distanceMeters > 1 else { return "—" }
        return String(format: "%.1f km", stats.distanceMeters / 1000)
    }

    private func metersText(_ meters: Double) -> String {
        guard meters > 0 else { return "—" }
        return "\(Int(meters.rounded())) m"
    }

    private func strideText(_ stats: TrainingStats) -> String {
        guard stats.averageStrideMeters > 0 else { return "—" }
        return "\(Int((stats.averageStrideMeters * 100).rounded())) cm"
    }

    private func loadText(_ stats: TrainingStats) -> String {
        guard stats.totalSessionLoad > 0 else { return "—" }
        return String(Int(stats.totalSessionLoad.rounded()))
    }

    private func scoreText(_ stats: TrainingStats) -> String {
        guard stats.trainingScore > 0 else { return "—" }
        return String(Int(stats.trainingScore.rounded()))
    }
}

private enum AnalysisStatsMetrics {
    static let periodWidth: CGFloat = 52
    static let gap: CGFloat = 12
}

/// 「综合评分」card. Draws `model` as given. It does not read workouts or `StatsWindow`.
struct AnalysisScoreCardView: View {
    var model: AnalysisScoreCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: SkyTheme.Spacing.screenInset) {
            header
            AnalysisRadarChart(scores: AnalysisScorePlaceholder.orderedScores(model.current))
            Text("近三个月")
                .font(SkyTheme.Font.headline)
                .fontWeight(.semibold)
                .foregroundStyle(SkyTheme.Color.ink)
                .accessibilityAddTraits(.isHeader)
            trendGrid
        }
        .analysisCardSurface()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: SkyTheme.Spacing.related) {
            Text("综合评分")
                .font(SkyTheme.Font.headline)
                .fontWeight(.semibold)
                .foregroundStyle(SkyTheme.Color.ink)
            Spacer(minLength: SkyTheme.Spacing.related)
            Text("\(model.composite)")
                .font(SkyTheme.Font.title2)
                .fontWeight(.bold)
                .foregroundStyle(SkyTheme.Color.primary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("综合评分 \(model.composite)")
        .accessibilityAddTraits(.isHeader)
    }

    private var trendGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: SkyTheme.Spacing.screenInset),
                GridItem(.flexible(), spacing: SkyTheme.Spacing.screenInset)
            ],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(model.trends, id: \.dimension) { trend in
                AnalysisTrendChart(
                    dimension: trend.dimension,
                    samples: trend.samples,
                    window: model.window,
                    current: model.current[trend.dimension] ?? 0
                )
            }
        }
    }
}

struct AnalysisRadarChart: View {
    /// Clockwise from the top: 体力 through 恢复. Full scale is 100.
    var scores: [Int]

    var body: some View {
        let axisScores = scores
        return GeometryReader { geo in
            let frame = AnalysisRadarFrame.make(in: geo.size)
            ZStack {
                Canvas { context, _ in
                    AnalysisRadarDrawing.grid(in: context, frame: frame)
                    AnalysisRadarDrawing.polygon(in: context, frame: frame, scores: axisScores)
                }
                ForEach(Array(AnalysisScoreDimension.allCases.enumerated()), id: \.element.id) { index, dimension in
                    Text(dimension.title)
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .position(frame.label(index))
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 268)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        let parts = zip(AnalysisScoreDimension.allCases, scores).map { dimension, score in
            "\(dimension.title) \(score)"
        }
        return "八维评分，" + parts.joined(separator: "，")
    }

}

private enum AnalysisRadarDrawing {
    static func grid(in context: GraphicsContext, frame: AnalysisRadarFrame) {
        let style = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        for fraction in AnalysisRadarLayout.ringFractions {
            var path = Path()
            for index in 0..<AnalysisRadarLayout.vertexCount {
                let point = frame.screen(AnalysisRadarLayout.unitVertex(index: index), scale: fraction)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
            context.stroke(path, with: .color(SkyTheme.Color.tertiary), style: style)
        }
        for index in 0..<AnalysisRadarLayout.vertexCount {
            var spoke = Path()
            spoke.move(to: frame.center)
            spoke.addLine(to: frame.screen(AnalysisRadarLayout.unitVertex(index: index), scale: 1))
            context.stroke(spoke, with: .color(SkyTheme.Color.tertiary), style: style)
        }
    }

    static func polygon(in context: GraphicsContext, frame: AnalysisRadarFrame, scores: [Int]) {
        let vertices = AnalysisRadarLayout.polygon(scores: scores)
        guard vertices.count >= 3 else { return }
        var path = Path()
        for (index, vertex) in vertices.enumerated() {
            let point = frame.screen(vertex, scale: 1)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        context.fill(path, with: .color(SkyTheme.Color.primary.opacity(AnalysisRadarLayout.fillOpacity)))
        context.stroke(
            path,
            with: .color(SkyTheme.Color.primary),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
        for vertex in vertices {
            let point = frame.screen(vertex, scale: 1)
            let dot = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(SkyTheme.Color.primary))
        }
    }
}

private struct AnalysisRadarFrame {
    var center: CGPoint
    var radius: CGFloat

    static func make(in size: CGSize) -> AnalysisRadarFrame {
        AnalysisRadarFrame(
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            radius: max(0, min(size.width, size.height) / 2 - 28)
        )
    }

    func screen(_ point: AnalysisChartPoint, scale: Double) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(point.x * scale) * radius,
            y: center.y - CGFloat(point.y * scale) * radius
        )
    }

    func label(_ index: Int) -> CGPoint {
        let unit = AnalysisRadarLayout.unitVertex(index: index)
        let reach = radius + 16
        return CGPoint(
            x: center.x + CGFloat(unit.x) * reach,
            y: center.y - CGFloat(unit.y) * reach
        )
    }
}

struct AnalysisTrendChart: View {
    var dimension: AnalysisScoreDimension
    var samples: [AnalysisScoreSample]
    var window: AnalysisScoreWindow
    var current: Int

    var body: some View {
        let samples = samples
        let window = window
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(dimension.title)
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(current)")
                    .font(SkyTheme.Font.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(SkyTheme.Color.primary)
                    .monospacedDigit()
            }
            Canvas { context, size in
                let points = AnalysisSparklineLayout.normalized(samples: samples, window: window)
                guard points.count >= 2 else { return }
                func place(_ point: AnalysisChartPoint) -> CGPoint {
                    let inset: CGFloat = 2
                    let width = max(size.width - inset * 2, 1)
                    let height = max(size.height - inset * 2, 1)
                    return CGPoint(
                        x: inset + CGFloat(point.x) * width,
                        y: inset + (1 - CGFloat(point.y)) * height
                    )
                }
                let grid = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                for mark in [0.0, 0.5, 1.0] {
                    var line = Path()
                    let y = place(AnalysisChartPoint(x: 0, y: mark)).y
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(SkyTheme.Color.tertiary), style: grid)
                }
                var path = Path()
                path.move(to: place(points[0]))
                for point in points.dropFirst() {
                    path.addLine(to: place(point))
                }
                context.stroke(
                    path,
                    with: .color(SkyTheme.Color.primary),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(height: 48)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dimension.title) \(current)")
    }
}

private extension View {
    func analysisCardSurface() -> some View {
        padding(SkyTheme.Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SkyTheme.Color.card,
                in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
            )
            .shadow(
                color: SkyTheme.Shadow.card.color.opacity(SkyTheme.Shadow.card.opacity),
                radius: SkyTheme.Shadow.card.radius,
                y: SkyTheme.Shadow.card.y
            )
    }
}

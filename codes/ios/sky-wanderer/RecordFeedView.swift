import SwiftUI

/// Records tab. White cards on the grouped background, six metrics beside a track thumbnail.
struct RecordFeedView: View {
    @EnvironmentObject private var app: PhoneAppState

    var body: some View {
        Group {
            if app.workouts.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SkyTheme.Spacing.screenInset) {
                        if !app.banner.isEmpty {
                            Text(app.banner)
                                .font(SkyTheme.Font.footnote)
                                .foregroundStyle(SkyTheme.Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(app.workouts) { workout in
                            NavigationLink(value: RecordRoute.detail(workout.id)) {
                                RecordSummaryCard(workout: workout)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, SkyTheme.Spacing.screenInset)
                    .padding(.top, SkyTheme.Spacing.related)
                    .padding(.bottom, SkyTheme.Spacing.related)
                }
                .scrollClipDisabled()
                .refreshable {
                    await app.importFromApple()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyTheme.Color.grouped)
        .task {
            await app.importFromApple()
        }
    }

    private var empty: some View {
        VStack(spacing: SkyTheme.Spacing.related) {
            Text("还没有训练记录")
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.ink)
            Text("完成一次徒步或跑步后，会出现在这里。")
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
                .multilineTextAlignment(.center)
            if !app.banner.isEmpty {
                Text(app.banner)
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordSummaryCard: View {
    var workout: WorkoutRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RecordTrackThumbnail(points: workout.route, sport: workout.sport)
            HStack(alignment: .top, spacing: SkyTheme.Spacing.related) {
                VStack(alignment: .leading, spacing: 10) {
                    metric("平均心率", value: Format.integer(workout.averageHeartRate), unit: "bpm")
                    metric("训练时长", value: Format.clock(workout.duration), unit: nil)
                    metric("平均步频", value: Format.integer(workout.averageCadence), unit: "spm")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    metric("平均配速", value: Format.pace(workout.averagePaceSecPerKm), unit: "/km")
                    metric("开始时间", value: Format.relativeDayTime(workout.start), unit: nil)
                    metric("动态消耗", value: energyText, unit: "kcal")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(SkyTheme.Color.card, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous))
        .shadow(
            color: SkyTheme.Shadow.card.color.opacity(SkyTheme.Shadow.card.opacity),
            radius: SkyTheme.Shadow.card.radius,
            y: SkyTheme.Shadow.card.y
        )
        .accessibilityElement(children: .combine)
    }

    private var energyText: String {
        guard workout.energyKilocalories > 0 else { return "—" }
        return String(Int(workout.energyKilocalories.rounded()))
    }

    private func metric(_ title: String, value: String, unit: String?) -> some View {
        let shownUnit = value == "—" ? nil : unit
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let shownUnit {
                    Text(shownUnit)
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title == "开始时间" ? "训练开始时间" : title)
        .accessibilityValue(shownUnit.map { "\(value) \($0)" } ?? value)
    }
}

struct RecordTrackThumbnail: View {
    var points: [GeoPoint]
    var sport: SportKind

    var body: some View {
        ZStack {
            SkyTheme.Color.cardBorder
            roadHints
            if points.count >= 2 {
                trackLayer
            } else {
                Image(systemName: sport == .running ? "figure.run" : "figure.hiking")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(SkyTheme.Color.primary)
            }
        }
        .frame(width: 108, height: 116)
        .clipShape(RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous))
        .accessibilityHidden(true)
    }

    private var roadHints: some View {
        Canvas { context, size in
            let roads: [(CGFloat, CGFloat, CGFloat)] = [
                (0.28, 0.42, 0.18),
                (0.62, 0.7, 0.46),
                (0.4, 0.22, 0.55)
            ]
            for (start, end, control) in roads {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height * start))
                path.addQuadCurve(
                    to: CGPoint(x: size.width, y: size.height * end),
                    control: CGPoint(x: size.width * 0.55, y: size.height * control)
                )
                context.stroke(
                    path,
                    with: .color(SkyTheme.Color.separator.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
            }
        }
    }

    private var trackLayer: some View {
        Canvas { context, size in
            let spots = projected(in: size)
            guard spots.count >= 2 else { return }
            var path = Path()
            path.move(to: spots[0])
            for point in spots.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(SkyTheme.Color.primary),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            if let last = spots.last {
                let head = CGRect(x: last.x - 4, y: last.y - 16, width: 8, height: 8)
                context.fill(Path(ellipseIn: head), with: .color(SkyTheme.Color.primary))
                var pin = Path()
                pin.move(to: CGPoint(x: last.x - 4, y: last.y - 9))
                pin.addLine(to: CGPoint(x: last.x + 4, y: last.y - 9))
                pin.addLine(to: last)
                pin.closeSubpath()
                context.fill(pin, with: .color(SkyTheme.Color.primary))
                let hole = CGRect(x: last.x - 1.6, y: last.y - 14.4, width: 3.2, height: 3.2)
                context.fill(Path(ellipseIn: hole), with: .color(SkyTheme.Color.card))
            }
        }
    }

    private func projected(in size: CGSize) -> [CGPoint] {
        guard let first = points.first, points.count >= 2 else { return [] }
        let midLatitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let cosLat = max(cos(midLatitude * .pi / 180), 0.2)
        let east = points.map { CGFloat(($0.longitude - first.longitude) * 111_320 * cosLat) }
        let north = points.map { CGFloat(($0.latitude - first.latitude) * 111_320) }
        let minX = east.min() ?? 0
        let maxX = east.max() ?? 0
        let minY = north.min() ?? 0
        let maxY = north.max() ?? 0
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let pad: CGFloat = 16
        let width = max(size.width - pad * 2, 1)
        let height = max(size.height - pad * 2, 1)
        let scale = min(width / spanX, height / spanY)
        let usedWidth = spanX * scale
        let usedHeight = spanY * scale
        let originX = pad + (width - usedWidth) / 2
        let originY = pad + (height - usedHeight) / 2
        return zip(east, north).map { easting, northing in
            CGPoint(
                x: originX + (easting - minX) * scale,
                y: originY + (maxY - northing) * scale
            )
        }
    }
}

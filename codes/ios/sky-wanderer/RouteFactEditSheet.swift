import SwiftUI

enum RouteFactEditTarget: Identifiable, Hashable {
    case totals
    case waypoint(Int)

    var id: String {
        switch self {
        case .totals:
            return "totals"
        case .waypoint(let index):
            return "waypoint-\(index)"
        }
    }
}

/// Edits the fields on one route-detail card. Blank fields clear that override.
/// Segment and cumulative values are saved separately. The GPX file is not changed.
struct RouteFactEditSheet: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss

    var routeID: String
    var target: RouteFactEditTarget

    @State private var name = ""
    @State private var cutoff = ""
    @State private var distance = ""
    @State private var ascent = ""
    @State private var descent = ""
    @State private var peak = ""
    @State private var segmentDistance = ""
    @State private var segmentAscent = ""
    @State private var segmentDescent = ""
    @State private var cumulativeDistance = ""
    @State private var cumulativeAscent = ""
    @State private var cumulativeDescent = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                switch target {
                case .totals:
                    totalsFields
                case .waypoint:
                    waypointFields
                }
                if let error {
                    Text(error)
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.danger)
                }
                Text("留空并保存会恢复为轨迹计算值。分段和累积各自保存，改一边不会改另一边。")
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: load)
    }

    private var title: String {
        switch target {
        case .totals:
            return "编辑总数据"
        case .waypoint(let id):
            guard let route = app.savedRoutes.first(where: { $0.id == routeID }) else { return "编辑检查点" }
            let progress = RouteCheckpoints.progress(waypoints: route.waypoints, points: route.points)
            guard let row = progress.first(where: { $0.id == id }) else { return "编辑检查点" }
            return "编辑 \(RouteFacts.displayWaypoint(row, route: route).name)"
        }
    }

    private var totalsFields: some View {
        Group {
            numberField("距离", text: $distance, unit: "公里")
            numberField("爬升", text: $ascent, unit: "米")
            numberField("下降", text: $descent, unit: "米")
            numberField("最高海拔", text: $peak, unit: "米")
        }
    }

    private var waypointFields: some View {
        Group {
            textField("名称", text: $name)
            textField("关门时间", text: $cutoff)
            Section("本段") {
                numberField("距离", text: $segmentDistance, unit: "公里")
                numberField("爬升", text: $segmentAscent, unit: "米")
                numberField("下降", text: $segmentDescent, unit: "米")
            }
            Section("累积") {
                numberField("累积距离", text: $cumulativeDistance, unit: "公里")
                numberField("累积爬升", text: $cumulativeAscent, unit: "米")
                numberField("累积下降", text: $cumulativeDescent, unit: "米")
            }
        }
    }

    private func textField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("留空恢复", text: text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func numberField(_ label: String, text: Binding<String>, unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("留空恢复", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(unit)
                    .foregroundStyle(SkyTheme.Color.secondary)
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let route = app.savedRoutes.first(where: { $0.id == routeID }) else { return }
        switch target {
        case .totals:
            let totals = RouteFacts.displayTotals(route)
            distance = Format.kilometers(totals.distanceMeters)
            ascent = metersText(totals.ascentMeters)
            descent = metersText(totals.descentMeters)
            peak = totals.maxElevationMeters.map(metersText) ?? ""
        case .waypoint(let id):
            let progress = RouteCheckpoints.progress(waypoints: route.waypoints, points: route.points)
            guard let row = progress.first(where: { $0.id == id }) else { return }
            let shown = RouteFacts.displayWaypoint(row, route: route)
            name = shown.name
            cutoff = shown.cutoff ?? ""
            segmentDistance = Format.kilometers(shown.segmentDistanceMeters)
            segmentAscent = metersText(shown.segmentAscentMeters)
            segmentDescent = metersText(shown.segmentDescentMeters)
            cumulativeDistance = Format.kilometers(shown.cumulativeDistanceMeters)
            cumulativeAscent = metersText(shown.cumulativeAscentMeters)
            cumulativeDescent = metersText(shown.cumulativeDescentMeters)
        }
    }

    private func save() {
        guard var route = app.savedRoutes.first(where: { $0.id == routeID }) else {
            dismiss()
            return
        }
        switch target {
        case .totals:
            let distanceChange = RouteFacts.parseMeters(distance, kilometers: true)
            let ascentChange = RouteFacts.parseMeters(ascent, kilometers: false)
            let descentChange = RouteFacts.parseMeters(descent, kilometers: false)
            let peakChange = RouteFacts.parseMeters(peak, kilometers: false)
            guard valid(distanceChange, ascentChange, descentChange, peakChange) else { return }
            RouteFacts.applyTotals(
                &route,
                distance: distanceChange,
                ascent: ascentChange,
                descent: descentChange,
                maxElevation: peakChange
            )
        case .waypoint(let id):
            let progress = RouteCheckpoints.progress(waypoints: route.waypoints, points: route.points)
            guard let row = progress.first(where: { $0.id == id }) else {
                dismiss()
                return
            }
            let segmentDistanceChange = RouteFacts.parseMeters(segmentDistance, kilometers: true)
            let segmentAscentChange = RouteFacts.parseMeters(segmentAscent, kilometers: false)
            let segmentDescentChange = RouteFacts.parseMeters(segmentDescent, kilometers: false)
            let cumulativeDistanceChange = RouteFacts.parseMeters(cumulativeDistance, kilometers: true)
            let cumulativeAscentChange = RouteFacts.parseMeters(cumulativeAscent, kilometers: false)
            let cumulativeDescentChange = RouteFacts.parseMeters(cumulativeDescent, kilometers: false)
            guard valid(
                segmentDistanceChange,
                segmentAscentChange,
                segmentDescentChange,
                cumulativeDistanceChange,
                cumulativeAscentChange,
                cumulativeDescentChange
            ) else { return }
            RouteFacts.applyWaypoint(
                &route,
                progress: row,
                name: RouteFacts.parseLabel(name),
                cutoff: RouteFacts.parseLabel(cutoff),
                segmentDistance: segmentDistanceChange,
                segmentAscent: segmentAscentChange,
                segmentDescent: segmentDescentChange,
                cumulativeDistance: cumulativeDistanceChange,
                cumulativeAscent: cumulativeAscentChange,
                cumulativeDescent: cumulativeDescentChange
            )
        }
        app.saveRouteFactOverrides(id: route.id, overrides: route.factOverrides)
        dismiss()
    }

    private func valid(_ changes: RouteFactFieldChange...) -> Bool {
        if changes.contains(where: { if case .invalid = $0 { return true }; return false }) {
            error = "请填写不小于 0 的数字，或留空恢复计算值。"
            return false
        }
        error = nil
        return true
    }

    private func metersText(_ meters: Double) -> String {
        String(Int(meters.rounded()))
    }
}

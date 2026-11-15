import CoreLocation
import SwiftUI

private enum EditTool: String, CaseIterable, Identifiable {
    case pan = "平移"
    case add = "添加"
    case move = "移动"
    case delete = "删除"
    var id: String { rawValue }
}

struct PresetRouteEditor: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var basemap = SkyBasemapCenter.shared
    @State private var points: [GeoPoint] = []
    @State private var loaded = false
    @State private var tool: EditTool = .pan

    var body: some View {
        ZStack {
            editorMap
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.omniInk)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    Text("编辑路线")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Spacer()
                    Button {
                        app.replacePresetRunning(points: points)
                        dismiss()
                    } label: {
                        Text("保存")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.omniCobalt)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glass(radius: 22)
                Spacer()
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        ForEach(EditTool.allCases) { item in
                            Button { tool = item } label: {
                                Text(item.rawValue)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(tool == item ? Color.omniCobalt : Color.omniIdle)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(toolHint)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.omniMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .glass(radius: 22)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .navigationBarHidden(true)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            points = app.savedRoutes.first { $0.kind == .presetRunning }?.points ?? []
        }
    }

    private var toolHint: String {
        switch tool {
        case .pan: return "拖动地图。保存后写在这台手机上。"
        case .add: return "点地图增加一个点。"
        case .move: return "按住一个点拖动。"
        case .delete: return "点一个点删除它。"
        }
    }

    private var editorMap: some View {
        SkyTrackMap(
            route: points,
            basemapMode: basemap.mode,
            creditBottomInset: 108,
            scrollEnabled: tool == .pan,
            vertices: points.enumerated().map { index, point in
                TrackVertex(
                    id: index,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    label: "\(index + 1)"
                )
            },
            refitsOnChange: false,
            onTap: tool == .add || tool == .delete ? { coordinate in
                if tool == .add {
                    points.append(GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0, timestamp: nil))
                } else if let index = nearest(to: coordinate, within: 80) {
                    points.remove(at: index)
                }
            } : nil,
            onVertexDrag: tool == .move ? { index, coordinate in
                guard points.indices.contains(index) else { return }
                points[index].latitude = coordinate.latitude
                points[index].longitude = coordinate.longitude
            } : nil
        )
    }

    private func nearest(to coordinate: CLLocationCoordinate2D, within meters: Double) -> Int? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (Int, Double)?
        for (index, point) in points.enumerated() {
            let distance = CLLocation(latitude: point.latitude, longitude: point.longitude).distance(from: target)
            if distance <= meters, best == nil || distance < best!.1 {
                best = (index, distance)
            }
        }
        return best?.0
    }
}

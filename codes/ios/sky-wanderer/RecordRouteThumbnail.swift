import SwiftUI
import UIKit

/// 82pt route mark for one record card.
///
/// This is the existing track stroke, not a basemap. An 82pt cell cannot show
/// the Tianditu approval line or the Apple map logo without covering the route,
/// and a VoiceOver label is not that attribution. No route stays the detail
/// empty line. The stroke is the stored track, never a stand-in city or drawing.
struct RecordRouteThumbnail: View {
    var route: [GeoPoint]

    var body: some View {
        ZStack {
            Color(uiColor: SkyBasemapInstaller.backdrop)
            if route.count < 2 {
                Text("这次没有轨迹")
                    .font(.system(size: 11, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(SkyTheme.Color.ink)
                    .multilineTextAlignment(.center)
                    .padding(4)
            } else {
                RecordTrackLine(points: route)
            }
        }
        .frame(width: CGFloat(RecordListCardLayout.mapSide), height: CGFloat(RecordListCardLayout.mapSide))
        .clipShape(
            RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.count >= 2 ? "轨迹" : "这次没有轨迹")
    }
}

/// Brand blue kept light enough that numbers drawn on top stay readable.
/// Route cards still use this stroke.
private enum RecordTrackInk {
    /// About 38% of `#1E88FE`, inside the 0.35–0.40 band for the background track.
    static let color = SkyTheme.Color.primary.opacity(0.38)
}

/// Route stroke. Long traces are sampled down before they are projected.
struct RecordTrackLine: View {
    var points: [GeoPoint]

    var body: some View {
        let samples = RecordTrackPath.simplified(points)
        Canvas { context, size in
            let spots = Self.projected(samples, in: size)
            guard spots.count >= 2 else { return }
            var path = Path()
            path.move(to: spots[0])
            for point in spots.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(RecordTrackInk.color),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            if let last = spots.last {
                let dot = CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dot), with: .color(RecordTrackInk.color))
            }
        }
    }

    private static func projected(_ points: [GeoPoint], in size: CGSize) -> [CGPoint] {
        guard let first = points.first, points.count >= 2 else { return [] }
        var latitudeSum = 0.0
        for point in points {
            latitudeSum += point.latitude
        }
        let midLatitude = latitudeSum / Double(points.count)
        let cosLat = max(cos(midLatitude * .pi / 180), 0.2)
        var east: [CGFloat] = []
        var north: [CGFloat] = []
        east.reserveCapacity(points.count)
        north.reserveCapacity(points.count)
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in points {
            let easting = CGFloat((point.longitude - first.longitude) * 111_320 * cosLat)
            let northing = CGFloat((point.latitude - first.latitude) * 111_320)
            east.append(easting)
            north.append(northing)
            minX = min(minX, easting)
            maxX = max(maxX, easting)
            minY = min(minY, northing)
            maxY = max(maxY, northing)
        }
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let pad: CGFloat = 12
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

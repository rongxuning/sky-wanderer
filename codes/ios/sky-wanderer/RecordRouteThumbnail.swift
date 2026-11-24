import SwiftUI
import UIKit

/// Square map for one record card: the basemap with the stored track on it.
///
/// The image comes from the same offscreen map as the share image, so the
/// datum, tiles, and track stroke match the detail screen. Until it arrives
/// the cell shows the bare stroke on the backdrop. No route stays the detail
/// empty line. The stroke is the stored track, never a stand-in city or drawing.
struct RecordRouteThumbnail: View {
    var workoutID: UUID
    var route: [GeoPoint]
    @ObservedObject private var basemap = SkyBasemapCenter.shared
    @ScaledMetric(relativeTo: .caption2) private var emptySize: CGFloat = 11
    @State private var mapImage: UIImage?

    private var side: CGFloat { CGFloat(RecordListCardLayout.mapSide) }

    private var loadKey: String {
        "\(workoutID.uuidString)-\(route.count)-\(basemap.mode == .tianditu ? "t" : "s")"
    }

    var body: some View {
        ZStack {
            Color(uiColor: SkyBasemapInstaller.backdrop)
            if route.count < 2 {
                Text("这次没有轨迹")
                    .font(.system(size: emptySize, weight: .semibold))
                    .foregroundStyle(SkyTheme.Color.ink)
                    .multilineTextAlignment(.center)
                    .padding(4)
            } else {
                RecordTrackLine(points: route)
                if let mapImage {
                    Image(uiImage: mapImage)
                        .resizable()
                        .frame(width: side, height: side)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(
            RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous)
        )
        .task(id: loadKey) {
            guard route.count >= 2 else { return }
            let image = await RecordMapThumbnails.shared.image(for: workoutID, route: route, side: side)
            guard let image, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                mapImage = image
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.count >= 2 ? "轨迹" : "这次没有轨迹")
    }
}

/// Renders card maps one at a time. Each render opens a short-lived offscreen
/// window, so a long list must not start them all at once. Finished images are
/// kept for the session, which makes scrolling back instant.
@MainActor
final class RecordMapThumbnails {
    static let shared = RecordMapThumbnails()

    private let cache = NSCache<NSString, UIImage>()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func image(for id: UUID, route: [GeoPoint], side: CGFloat) async -> UIImage? {
        let key = Self.key(id: id, route: route, side: side)
        if let hit = cache.object(forKey: key) { return hit }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let currentKey = Self.key(id: id, route: route, side: side)
        if let hit = cache.object(forKey: currentKey) { return hit }
        let image = await TrackMapImage.render(
            route: route,
            size: CGSize(width: side, height: side),
            overlap: 0,
            thumbnail: true
        )
        if let image {
            cache.setObject(image, forKey: currentKey)
        }
        return image
    }

    private static func key(id: UUID, route: [GeoPoint], side: CGFloat) -> NSString {
        let mode = SkyBasemapCenter.shared.mode == .tianditu ? "t" : "s"
        return "\(id.uuidString)-\(route.count)-\(mode)-\(Int(side))" as NSString
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
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
        let pad = min(size.width, size.height) * CGFloat(RecordListCardLayout.mapTrackInsetFraction)
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

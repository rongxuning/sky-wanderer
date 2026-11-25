import SwiftUI
import UIKit

/// Map plate for one record card: the basemap with the stored track on it.
///
/// The image comes from the same offscreen map as the share image, so the
/// datum and tiles match the detail screen. Until it arrives the cell shows
/// the bare stroke on the backdrop. Empty routes are not drawn here — the
/// card swaps in `RecordSportSwatch` instead. The stroke is the stored track,
/// never a stand-in city or drawing.
struct RecordRouteThumbnail: View {
    var workoutID: UUID
    var route: [GeoPoint]
    var width: CGFloat
    var height: CGFloat
    @ObservedObject private var basemap = SkyBasemapCenter.shared
    @State private var mapImage: UIImage?

    private var loadKey: String {
        "\(workoutID.uuidString)-\(route.count)-\(basemap.mode == .tianditu ? "t" : "s")-\(Int(width))x\(Int(height))"
    }

    private var renderSide: CGFloat {
        max(width, height, CGFloat(RecordListCardLayout.mapSide))
    }

    var body: some View {
        ZStack {
            Color(uiColor: SkyBasemapInstaller.backdrop)
            if route.count >= 2 {
                RecordTrackLine(points: route)
                if let mapImage {
                    Image(uiImage: mapImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .transition(.opacity)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(
            RoundedRectangle(cornerRadius: CGFloat(RecordListCardLayout.mapCorner), style: .continuous)
        )
        .task(id: loadKey) {
            guard route.count >= 2 else { return }
            let image = await RecordMapThumbnails.shared.image(
                for: workoutID,
                route: route,
                side: renderSide
            )
            guard let image, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                mapImage = image
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("轨迹")
    }
}

/// Frosted glass plate when the card has no route to draw.
/// Strength and mixed training use their catalog icons; other sports fall
/// back to the SF Symbol. The tint stays a light wash of the sport accent.
struct RecordSportSwatch: View {
    var sport: SportKind

    private var plate: RoundedRectangle {
        RoundedRectangle(cornerRadius: CGFloat(RecordListCardLayout.mapCorner), style: .continuous)
    }

    var body: some View {
        ZStack {
            plate.fill(.ultraThinMaterial)
            plate.fill(SkyTheme.Color.sport(sport).opacity(0.12))
            plate.strokeBorder(SkyTheme.Color.sport(sport).opacity(0.18), lineWidth: 1)
            glyph
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(plate)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if let asset = sport.listThumbnailAsset {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(SkyTheme.Color.sport(sport).opacity(0.72))
                .padding(CGFloat(RecordListCardLayout.mapSide) * 0.2)
        } else {
            Image(systemName: sport.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(SkyTheme.Color.sport(sport).opacity(0.72))
        }
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
        return "\(id.uuidString)-\(route.count)-\(mode)-\(Int(side))-list" as NSString
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

/// Record-list track ink. Matches the basemap thumbnail stroke.
private enum RecordTrackInk {
    static let color = SkyTheme.Color.recordTrack
    static var lineWidth: CGFloat { CGFloat(RecordListCardLayout.mapTrackLineWidth) }
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
                style: StrokeStyle(
                    lineWidth: RecordTrackInk.lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            if let last = spots.last {
                let radius = RecordTrackInk.lineWidth * 0.55
                let dot = CGRect(
                    x: last.x - radius,
                    y: last.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
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

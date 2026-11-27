import SwiftUI
import UIKit

/// Map plate for one record card: a disk/memory basemap plate when one exists,
/// otherwise the bare track stroke or start pin on the backdrop.
///
/// The list never opens a live `MKMapView` per card. That stampeded on cold
/// launch and jetsam-killed the app. Plates are written when a workout is saved
/// or by a gentle backfill. Strength / mixed training always use this view —
/// even with no fix they keep the map chrome instead of a catalog icon.
struct RecordRouteThumbnail: View {
    var workoutID: UUID
    var route: [GeoPoint]
    var width: CGFloat
    var height: CGFloat
    @ObservedObject private var basemap = SkyBasemapCenter.shared
    @ObservedObject private var thumbs = RecordMapThumbnails.shared
    @State private var mapImage: UIImage?

    /// Plates are written at the layout side. The card may pass a larger square
    /// (Dynamic Type); the plate scales to fill that square.
    private var plateSide: CGFloat {
        CGFloat(RecordListCardLayout.mapSide)
    }

    /// Prefer the full-track count when the list only holds a summary polyline.
    var routePointCount: Int = 0

    private var kind: RecordListThumbnailKind {
        RecordListThumbnailKind.resolve(routeCount: routePointCount > 0 ? routePointCount : route.count)
    }

    private var loadKey: String {
        "\(workoutID.uuidString)-\(route.count)-\(basemap.mode == .tianditu ? "t" : "s")-\(thumbs.revision)-\(RecordListThumbnailFile.plateVersion)"
    }

    var body: some View {
        ZStack {
            Color(uiColor: SkyBasemapInstaller.backdrop)
            plate
        }
        .frame(width: width, height: height)
        .clipShape(
            RoundedRectangle(cornerRadius: CGFloat(RecordListCardLayout.mapCorner), style: .continuous)
        )
        .task(id: loadKey) {
            guard kind != .swatch else { return }
            let image = await RecordMapThumbnails.shared.cachedImage(
                for: workoutID,
                side: plateSide
            )
            guard !Task.isCancelled else { return }
            if mapImage !== image {
                if image != nil {
                    withAnimation(.easeOut(duration: 0.2)) {
                        mapImage = image
                    }
                } else {
                    mapImage = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .startPoint ? "训练地点" : kind == .track ? "轨迹" : "地图")
    }

    @ViewBuilder
    private var plate: some View {
        switch kind {
        case .track:
            ZStack {
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
        case .startPoint:
            ZStack {
                if let mapImage {
                    Image(uiImage: mapImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .transition(.opacity)
                } else if let point = route.first {
                    RecordStartPointMark(point: point)
                }
            }
        case .swatch:
            // Map chrome only — used by 力量 / 综合 when no start fix exists.
            EmptyView()
        }
    }
}

/// Frosted glass plate when the card has no start coordinate to map.
/// Used for sports that are not 力量 / 综合. Those two keep the map plate
/// instead of a catalog icon. Other sports fall back to the SF Symbol.
/// The tint stays a light wash of the sport accent.
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

/// Record-list map plates: memory → disk → optional one-at-a-time MapKit warm.
///
/// The list path only calls `cachedImage`. `warm` / `backfill` open the offscreen
/// map away from scroll, write JPEG under `record-thumbs/`, and bump `revision`
/// so visible cards pick up the plate.
@MainActor
final class RecordMapThumbnails: ObservableObject {
    static let shared = RecordMapThumbnails()

    /// Bumped after a plate is written so list cells re-read cache/disk.
    @Published private(set) var revision: Int = 0

    private let cache = NSCache<NSString, UIImage>()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var warming = Set<String>()

    init() {
        cache.countLimit = 40
    }

    /// Memory or disk only. Never opens MapKit.
    func cachedImage(for id: UUID, side: CGFloat) async -> UIImage? {
        let token = Self.basemapToken
        let sideKey = Int(side.rounded())
        let key = Self.key(id: id, basemapToken: token, side: sideKey)
        if let hit = cache.object(forKey: key) { return hit }
        let disk = await Task.detached(priority: .utility) {
            RecordListThumbnailStore.load(id: id, basemapToken: token, side: sideKey)
        }.value
        if let disk {
            cache.setObject(disk, forKey: key)
        }
        return disk
    }

    /// Fire-and-forget warm after a workout is saved. Skips if already queued.
    func enqueueWarm(for id: UUID, route: [GeoPoint], side: CGFloat) {
        guard RecordListThumbnailKind.resolve(routeCount: route.count) != .swatch else { return }
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        let stamp = Self.warmStamp(id: id, basemapToken: token, side: sideKey)
        guard !warming.contains(stamp) else { return }
        warming.insert(stamp)
        Task { @MainActor in
            defer { self.warming.remove(stamp) }
            _ = await self.warm(for: id, route: route, side: side)
        }
    }

    /// One MapKit render, then disk + memory. Serialized across the process.
    @discardableResult
    func warm(for id: UUID, route: [GeoPoint], side: CGFloat) async -> UIImage? {
        guard RecordListThumbnailKind.resolve(routeCount: route.count) != .swatch else { return nil }
        if let hit = await cachedImage(for: id, side: side) { return hit }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        // Read after waiting: the mode may have changed while this render was queued.
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        let key = Self.key(id: id, basemapToken: token, side: sideKey)
        if let hit = cache.object(forKey: key) { return hit }
        if let disk = await RecordListThumbnailStore.loadAsync(id: id, basemapToken: token, side: sideKey) {
            cache.setObject(disk, forKey: key)
            return disk
        }
        let image = await TrackMapImage.render(
            route: route,
            size: CGSize(width: side, height: side),
            overlap: 0,
            thumbnail: true
        )
        // The render follows the live basemap. Drop it if the mode moved, so a
        // system-map image is never saved under the Tianditu name.
        guard let image, Self.basemapToken == token else { return nil }
        cache.setObject(image, forKey: key)
        RecordListThumbnailStore.save(image, id: id, basemapToken: token, side: sideKey)
        revision &+= 1
        return image
    }

    /// Fills missing plates slowly. The caller restarts this when the workout ids
    /// or the basemap mode change, so each pass uses one token. Sleeps between renders.
    func backfill(workouts: [WorkoutRecord], side: CGFloat) async {
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        for workout in workouts {
            guard !Task.isCancelled else { return }
            guard RecordListThumbnailKind.resolve(routeCount: workout.listThumbnailPointCount) != .swatch else { continue }
            if await RecordListThumbnailStore.existsAsync(id: workout.id, basemapToken: token, side: sideKey) {
                continue
            }
            _ = await warm(for: workout.id, route: workout.listThumbnailRoute, side: side)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func forget(id: UUID) {
        RecordListThumbnailStore.deleteAll(for: id)
        // NSCache has no prefix purge; drop the session plates for this id.
        cache.removeAllObjects()
        revision &+= 1
    }

    private static var basemapToken: String {
        SkyBasemapCenter.shared.mode == .tianditu ? "t" : "s"
    }

    private static func key(id: UUID, basemapToken: String, side: Int) -> NSString {
        RecordListThumbnailFile.relativePath(id: id, basemapToken: basemapToken, side: side) as NSString
    }

    private static func warmStamp(id: UUID, basemapToken: String, side: Int) -> String {
        "\(id.uuidString)-\(basemapToken)-\(side)"
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

/// Placeholder start pin while the basemap plate is still missing.
struct RecordStartPointMark: View {
    var point: GeoPoint

    var body: some View {
        Canvas { context, size in
            let radius = max(RecordTrackInk.lineWidth * 0.9, 5)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = CGRect(
                x: center.x - radius - 2,
                y: center.y - radius - 2,
                width: (radius + 2) * 2,
                height: (radius + 2) * 2
            )
            let disc = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: ring), with: .color(.white))
            context.fill(Path(ellipseIn: disc), with: .color(RecordTrackInk.color))
        }
        .accessibilityHidden(true)
        // Keep `point` so callers pass the start coordinate explicitly.
        .opacity(point.latitude.isFinite ? 1 : 0)
    }
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
        // Edge pad covers the canvas end dot and the thicker basemap stroke.
        let pad = CGFloat(RecordListCardLayout.mapTrackEdgePad)
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

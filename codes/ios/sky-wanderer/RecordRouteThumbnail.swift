import SwiftUI
import UIKit

/// Map plate for one record card: a disk/memory basemap plate when one exists,
/// otherwise the bare track stroke on the backdrop.
///
/// The list never opens a live `MKMapView` per card. That stampeded on cold
/// launch and jetsam-killed the app. Plates are written when a workout is saved
/// or by a gentle backfill. Empty routes are not drawn here — the card swaps in
/// `RecordSportSwatch` instead.
struct RecordRouteThumbnail: View {
    var workoutID: UUID
    var route: [GeoPoint]
    var width: CGFloat
    var height: CGFloat
    @ObservedObject private var basemap = SkyBasemapCenter.shared
    @ObservedObject private var thumbs = RecordMapThumbnails.shared
    @State private var mapImage: UIImage?

    private var loadKey: String {
        "\(workoutID.uuidString)-\(route.count)-\(basemap.mode == .tianditu ? "t" : "s")-\(Int(renderSide))-\(thumbs.revision)"
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
            let image = await RecordMapThumbnails.shared.cachedImage(
                for: workoutID,
                side: renderSide
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
        guard route.count >= 2 else { return }
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
        guard route.count >= 2 else { return nil }
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        let key = Self.key(id: id, basemapToken: token, side: sideKey)
        if let hit = cache.object(forKey: key) { return hit }
        if let disk = RecordListThumbnailStore.load(id: id, basemapToken: token, side: sideKey) {
            cache.setObject(disk, forKey: key)
            return disk
        }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        if let hit = cache.object(forKey: key) { return hit }
        if let disk = RecordListThumbnailStore.load(id: id, basemapToken: token, side: sideKey) {
            cache.setObject(disk, forKey: key)
            return disk
        }
        let image = await TrackMapImage.render(
            route: route,
            size: CGSize(width: side, height: side),
            overlap: 0,
            thumbnail: true
        )
        guard let image else { return nil }
        cache.setObject(image, forKey: key)
        RecordListThumbnailStore.save(image, id: id, basemapToken: token, side: sideKey)
        revision &+= 1
        return image
    }

    /// Fills missing plates slowly after launch. Cancelled when the caller’s
    /// task ends. Sleeps between renders so MapKit is not back-to-back.
    func backfill(workouts: [WorkoutRecord], side: CGFloat) async {
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        for workout in workouts {
            guard !Task.isCancelled else { return }
            guard workout.route.count >= 2 else { continue }
            let key = Self.key(id: workout.id, basemapToken: token, side: sideKey)
            if cache.object(forKey: key) != nil { continue }
            if RecordListThumbnailStore.load(id: workout.id, basemapToken: token, side: sideKey) != nil {
                continue
            }
            _ = await warm(for: workout.id, route: workout.route, side: side)
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

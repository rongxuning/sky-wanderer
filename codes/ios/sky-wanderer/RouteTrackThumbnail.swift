import SwiftUI
import UIKit

/// Map plate for one route card: a disk/memory basemap plate when one exists,
/// otherwise the bare track stroke on the backdrop.
///
/// The list never opens a live `MKMapView` per card. Plates are written when a
/// route is imported or by a gentle backfill.
struct RouteTrackThumbnail: View {
    var routeID: String
    var points: [GeoPoint]
    var side: CGFloat
    @ObservedObject private var basemap = SkyBasemapCenter.shared
    @ObservedObject private var thumbs = RouteMapThumbnails.shared
    @State private var mapImage: UIImage?

    private var loadKey: String {
        "\(routeID)-\(points.count)-\(basemap.mode == .tianditu ? "t" : "s")-\(thumbs.revision)-\(RouteListThumbnailFile.plateVersion)"
    }

    var body: some View {
        ZStack {
            Color(uiColor: SkyBasemapInstaller.backdrop)
            RecordTrackLine(points: points)
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(
            RoundedRectangle(cornerRadius: CGFloat(RecordListCardLayout.mapCorner), style: .continuous)
        )
        .task(id: loadKey) {
            guard points.count >= 2 else { return }
            let image = await RouteMapThumbnails.shared.cachedImage(for: routeID, side: side)
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

/// Route-list map plates: memory → disk → optional one-at-a-time MapKit warm.
@MainActor
final class RouteMapThumbnails: ObservableObject {
    static let shared = RouteMapThumbnails()

    @Published private(set) var revision: Int = 0

    private let cache = NSCache<NSString, UIImage>()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var warming = Set<String>()

    init() {
        cache.countLimit = 40
    }

    /// Memory or disk only. Never opens MapKit.
    func cachedImage(for id: String, side: CGFloat) async -> UIImage? {
        let token = Self.basemapToken
        let sideKey = Int(side.rounded())
        let key = Self.key(id: id, basemapToken: token, side: sideKey)
        if let hit = cache.object(forKey: key) { return hit }
        let disk = await Task.detached(priority: .utility) {
            RouteListThumbnailStore.load(id: id, basemapToken: token, side: sideKey)
        }.value
        if let disk {
            cache.setObject(disk, forKey: key)
        }
        return disk
    }

    /// Fire-and-forget warm after a route is imported. Skips if already queued.
    func enqueueWarm(for id: String, points: [GeoPoint], side: CGFloat) {
        guard points.count >= 2 else { return }
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        let stamp = Self.warmStamp(id: id, basemapToken: token, side: sideKey)
        guard !warming.contains(stamp) else { return }
        warming.insert(stamp)
        Task { @MainActor in
            defer { self.warming.remove(stamp) }
            _ = await self.warm(for: id, points: points, side: side)
        }
    }

    /// One MapKit render, then disk + memory. Serialized across the process.
    @discardableResult
    func warm(for id: String, points: [GeoPoint], side: CGFloat) async -> UIImage? {
        guard points.count >= 2 else { return nil }
        if let hit = await cachedImage(for: id, side: side) { return hit }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        let key = Self.key(id: id, basemapToken: token, side: sideKey)
        if let hit = cache.object(forKey: key) { return hit }
        if let disk = await RouteListThumbnailStore.loadAsync(id: id, basemapToken: token, side: sideKey) {
            cache.setObject(disk, forKey: key)
            return disk
        }
        let image = await TrackMapImage.render(
            route: points,
            size: CGSize(width: side, height: side),
            overlap: 0,
            thumbnail: true
        )
        guard let image, Self.basemapToken == token else { return nil }
        cache.setObject(image, forKey: key)
        RouteListThumbnailStore.save(image, id: id, basemapToken: token, side: sideKey)
        revision &+= 1
        return image
    }

    /// Fills missing plates slowly. The caller restarts this when the route ids
    /// or the basemap mode change. Sleeps between renders.
    func backfill(routes: [SavedRoute], side: CGFloat) async {
        let sideKey = Int(side.rounded())
        let token = Self.basemapToken
        for route in routes {
            guard !Task.isCancelled else { return }
            guard route.points.count >= 2 else { continue }
            if await RouteListThumbnailStore.existsAsync(id: route.id, basemapToken: token, side: sideKey) {
                continue
            }
            _ = await warm(for: route.id, points: route.points, side: side)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func forget(id: String) {
        RouteListThumbnailStore.deleteAll(for: id)
        cache.removeAllObjects()
        revision &+= 1
    }

    private static var basemapToken: String {
        SkyBasemapCenter.shared.mode == .tianditu ? "t" : "s"
    }

    private static func key(id: String, basemapToken: String, side: Int) -> NSString {
        RouteListThumbnailFile.relativePath(id: id, basemapToken: basemapToken, side: side) as NSString
    }

    private static func warmStamp(id: String, basemapToken: String, side: Int) -> String {
        "\(id)-\(basemapToken)-\(side)"
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

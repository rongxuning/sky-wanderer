import MapKit
import SwiftUI
import UIKit

/// 82pt route thumbnail for one record card.
///
/// A cell does not host a live map. The real track is drawn immediately.
/// A snapshot is queued one at a time and reused from memory and disk.
/// The snapshot uses the same basemap as the rest of the phone
/// (`ter_w` + `cta_w`, or the system map after the existing fallback)
/// and the same `TrackOverlay` / `TrackDatum` policy.
/// No route: the detail empty line, never a stand-in track or city.
struct RecordRouteThumbnail: View {
    var route: [GeoPoint]

    @ObservedObject private var store = RecordRouteThumbnailStore.shared
    @ObservedObject private var basemap = SkyBasemapCenter.shared

    private var key: String {
        RecordRouteThumbnailKey.make(
            route: route,
            mode: basemap.mode,
            scale: RecordRouteThumbnailScale.current
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: SkyBasemapInstaller.backdrop)
            if route.count < 2 {
                Text("这次没有轨迹")
                    .font(.system(size: 11, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(SkyTheme.Color.ink)
                    .multilineTextAlignment(.center)
                    .padding(4)
            } else if let image = store.image(for: key) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RecordTrackLine(points: route)
            }
        }
        .frame(width: CGFloat(RecordListCardLayout.mapSide), height: CGFloat(RecordListCardLayout.mapSide))
        .clipShape(
            RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.count >= 2 ? "轨迹，\(basemap.caption)" : "这次没有轨迹")
        .task(id: key) {
            await store.prepare(key: key, route: route)
        }
    }
}

enum RecordRouteThumbnailScale {
    @MainActor
    static var current: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scale = scenes.first?.screen.scale ?? 0
        return scale > 0 ? scale : 3
    }
}

enum RecordRouteThumbnailKey {
    /// Stable across launches. `Hasher` is not, so the disk cache does not use it.
    static func make(route: [GeoPoint], mode: SkyBasemapMode, scale: CGFloat) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_03
        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 1_099_511_628_211
        }
        func mixCoordinate(_ value: Double) {
            guard value.isFinite else {
                mix(0)
                return
            }
            let scaled = min(max(value * 100_000, -1_000_000_000_000), 1_000_000_000_000).rounded()
            mix(UInt64(bitPattern: Int64(scaled)))
        }
        mix(UInt64(route.count))
        for point in RecordTrackPath.simplified(route, limit: 24) {
            mixCoordinate(point.latitude)
            mixCoordinate(point.longitude)
        }
        mix(mode == .tianditu ? 1 : 2)
        let bucket = UInt64(max(1, Int(scale.rounded())))
        mix(bucket)
        let modeName = mode == .tianditu ? "td" : "sys"
        return "\(modeName)-x\(bucket)-\(String(hash, radix: 16))"
    }
}

@MainActor
final class RecordRouteThumbnailStore: ObservableObject {
    static let shared = RecordRouteThumbnailStore()

    @Published private var images: [String: UIImage] = [:]
    private var memoryOrder: [String] = []
    private var pending: [String] = []
    private var routes: [String: [GeoPoint]] = []
    private var activeKey: String?

    func image(for key: String) -> UIImage? {
        images[key]
    }

    func prepare(key: String, route: [GeoPoint]) async {
        guard route.count >= 2 else { return }
        if images[key] != nil { return }
        if let stored = RecordRouteThumbnailDisk.load(key) {
            remember(key, stored)
            return
        }
        routes[key] = route
        if activeKey != key, !pending.contains(key) {
            pending.append(key)
        }
        pump()
        while images[key] == nil, !Task.isCancelled, activeKey == key || pending.contains(key) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        if Task.isCancelled, activeKey != key {
            pending.removeAll { $0 == key }
            if activeKey != key {
                routes[key] = nil
            }
        }
    }

    private func pump() {
        guard activeKey == nil, !pending.isEmpty else { return }
        let key = pending.removeFirst()
        guard let route = routes.removeValue(forKey: key) else {
            pump()
            return
        }
        activeKey = key
        Task { @MainActor in
            let image = await RecordRouteSnapshot.render(route: route)
            if let image {
                self.remember(key, image)
                RecordRouteThumbnailDisk.save(key, image)
            }
            self.activeKey = nil
            self.pump()
        }
    }

    private func remember(_ key: String, _ image: UIImage) {
        images[key] = image
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        while memoryOrder.count > 48 {
            let drop = memoryOrder.removeFirst()
            images.removeValue(forKey: drop)
        }
    }
}

enum RecordRouteThumbnailDisk {
    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("record-route-thumbnails", isDirectory: true)
    }

    static func load(_ key: String) -> UIImage? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data, scale: RecordRouteThumbnailScale.current)
    }

    static func save(_ key: String, _ image: UIImage) {
        guard let url = fileURL(key), let data = image.pngData(), let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(_ key: String) -> URL? {
        guard let folder else { return nil }
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard safe == key, !safe.isEmpty else { return nil }
        return folder.appendingPathComponent(safe).appendingPathExtension("png")
    }
}

/// Offscreen snapshot. One window at a time, behind the app window.
/// A route that cannot be fitted returns nil. There is no stand-in city.
@MainActor
enum RecordRouteSnapshot {
    static func render(route: [GeoPoint]) async -> UIImage? {
        let samples = RecordTrackPath.simplified(route, limit: 180)
        let finite = samples.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        guard finite.count >= 2 else { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        let side = CGFloat(RecordListCardLayout.mapSide)
        let host = RecordRouteSnapshotHost(scene: scene, side: side)
        host.start(route: finite)
        defer { host.teardown() }
        return await host.waitForImage()
    }
}

@MainActor
private final class RecordRouteSnapshotHost: NSObject, MKMapViewDelegate {
    private let scene: UIWindowScene
    private let side: CGFloat
    private var window: UIWindow?
    private var map: MKMapView?
    private var tiles: [MKTileOverlay] = []
    private var mode: SkyBasemapMode
    private var fullRenders = 0
    private var finished = false
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var earlyImage: UIImage?
    private var route: [GeoPoint] = []

    init(scene: UIWindowScene, side: CGFloat) {
        self.scene = scene
        self.side = side
        mode = SkyBasemapCenter.shared.mode
    }

    func start(route: [GeoPoint]) {
        self.route = route
        guard let region = region(for: route, mode: mode) else {
            finish(image: nil)
            return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        let map = MKMapView(frame: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        map.delegate = self
        map.overrideUserInterfaceStyle = .light
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = false
        map.pointOfInterestFilter = SkyBasemapCenter.shared.mode == .tianditu ? .excludingAll : nil
        map.backgroundColor = SkyBasemapInstaller.backdrop
        window.addSubview(map)
        window.isHidden = false
        self.window = window
        self.map = map
        installContent(on: map)
        map.setRegion(region, animated: false)
        watch()
    }

    func waitForImage() async -> UIImage? {
        if finished { return earlyImage }
        return await withCheckedContinuation { continuation in
            if self.finished {
                continuation.resume(returning: self.earlyImage)
                return
            }
            self.continuation = continuation
        }
    }

    func teardown() {
        map?.delegate = nil
        window?.isHidden = true
        window = nil
        map = nil
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        TrackMapDrawing.renderer(for: overlay)
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        guard fullyRendered else { return }
        fullRenders += 1
        MapLegalChrome.setAppleAttributionHidden(SkyBasemapCenter.shared.mode == .tianditu, on: mapView)
    }

    private func installContent(on map: MKMapView) {
        mode = SkyBasemapCenter.shared.mode
        tiles = SkyBasemapInstaller.attach(to: map, mode: mode, removing: tiles)
        map.pointOfInterestFilter = mode == .tianditu ? .excludingAll : nil
        map.removeOverlays(map.overlays.filter { $0 is TrackOverlay })
        let shown = TrackDatum.displayed(route, mode: mode)
        if shown.count >= 2 {
            map.addOverlay(TrackOverlay(points: shown, style: .solid(TrackPaint.primary)))
        }
        MapLegalChrome.setAppleAttributionHidden(mode == .tianditu, on: map)
    }

    private func watch() {
        let started = Date()
        Task { @MainActor in
            while !self.finished {
                let elapsed = Date().timeIntervalSince(started)
                let current = SkyBasemapCenter.shared.mode
                if current != self.mode, let map = self.map {
                    self.fullRenders = 0
                    self.installContent(on: map)
                    if let region = self.region(for: self.route, mode: current) {
                        map.setRegion(region, animated: false)
                    }
                }
                let idle = !TiandituTileActivity.busy
                let ready = self.fullRenders > 0 && idle && (current == .system || elapsed > 0.6)
                if ready {
                    self.finish(image: self.capture())
                    return
                }
                if elapsed > 3.5 {
                    // Keep a painted frame. A frame that never rendered is not cached.
                    self.finish(image: self.fullRenders > 0 ? self.capture() : nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func finish(image: UIImage?) {
        guard !finished else { return }
        finished = true
        if let continuation {
            continuation.resume(returning: image)
            self.continuation = nil
        } else {
            earlyImage = image
        }
    }

    private func capture() -> UIImage? {
        guard let window else { return nil }
        let scale = scene.screen.scale > 0 ? scene.screen.scale : 3
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: CGSize(width: side, height: side)), afterScreenUpdates: true)
        }
    }

    /// Fitted route only. No fallback city when the points cannot make a region.
    private func region(for route: [GeoPoint], mode: SkyBasemapMode) -> MKCoordinateRegion? {
        let shown = TrackDatum.displayed(route, mode: mode).map(\.coordinate)
        return GeoFit.region(shown)
    }
}

/// Brand blue kept light enough that numbers drawn on top stay readable.
/// Route cards still use this stroke. The record list uses it only until a snapshot arrives.
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

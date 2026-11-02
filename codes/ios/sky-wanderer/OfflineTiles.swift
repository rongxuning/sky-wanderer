import Darwin
import MapKit
import UIKit

struct TileKey: Hashable {
    var z: Int
    var x: Int
    var y: Int
}

enum TileSource: String {
    case osm
    case local
}

enum ZoomDragPhase {
    case began
    case changed(CGFloat)
    case ended
}

/// Disk cache for route basemap tiles. MapKit does not keep a durable offline copy,
/// so each route warms this folder. A drawn tile is stored when OpenStreetMap has no tile.
enum OfflineTileStore {
    private static let attemptLock = NSLock()
    private static var inFlight = Set<TileKey>()
    private static var failedAt: [TileKey: Date] = [:]

    static func prefetch(_ routes: [[GeoPoint]]) async {
        var keys: [TileKey] = []
        var seen = Set<TileKey>()
        for points in routes {
            for key in TilePlan.covering(points) where seen.insert(key).inserted {
                keys.append(key)
                if keys.count >= 80 { break }
            }
            if keys.count >= 80 { break }
        }
        let pending = keys.filter { OfflineTileDisk.source($0) != .osm }
        var wrote = false
        var index = 0
        while index < pending.count {
            let end = min(index + 4, pending.count)
            let slice = Array(pending[index..<end])
            index = end
            let changed: Bool = await withTaskGroup(of: Bool.self) { group in
                for key in slice {
                    group.addTask { await fill(key) }
                }
                var any = false
                for await value in group where value {
                    any = true
                }
                return any
            }
            if changed { wrote = true }
        }
        if wrote {
            await MainActor.run { TileCacheStatus.shared.bump() }
        }
    }

    private static func fill(_ key: TileKey) async -> Bool {
        guard claim(key) else { return false }
        if let data = await OfflineTileDisk.fetchOSM(key) {
            OfflineTileDisk.write(key, data: data, source: .osm)
            finish(key, success: true)
            return true
        }
        var wrote = false
        if OfflineTileDisk.source(key) == nil {
            OfflineTileDisk.write(key, data: OfflineTileDisk.localImage(), source: .local)
            wrote = true
        }
        finish(key, success: false)
        return wrote
    }

    private static func claim(_ key: TileKey) -> Bool {
        attemptLock.lock()
        defer { attemptLock.unlock() }
        if OfflineTileDisk.source(key) == .osm { return false }
        if inFlight.contains(key) { return false }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 600 { return false }
        inFlight.insert(key)
        return true
    }

    private static func finish(_ key: TileKey, success: Bool) {
        attemptLock.lock()
        inFlight.remove(key)
        if success {
            failedAt[key] = nil
        } else {
            failedAt[key] = Date()
        }
        attemptLock.unlock()
    }
}

final class TileCacheStatus: ObservableObject {
    static let shared = TileCacheStatus()
    @Published private(set) var revision = 0
    @Published private(set) var note = "正在准备离线地图"

    func bump() {
        revision += 1
    }

    func refresh(for points: [GeoPoint]) {
        let keys = TilePlan.covering(points)
        let next: String
        if keys.isEmpty {
            next = "离线底图已保存在本机"
        } else if keys.contains(where: { OfflineTileDisk.source($0) == .osm }) {
            next = "离线地图 · © OpenStreetMap"
        } else if keys.contains(where: { OfflineTileDisk.source($0) != nil }) {
            next = "离线底图已保存在本机"
        } else {
            next = "正在准备离线地图"
        }
        if next != note { note = next }
    }
}

enum TilePlan {
    static func covering(_ points: [GeoPoint], maxTiles: Int = 48) -> [TileKey] {
        guard points.count >= 2 else { return [] }
        let fit = fitZoom(for: points)
        let zooms = [fit, fit - 1, fit + 1, fit - 2, fit + 2].filter { (11...17).contains($0) }
        var chosen: [TileKey] = []
        var seen = Set<TileKey>()
        for zoom in zooms {
            let fresh = tiles(points, zoom: zoom, padding: 1).filter { seen.insert($0).inserted }
            if chosen.count + fresh.count <= maxTiles {
                chosen.append(contentsOf: fresh)
            } else if chosen.isEmpty {
                chosen.append(contentsOf: fresh.prefix(maxTiles))
                break
            }
        }
        return chosen
    }

    private static func fitZoom(for points: [GeoPoint]) -> Int {
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let span = max(
            (latitudes.max() ?? 0) - (latitudes.min() ?? 0),
            (longitudes.max() ?? 0) - (longitudes.min() ?? 0),
            0.0008
        ) * 1.6
        let zoom = Int(Darwin.log2(720 / span).rounded())
        return min(16, max(11, zoom))
    }

    private static func tiles(_ points: [GeoPoint], zoom: Int, padding: Int) -> [TileKey] {
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
        for point in points {
            let x = xIndex(longitude: point.longitude, zoom: zoom)
            let y = yIndex(latitude: point.latitude, zoom: zoom)
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        let limit = (1 << zoom) - 1
        minX = max(0, minX - padding)
        maxX = min(limit, maxX + padding)
        minY = max(0, minY - padding)
        maxY = min(limit, maxY + padding)
        guard minX <= maxX, minY <= maxY else { return [] }
        var keys: [TileKey] = []
        for x in minX...maxX {
            for y in minY...maxY {
                keys.append(TileKey(z: zoom, x: x, y: y))
            }
        }
        return keys
    }

    private static func xIndex(longitude: Double, zoom: Int) -> Int {
        let count = Double(1 << zoom)
        let x = (longitude + 180) / 360 * count
        return clamp(Int(x.rounded(.down)), zoom: zoom)
    }

    private static func yIndex(latitude: Double, zoom: Int) -> Int {
        let count = Double(1 << zoom)
        let limited = min(85.05112878, max(-85.05112878, latitude))
        let radians = limited * .pi / 180
        let y = (1 - Darwin.log(Darwin.tan(radians) + 1 / Darwin.cos(radians)) / Double.pi) / 2 * count
        return clamp(Int(y.rounded(.down)), zoom: zoom)
    }

    private static func clamp(_ value: Int, zoom: Int) -> Int {
        let limit = (1 << zoom) - 1
        return min(limit, max(0, value))
    }
}

enum OfflineTileDisk {
    private static let lock = NSLock()

    static func source(_ key: TileKey) -> TileSource? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(key) else { return nil }
        let marker = url.appendingPathExtension("source")
        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let source = TileSource(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return source
        }
        if FileManager.default.fileExists(atPath: url.path) { return .local }
        return nil
    }

    static func read(_ key: TileKey) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(key) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func write(_ key: TileKey, data: Data, source: TileSource) {
        guard isPNG(data), let url = fileURL(key) else { return }
        lock.lock()
        defer { lock.unlock() }
        let marker = url.appendingPathExtension("source")
        if source == .local,
           let existing = try? String(contentsOf: marker, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines) == TileSource.osm.rawValue {
            return
        }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? Data(source.rawValue.utf8).write(to: marker, options: .atomic)
    }

    static func fetchOSM(_ key: TileKey) async -> Data? {
        guard let url = URL(string: "https://tile.openstreetmap.org/\(key.z)/\(key.x)/\(key.y).png") else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("sky-wanderer/1.0 (iOS; on-device route cache)", forHTTPHeaderField: "User-Agent")
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, isPNG(data) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func localImage() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        return renderer.pngData { context in
            UIColor(red: 0.886, green: 0.925, blue: 0.910, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            UIColor(red: 0.773, green: 0.839, blue: 0.816, alpha: 1).setStroke()
            let graphics = context.cgContext
            graphics.setLineWidth(1)
            for step in stride(from: 0, to: 256, by: 64) {
                let position = CGFloat(step) + 0.5
                graphics.move(to: CGPoint(x: position, y: 0))
                graphics.addLine(to: CGPoint(x: position, y: 256))
                graphics.move(to: CGPoint(x: 0, y: position))
                graphics.addLine(to: CGPoint(x: 256, y: position))
            }
            graphics.strokePath()
        }
    }

    static func isPNG(_ data: Data) -> Bool {
        data.count > 8 && data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
    }

    private static func fileURL(_ key: TileKey) -> URL? {
        guard let root = try? AppFiles.directory() else { return nil }
        let folder = root.appendingPathComponent("tiles", isDirectory: true)
        return folder
            .appendingPathComponent(String(key.z), isDirectory: true)
            .appendingPathComponent(String(key.x), isDirectory: true)
            .appendingPathComponent("\(key.y).png")
    }
}

final class DiskTileOverlay: MKTileOverlay {
    override init() {
        super.init(urlTemplate: "")
        canReplaceMapContent = true
        minimumZ = 2
        maximumZ = 18
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = TileKey(z: path.z, x: path.x, y: path.y)
        if let data = OfflineTileDisk.read(key), OfflineTileDisk.isPNG(data) {
            result(data, nil)
            return
        }
        let data = OfflineTileDisk.localImage()
        OfflineTileDisk.write(key, data: data, source: .local)
        result(data, nil)
    }
}

final class RouteMapContainer: UIView {
    let map = MKMapView()
    let zoomCover = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomCover.backgroundColor = .clear
        zoomCover.isHidden = true
        zoomCover.isAccessibilityElement = false
        addSubview(map)
        addSubview(zoomCover)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds
        zoomCover.frame = bounds
    }
}

struct OfflineRouteMap: UIViewRepresentable {
    var routeID: String
    var points: [GeoPoint]
    var zoomMultiplier: Double
    var zoomArmed: Bool
    var tileEpoch: Int
    var onZoomChanged: (Double) -> Void
    var onZoomDrag: (ZoomDragPhase) -> Void

    func makeCoordinator() -> OfflineRouteMapCoordinator {
        OfflineRouteMapCoordinator()
    }

    func makeUIView(context: Context) -> RouteMapContainer {
        let container = RouteMapContainer()
        let map = container.map
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .light
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.backgroundColor = UIColor(red: 0.886, green: 0.925, blue: 0.910, alpha: 1)
        map.accessibilityLabel = "路线地图"
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(OfflineRouteMapCoordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        container.zoomCover.addGestureRecognizer(pan)
        return container
    }

    func updateUIView(_ container: RouteMapContainer, context: Context) {
        let map = container.map
        let coordinator = context.coordinator
        coordinator.onZoomChanged = onZoomChanged
        coordinator.onZoomDrag = onZoomDrag
        coordinator.zoomArmed = zoomArmed
        container.zoomCover.isHidden = !zoomArmed
        map.isScrollEnabled = !zoomArmed
        map.isZoomEnabled = !zoomArmed
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        if coordinator.routeID != routeID {
            coordinator.install(routeID: routeID, points: points, tileEpoch: tileEpoch, map: map)
            return
        }
        if coordinator.tileEpoch != tileEpoch {
            coordinator.tileEpoch = tileEpoch
            coordinator.replaceTiles(on: map)
        }
        if abs(coordinator.appliedMultiplier - zoomMultiplier) > 0.02 {
            coordinator.apply(multiplier: zoomMultiplier, map: map)
        }
    }

    static func dismantleUIView(_ container: RouteMapContainer, coordinator: OfflineRouteMapCoordinator) {
        coordinator.onZoomChanged = nil
        coordinator.onZoomDrag = nil
    }
}

final class OfflineRouteMapCoordinator: NSObject, MKMapViewDelegate {
    var onZoomChanged: ((Double) -> Void)?
    var onZoomDrag: ((ZoomDragPhase) -> Void)?
    var routeID = ""
    var zoomArmed = false
    var tileEpoch = -1
    var appliedMultiplier = 1.0

    private var fitted: MKCoordinateRegion?
    /// The first camera settles MapKit's aspect-fit. That view is 1×.
    private var lockingFit = false
    /// Set around a zoom-tool camera change so it is not read back as a pinch.
    private var suppressCallback = false
    private var tileOverlay: MKTileOverlay?
    private var halo: MKPolyline?
    private var polyline: MKPolyline?

    func install(routeID: String, points: [GeoPoint], tileEpoch: Int, map: MKMapView) {
        self.routeID = routeID
        self.tileEpoch = tileEpoch
        fitted = GeoFit.region(points.map(\.coordinate))
        replacePolyline(points, on: map)
        replaceTiles(on: map)
        guard let fitted else { return }
        lockingFit = true
        suppressCallback = false
        appliedMultiplier = 1
        map.setRegion(fitted, animated: false)
    }

    func replaceTiles(on map: MKMapView) {
        if let tileOverlay {
            map.removeOverlay(tileOverlay)
        }
        let overlay = DiskTileOverlay()
        map.addOverlay(overlay)
        tileOverlay = overlay
        liftLines(on: map)
    }

    func apply(multiplier: Double, map: MKMapView) {
        guard let fitted else { return }
        let clamped = min(16, max(0.4, multiplier))
        if abs(clamped - appliedMultiplier) <= 0.02 {
            appliedMultiplier = clamped
            return
        }
        let latitude = fitted.span.latitudeDelta / clamped
        var region = map.region
        let current = max(region.span.latitudeDelta, 0.0000001)
        let ratio = latitude / current
        region.span = MKCoordinateSpan(
            latitudeDelta: latitude,
            longitudeDelta: min(180, max(region.span.longitudeDelta * ratio, 0.0001))
        )
        suppressCallback = true
        appliedMultiplier = clamped
        map.setRegion(region, animated: false)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        if lockingFit {
            guard mapView.bounds.width > 40,
                  mapView.bounds.height > 40,
                  mapView.region.span.latitudeDelta > 0.0000001 else { return }
            lockingFit = false
            suppressCallback = false
            if var region = fitted {
                region.span.latitudeDelta = mapView.region.span.latitudeDelta
                region.span.longitudeDelta = mapView.region.span.longitudeDelta
                fitted = region
            }
            appliedMultiplier = 1
            return
        }
        if suppressCallback {
            suppressCallback = false
            return
        }
        guard let fitted, !zoomArmed else { return }
        let latitude = max(mapView.region.span.latitudeDelta, 0.0000001)
        let next = min(16, max(0.4, fitted.span.latitudeDelta / latitude))
        appliedMultiplier = next
        onZoomChanged?(next)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        guard let line = overlay as? MKPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.lineJoin = .round
        renderer.lineCap = .round
        if line === halo {
            renderer.strokeColor = UIColor.white.withAlphaComponent(0.92)
            renderer.lineWidth = 8
        } else {
            renderer.strokeColor = UIColor(red: 2 / 255, green: 132 / 255, blue: 199 / 255, alpha: 1)
            renderer.lineWidth = 4
        }
        return renderer
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        let y = gesture.translation(in: gesture.view).y
        switch gesture.state {
        case .began:
            onZoomDrag?(.began)
        case .changed:
            onZoomDrag?(.changed(y))
        case .ended, .cancelled, .failed:
            onZoomDrag?(.ended)
        default:
            break
        }
    }

    private func replacePolyline(_ points: [GeoPoint], on map: MKMapView) {
        if let halo { map.removeOverlay(halo) }
        if let polyline { map.removeOverlay(polyline) }
        halo = nil
        polyline = nil
        guard points.count >= 2 else { return }
        let coordinates = points.map(\.coordinate)
        let underlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(underlay)
        map.addOverlay(line)
        halo = underlay
        polyline = line
    }

    private func liftLines(on map: MKMapView) {
        if let halo {
            map.removeOverlay(halo)
            map.addOverlay(halo)
        }
        if let polyline {
            map.removeOverlay(polyline)
            map.addOverlay(polyline)
        }
    }
}

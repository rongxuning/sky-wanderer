import Darwin
import MapKit
import SwiftUI
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
    // MKTileOverlay's designated initializer is init(urlTemplate:).
    // NSObject.init is only a convenience initializer, so it cannot be overridden.
    override init(urlTemplate: String?) {
        super.init(urlTemplate: urlTemplate)
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
    var onLayout: ((CGSize) -> Void)?
    private var notifyingLayout = false

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
        guard !notifyingLayout else { return }
        notifyingLayout = true
        onLayout?(bounds.size)
        notifyingLayout = false
    }
}

struct OfflineRouteMap: UIViewRepresentable {
    var routeID: String
    var points: [GeoPoint]
    var checkpoints: [RouteCheckpointMark]
    var showsKilometerMarkers: Bool = false
    var zoomMultiplier: Double
    var zoomArmed: Bool
    var tileEpoch: Int
    /// Bottom of the title bar. 1× fits the route below this and above the card.
    var topContentInset: CGFloat = 0
    /// Lifts the legal label above the floating card, and is the bottom of the 1× band.
    var legalBottomInset: CGFloat = 0
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
        map.insetsLayoutMarginsFromSafeArea = false
        map.accessibilityLabel = "路线地图"
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(OfflineRouteMapCoordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        container.zoomCover.addGestureRecognizer(pan)
        let coordinator = context.coordinator
        container.onLayout = { [weak container, weak coordinator] size in
            guard let container, let coordinator else { return }
            coordinator.noteLayout(size, map: container.map)
        }
        return container
    }

    func updateUIView(_ container: RouteMapContainer, context: Context) {
        let map = container.map
        let coordinator = context.coordinator
        coordinator.onZoomChanged = onZoomChanged
        coordinator.onZoomDrag = onZoomDrag
        let wasArmed = coordinator.zoomArmed
        coordinator.zoomArmed = zoomArmed
        coordinator.topInset = max(0, topContentInset)
        coordinator.bottomInset = max(0, legalBottomInset)
        container.zoomCover.isHidden = !zoomArmed
        map.isScrollEnabled = !zoomArmed
        map.isZoomEnabled = !zoomArmed
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        let checkpointKey = checkpoints.map { "\($0.id):\($0.name):\($0.latitude):\($0.longitude)" }.joined(separator: "|")
        if coordinator.routeID != routeID {
            coordinator.install(
                routeID: routeID,
                points: points,
                checkpoints: checkpoints,
                showsKilometerMarkers: showsKilometerMarkers,
                tileEpoch: tileEpoch,
                map: map
            )
        } else {
            if coordinator.checkpointKey != checkpointKey {
                coordinator.replaceCheckpoints(checkpoints, on: map)
            }
            if coordinator.showsKilometers != showsKilometerMarkers {
                coordinator.setKilometers(showsKilometerMarkers, points: points, on: map)
            }
            if coordinator.tileEpoch != tileEpoch {
                coordinator.tileEpoch = tileEpoch
                coordinator.replaceTiles(on: map)
            }
            if abs(coordinator.appliedMultiplier - zoomMultiplier) > 0.02 {
                coordinator.apply(multiplier: zoomMultiplier, map: map, fromTool: true)
            }
            coordinator.requestFit(on: map)
        }
        if wasArmed, !zoomArmed {
            coordinator.flushPendingFit(on: map)
        }
        let inset = max(0, legalBottomInset)
        if abs(map.layoutMargins.bottom - inset) > 0.5 {
            var margins = map.layoutMargins
            margins.bottom = inset
            map.layoutMargins = margins
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
    var checkpointKey = ""
    var zoomArmed = false
    var tileEpoch = -1
    var appliedMultiplier = 1.0
    var showsKilometers = false
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// Camera region at 1×: the whole route inside the band, aspect-fit to the view.
    private var fitted: MKCoordinateRegion?
    private var routePoints: [GeoPoint] = []
    private var cachedMarkers: [KilometerMarker] = []
    /// The person has pinched, panned, or dragged the magnifier. Chrome changes keep that scale.
    private var userAdjusted = false
    /// A pinch or pan is in progress. Don't move the camera until it ends.
    private var userAdjusting = false
    private var pendingFit = false
    private var applyingCamera = false
    private var fittedInputs: FitInputs?
    private var tileOverlay: MKTileOverlay?
    private var halo: MKPolyline?
    private var track: ElevationTrackOverlay?
    private var checkpointAnnotations: [CheckpointAnnotation] = []
    private var kilometerAnnotations: [KilometerAnnotation] = []

    private struct FitInputs {
        var routeID: String
        var width: CGFloat
        var height: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    func install(
        routeID: String,
        points: [GeoPoint],
        checkpoints: [RouteCheckpointMark],
        showsKilometerMarkers: Bool,
        tileEpoch: Int,
        map: MKMapView
    ) {
        self.routeID = routeID
        self.tileEpoch = tileEpoch
        routePoints = points
        userAdjusted = false
        userAdjusting = false
        pendingFit = false
        applyingCamera = false
        fitted = nil
        fittedInputs = nil
        appliedMultiplier = 1
        if !kilometerAnnotations.isEmpty {
            map.removeAnnotations(kilometerAnnotations)
            kilometerAnnotations = []
        }
        cachedMarkers = []
        replacePolyline(points, on: map)
        replaceCheckpoints(checkpoints, on: map)
        setKilometers(showsKilometerMarkers, points: points, on: map)
        replaceTiles(on: map)
        commitFit(on: map)
    }

    func noteLayout(_ size: CGSize, map: MKMapView) {
        guard size.width > 40, size.height > 40 else { return }
        requestFit(on: map)
    }

    /// Re-fit when the title bar or the card changes height. A pinch or the magnifier
    /// keeps the camera until that gesture ends; 1× stays "the route in the band".
    func requestFit(on map: MKMapView) {
        guard map.bounds.width > 40, map.bounds.height > 40 else { return }
        if sameInputs(as: map), fitted != nil { return }
        if userAdjusting || zoomArmed {
            pendingFit = true
            return
        }
        commitFit(on: map)
    }

    func flushPendingFit(on map: MKMapView) {
        guard pendingFit || !sameInputs(as: map) || fitted == nil else { return }
        pendingFit = false
        guard !userAdjusting else {
            pendingFit = true
            return
        }
        commitFit(on: map)
    }

    func replaceTiles(on map: MKMapView) {
        if let tileOverlay {
            map.removeOverlay(tileOverlay)
        }
        let overlay = DiskTileOverlay(urlTemplate: "")
        map.addOverlay(overlay)
        tileOverlay = overlay
        liftLines(on: map)
    }

    func apply(multiplier: Double, map: MKMapView, fromTool: Bool) {
        guard let fitted else { return }
        let clamped = min(RouteZoomBaseline.maximum, max(RouteZoomBaseline.minimum, multiplier))
        if fromTool, abs(clamped - 1) > 0.02 {
            userAdjusted = true
        }
        let latitude = fitted.span.latitudeDelta / clamped
        let current = max(map.region.span.latitudeDelta, 0.0000001)
        if abs(clamped - appliedMultiplier) <= 0.02, abs(latitude - current) / max(latitude, 0.0000001) < 0.02 {
            appliedMultiplier = clamped
            return
        }
        var region = map.region
        let ratio = latitude / current
        region.span = MKCoordinateSpan(
            latitudeDelta: latitude,
            longitudeDelta: min(180, max(region.span.longitudeDelta * ratio, 0.0001))
        )
        applyingCamera = true
        appliedMultiplier = clamped
        map.setRegion(region, animated: false)
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        // A pinch that starts during our own setRegion still owns the camera.
        guard isUserGesture(mapView) else { return }
        applyingCamera = false
        userAdjusted = true
        userAdjusting = true
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        let wasProgrammatic = applyingCamera
        if applyingCamera {
            applyingCamera = false
        }
        refreshKilometerAnnotations(on: mapView)
        guard !wasProgrammatic else { return }
        guard userAdjusting else { return }
        userAdjusting = false
        publishZoom(from: mapView)
        guard pendingFit, !zoomArmed else { return }
        pendingFit = false
        commitFit(on: mapView)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let mark = annotation as? CheckpointAnnotation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: CheckpointMarkerView.reuseID) as? CheckpointMarkerView
                ?? CheckpointMarkerView(annotation: mark, reuseIdentifier: CheckpointMarkerView.reuseID)
            view.annotation = mark
            view.apply(name: mark.title ?? "")
            return view
        }
        if let mark = annotation as? KilometerAnnotation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: KilometerMarkerView.reuseID) as? KilometerMarkerView
                ?? KilometerMarkerView(annotation: mark, reuseIdentifier: KilometerMarkerView.reuseID)
            view.annotation = mark
            view.apply(kilometer: mark.kilometer)
            return view
        }
        return nil
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        if overlay is ElevationTrackOverlay {
            return ElevationTrackRenderer(overlay: overlay)
        }
        guard let line = overlay as? MKPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.lineJoin = .round
        renderer.lineCap = .round
        renderer.strokeColor = UIColor.white.withAlphaComponent(0.92)
        renderer.lineWidth = 8
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
        if let track {
            map.removeOverlay(track)
        }
        halo = nil
        track = nil
        guard points.count >= 2 else { return }
        let coordinates = points.map(\.coordinate)
        let underlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(underlay)
        halo = underlay
        let colored = ElevationTrackOverlay(points: points)
        map.addOverlay(colored)
        track = colored
    }

    func setKilometers(_ visible: Bool, points: [GeoPoint], on map: MKMapView) {
        showsKilometers = visible
        cachedMarkers = visible ? RouteKilometers.markers(along: points) : []
        // A new route reuses kilometer numbers. Drop the old coordinates before rebuilding.
        if !kilometerAnnotations.isEmpty {
            map.removeAnnotations(kilometerAnnotations)
            kilometerAnnotations = []
        }
        refreshKilometerAnnotations(on: map)
    }

    func replaceCheckpoints(_ marks: [RouteCheckpointMark], on map: MKMapView) {
        if !checkpointAnnotations.isEmpty {
            map.removeAnnotations(checkpointAnnotations)
        }
        let notes = marks.compactMap { mark -> CheckpointAnnotation? in
            guard mark.latitude.isFinite, mark.longitude.isFinite else { return nil }
            return CheckpointAnnotation(
                name: mark.name,
                coordinate: CLLocationCoordinate2D(latitude: mark.latitude, longitude: mark.longitude)
            )
        }
        checkpointAnnotations = notes
        checkpointKey = marks.map { "\($0.id):\($0.name):\($0.latitude):\($0.longitude)" }.joined(separator: "|")
        map.addAnnotations(notes)
        refreshKilometerAnnotations(on: map)
    }

    private func commitFit(on map: MKMapView) {
        guard map.bounds.width > 40, map.bounds.height > 40 else { return }
        guard let camera = makeCamera(for: map) else { return }
        if sameInputs(as: map), fitted != nil { return }
        let hadFit = fitted != nil
        fitted = camera
        fittedInputs = FitInputs(
            routeID: routeID,
            width: map.bounds.width,
            height: map.bounds.height,
            top: topInset,
            bottom: bottomInset
        )
        if userAdjusted, hadFit {
            apply(multiplier: appliedMultiplier, map: map, fromTool: false)
            return
        }
        if userAdjusted {
            // They moved the map before the band fit existed. Keep that picture
            // and read the multiplier off it, instead of snapping back to 1×.
            let next = RouteZoomBaseline.publishedMultiplier(
                fittedLatitude: camera.span.latitudeDelta,
                displayedLatitude: map.region.span.latitudeDelta,
                userGesture: true,
                programmatic: false
            ) ?? 1
            appliedMultiplier = next
            onZoomChanged?(next)
            return
        }
        appliedMultiplier = 1
        if regionClose(map.region, to: camera) { return }
        applyingCamera = true
        map.setRegion(camera, animated: false)
    }

    private func makeCamera(for map: MKMapView) -> MKCoordinateRegion? {
        var latitudes = routePoints.map(\.latitude)
        var longitudes = routePoints.map(\.longitude)
        for note in checkpointAnnotations {
            latitudes.append(note.coordinate.latitude)
            longitudes.append(note.coordinate.longitude)
        }
        guard let content = RouteBandFit.contentSpan(
            latitudes: latitudes,
            longitudes: longitudes
        ) else { return nil }
        let height = Double(map.bounds.height)
        let framed = RouteBandFit.visibleRegion(
            content: content,
            viewWidth: Double(map.bounds.width),
            viewHeight: height,
            topFraction: height > 1 ? Double(topInset) / height : 0,
            bottomFraction: height > 1 ? Double(bottomInset) / height : 0
        )
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: framed.centerLatitude, longitude: framed.centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: framed.latitudeDelta, longitudeDelta: framed.longitudeDelta)
        )
    }

    private func sameInputs(as map: MKMapView) -> Bool {
        guard let fittedInputs else { return false }
        return fittedInputs.routeID == routeID
            && abs(fittedInputs.width - map.bounds.width) < 0.5
            && abs(fittedInputs.height - map.bounds.height) < 0.5
            && abs(fittedInputs.top - topInset) < 0.5
            && abs(fittedInputs.bottom - bottomInset) < 0.5
    }

    private func regionClose(_ region: MKCoordinateRegion, to camera: MKCoordinateRegion) -> Bool {
        let latitude = max(camera.span.latitudeDelta, 0.0000001)
        let longitude = max(camera.span.longitudeDelta, 0.0000001)
        return abs(region.center.latitude - camera.center.latitude) < 0.000001
            && abs(region.center.longitude - camera.center.longitude) < 0.000001
            && abs(region.span.latitudeDelta - camera.span.latitudeDelta) / latitude < 0.02
            && abs(region.span.longitudeDelta - camera.span.longitudeDelta) / longitude < 0.02
    }

    private func publishZoom(from map: MKMapView) {
        guard let fitted, !zoomArmed else { return }
        guard let next = RouteZoomBaseline.publishedMultiplier(
            fittedLatitude: fitted.span.latitudeDelta,
            displayedLatitude: map.region.span.latitudeDelta,
            userGesture: true,
            programmatic: false
        ) else { return }
        if abs(next - appliedMultiplier) <= 0.02 { return }
        appliedMultiplier = next
        onZoomChanged?(next)
    }

    /// MapKit reports its own camera changes through the same delegate. Only a live
    /// gesture updates the multiplier, so the opening layout cannot land on 0.5×.
    private func isUserGesture(_ mapView: MKMapView) -> Bool {
        let recognizers = (mapView.gestureRecognizers ?? [])
            + mapView.subviews.compactMap(\.gestureRecognizers).flatMap { $0 }
        return recognizers.contains { recognizer in
            recognizer.state == .began || recognizer.state == .changed
        }
    }

    private func refreshKilometerAnnotations(on map: MKMapView) {
        let wanted = visibleKilometerIDs(on: map)
        let stale = kilometerAnnotations.filter { !wanted.contains($0.kilometer) }
        if !stale.isEmpty {
            map.removeAnnotations(stale)
            kilometerAnnotations.removeAll { !wanted.contains($0.kilometer) }
        }
        let have = Set(kilometerAnnotations.map(\.kilometer))
        let fresh = cachedMarkers.filter { wanted.contains($0.kilometer) && !have.contains($0.kilometer) }
            .map(KilometerAnnotation.init(marker:))
        guard !fresh.isEmpty else { return }
        kilometerAnnotations.append(contentsOf: fresh)
        map.addAnnotations(fresh)
        // Numbers added last paint over checkpoint names. Put the names back on top.
        bringCheckpointsForward(on: map)
    }

    private func visibleKilometerIDs(on map: MKMapView) -> Set<Int> {
        guard showsKilometers, map.bounds.width > 40, map.bounds.height > 40 else { return [] }
        let discs = cachedMarkers.map { marker in
            let point = map.convert(
                CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude),
                toPointTo: map
            )
            return RouteKilometerLabels.disc(
                kilometer: marker.kilometer,
                at: (x: Double(point.x), y: Double(point.y))
            )
        }
        return Set(RouteKilometerLabels.visible(discs: discs, avoiding: checkpointObstacles(on: map)))
    }

    private func checkpointObstacles(on map: MKMapView) -> [RouteKilometerLabels.Obstacle] {
        let font = UIFont.systemFont(ofSize: 11, weight: .bold)
        return checkpointAnnotations.map { note in
            let point = map.convert(note.coordinate, toPointTo: map)
            let name = note.title ?? ""
            let textWidth = ceil((name as NSString).size(withAttributes: [.font: font]).width)
            return RouteKilometerLabels.checkpointObstacle(
                dotX: Double(point.x),
                dotY: Double(point.y),
                labelWidth: RouteKilometerLabels.labelWidth(textWidth: textWidth)
            )
        }
    }

    private func bringCheckpointsForward(on map: MKMapView) {
        guard !checkpointAnnotations.isEmpty else { return }
        map.removeAnnotations(checkpointAnnotations)
        map.addAnnotations(checkpointAnnotations)
    }

    private func liftLines(on map: MKMapView) {
        if let halo {
            map.removeOverlay(halo)
            map.addOverlay(halo)
        }
        if let track {
            map.removeOverlay(track)
            map.addOverlay(track)
        }
    }
}

/// One colored piece of the track. The next piece starts on this piece's last coordinate.
struct ElevationTrackRun {
    var coordinates: [CLLocationCoordinate2D]
    var color: UIColor
}

/// Splits the path into runs colored by altitude on this route's own range.
enum ElevationTrack {
    private static let steps = 48

    static func make(points: [GeoPoint]) -> [ElevationTrackRun] {
        guard points.count >= 2, let bounds = ElevationScale.bounds(points) else { return [] }
        let vertices = coloredVertices(points, bounds: bounds)
        guard let first = vertices.first else { return [] }
        var runs: [ElevationTrackRun] = []
        var coordinates: [CLLocationCoordinate2D] = [first.coordinate]
        var runBucket = first.bucket
        func flush() {
            guard coordinates.count >= 2 else { return }
            runs.append(ElevationTrackRun(coordinates: coordinates, color: color(for: runBucket)))
        }
        for vertex in vertices.dropFirst() {
            if vertex.bucket != runBucket {
                flush()
                coordinates = [coordinates.last ?? vertex.coordinate, vertex.coordinate]
                runBucket = vertex.bucket
            } else {
                coordinates.append(vertex.coordinate)
            }
        }
        flush()
        return runs
    }

    private static func coloredVertices(
        _ points: [GeoPoint],
        bounds: (low: Double, high: Double)
    ) -> [(coordinate: CLLocationCoordinate2D, bucket: Int)] {
        var vertices: [(coordinate: CLLocationCoordinate2D, bucket: Int)] = []
        vertices.append((points[0].coordinate, bucket(points[0].altitude, bounds: bounds)))
        for index in 1..<points.count {
            let previous = points[index - 1]
            let point = points[index]
            let from = bucket(previous.altitude, bounds: bounds)
            let to = bucket(point.altitude, bounds: bounds)
            let gap = abs(to - from)
            if gap > 1 {
                for step in 1..<gap {
                    let fraction = Double(step) / Double(gap)
                    let altitude = previous.altitude + (point.altitude - previous.altitude) * fraction
                    vertices.append((interpolate(previous, point, fraction), bucket(altitude, bounds: bounds)))
                }
            }
            vertices.append((point.coordinate, to))
        }
        return vertices
    }

    private static func interpolate(_ start: GeoPoint, _ end: GeoPoint, _ fraction: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    private static func bucket(_ altitude: Double, bounds: (low: Double, high: Double)) -> Int {
        let unit = ElevationScale.unit(altitude: altitude, low: bounds.low, high: bounds.high)
        let index = Int((unit * Double(steps - 1)).rounded())
        return min(steps - 1, max(0, index))
    }

    private static func color(for bucket: Int) -> UIColor {
        let unit = Double(bucket) / Double(max(steps - 1, 1))
        let rgb = ElevationScale.rgb(unit: unit)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

/// Map overlay whose stroke follows `ElevationScale` from this route's low altitude to its high altitude.
final class ElevationTrackOverlay: NSObject, MKOverlay {
    struct Run {
        var mapPoints: [MKMapPoint]
        var color: UIColor
        var bounds: MKMapRect
    }

    let runs: [Run]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(points: [GeoPoint]) {
        var built = ElevationTrack.make(points: points)
        if built.isEmpty, points.count >= 2 {
            let rgb = ElevationRGB.mid
            built = [
                ElevationTrackRun(
                    coordinates: points.map(\.coordinate),
                    color: UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                )
            ]
        }
        var runs: [Run] = []
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for piece in built {
            let mapPoints = piece.coordinates.map { MKMapPoint($0) }
            guard let first = mapPoints.first, mapPoints.count >= 2 else { continue }
            var left = first.x
            var right = first.x
            var top = first.y
            var bottom = first.y
            for mapPoint in mapPoints.dropFirst() {
                left = min(left, mapPoint.x)
                right = max(right, mapPoint.x)
                top = min(top, mapPoint.y)
                bottom = max(bottom, mapPoint.y)
            }
            minX = min(minX, left)
            maxX = max(maxX, right)
            minY = min(minY, top)
            maxY = max(maxY, bottom)
            runs.append(
                Run(
                    mapPoints: mapPoints,
                    color: piece.color,
                    bounds: MKMapRect(x: left, y: top, width: max(right - left, 1), height: max(bottom - top, 1))
                )
            )
        }
        self.runs = runs
        if minX <= maxX {
            let pad = 512.0
            boundingMapRect = MKMapRect(
                x: minX - pad,
                y: minY - pad,
                width: max(maxX - minX, 1) + pad * 2,
                height: max(maxY - minY, 1) + pad * 2
            )
            coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        } else {
            boundingMapRect = .world
            coordinate = points.first?.coordinate ?? CLLocationCoordinate2D()
        }
        super.init()
    }
}

final class ElevationTrackRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let track = overlay as? ElevationTrackOverlay else { return }
        let pad = 64 / Double(max(zoomScale, 0.0001))
        let visible = MKMapRect(
            x: mapRect.origin.x - pad,
            y: mapRect.origin.y - pad,
            width: mapRect.size.width + pad * 2,
            height: mapRect.size.height + pad * 2
        )
        // zoomScale is screen points per map point. Dividing keeps the stroke about 4 points wide.
        context.setLineWidth(4 / max(zoomScale, 0.000001))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for run in track.runs where run.bounds.intersects(visible) {
            guard let first = run.mapPoints.first else { continue }
            context.beginPath()
            context.setStrokeColor(run.color.cgColor)
            context.move(to: point(for: first))
            for mapPoint in run.mapPoints.dropFirst() {
                context.addLine(to: point(for: mapPoint))
            }
            context.strokePath()
        }
    }
}

final class KilometerAnnotation: NSObject, MKAnnotation {
    let kilometer: Int
    let coordinate: CLLocationCoordinate2D
    var title: String? { "\(kilometer)" }

    init(marker: KilometerMarker) {
        kilometer = marker.kilometer
        coordinate = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
        super.init()
    }
}

/// White disc with the kilometer number, lifted off the path so a checkpoint name stays readable.
final class KilometerMarkerView: MKAnnotationView {
    static let reuseID = "route-kilometer"

    private let badge = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
        badge.textAlignment = .center
        badge.backgroundColor = .white
        badge.layer.borderColor = UIColor(red: 0x1E / 255, green: 0x88 / 255, blue: 0xFE / 255, alpha: 1).cgColor
        badge.layer.borderWidth = 1.5
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        addSubview(badge)
        collisionMode = .none
        displayPriority = .required
        zPriority = .defaultUnselected
        canShowCallout = false
        isEnabled = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(kilometer: Int) {
        let text = String(kilometer)
        badge.text = text
        let side = CGFloat(RouteKilometerLabels.discSide(for: kilometer))
        badge.frame = CGRect(x: 0, y: 0, width: side, height: side)
        badge.layer.cornerRadius = side / 2
        bounds = badge.bounds
        // The disc sits above the coordinate. Checkpoint names stay to the right of their dot.
        centerOffset = CGPoint(x: 0, y: -CGFloat(RouteKilometerLabels.discLift(for: kilometer)))
        isAccessibilityElement = true
        accessibilityLabel = "\(kilometer) 公里"
    }
}

final class CheckpointAnnotation: NSObject, MKAnnotation {
    let title: String?
    let coordinate: CLLocationCoordinate2D

    init(name: String, coordinate: CLLocationCoordinate2D) {
        title = name
        self.coordinate = coordinate
        super.init()
    }
}

/// Small circle with the checkpoint name. The circle, not the label, sits on the coordinate.
final class CheckpointMarkerView: MKAnnotationView {
    static let reuseID = "route-checkpoint"

    private let dot = UIView()
    private let nameLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        dot.backgroundColor = UIColor(red: 2 / 255, green: 132 / 255, blue: 199 / 255, alpha: 1)
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 1.5
        dot.isUserInteractionEnabled = false
        nameLabel.font = .systemFont(ofSize: 11, weight: .bold)
        nameLabel.textColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
        nameLabel.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        nameLabel.layer.cornerRadius = 4
        nameLabel.clipsToBounds = true
        nameLabel.textAlignment = .center
        nameLabel.isUserInteractionEnabled = false
        addSubview(dot)
        addSubview(nameLabel)
        canShowCallout = false
        isEnabled = false
        isUserInteractionEnabled = false
        displayPriority = .required
        zPriority = .max
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(name: String) {
        nameLabel.text = name
        let textWidth = nameLabel.sizeThatFits(CGSize(width: 160, height: 16)).width
        let labelWidth = min(160, max(18, textWidth + 8))
        let labelHeight: CGFloat = 16
        let dotSide: CGFloat = 10
        nameLabel.frame = CGRect(x: dotSide + 3, y: 0, width: labelWidth, height: labelHeight)
        dot.frame = CGRect(x: 0, y: (labelHeight - dotSide) / 2, width: dotSide, height: dotSide)
        dot.layer.cornerRadius = dotSide / 2
        bounds = CGRect(x: 0, y: 0, width: nameLabel.frame.maxX, height: labelHeight)
        centerOffset = CGPoint(x: bounds.midX - dot.frame.midX, y: bounds.midY - dot.frame.midY)
        isAccessibilityElement = true
        accessibilityLabel = name
    }
}

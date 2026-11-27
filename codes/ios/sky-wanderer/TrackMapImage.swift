import MapKit
import UIKit

/// Share image from the same basemap and the same `TrackOverlay` as the screen.
/// This is an offscreen `MKMapView`, not an `MKMapSnapshotter` of the system map.
/// `thumbnail` drops the credit capsule, the legal line, the provider logo,
/// and the empty-route caption. Multi-point routes omit endpoint markers and
/// center the track so its longer axis meets a half-stroke inset. A single
/// start coordinate draws a round pin on a neighborhood map. Record cards use it.
enum TrackMapImage {
    @MainActor
    static func render(route: [GeoPoint], size: CGSize, overlap: CGFloat, thumbnail: Bool = false) async -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        let host = TrackMapSnapshotHost(scene: scene, size: size, overlap: overlap, thumbnail: thumbnail)
        host.start(route: route)
        defer { host.teardown() }
        return await host.waitForImage()
    }
}

@MainActor
private final class TrackMapSnapshotHost: NSObject, MKMapViewDelegate {
    private let scene: UIWindowScene
    private let size: CGSize
    private let overlap: CGFloat
    private let thumbnail: Bool
    private var window: UIWindow?
    private var map: MKMapView?
    private var tiles: [MKTileOverlay] = []
    private var mode: SkyBasemapMode
    private var fullRenders = 0
    private var finished = false
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var earlyImage: UIImage?
    private var route: [GeoPoint] = []

    init(scene: UIWindowScene, size: CGSize, overlap: CGFloat, thumbnail: Bool) {
        self.scene = scene
        self.size = size
        self.overlap = overlap
        self.thumbnail = thumbnail
        mode = SkyBasemapCenter.shared.mode
    }

    func start(route: [GeoPoint]) {
        self.route = route
        let window = UIWindow(windowScene: scene)
        // Behind the app window so MapKit still paints tiles, without covering the page.
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        let map = ProviderChromeMapView(frame: CGRect(origin: .zero, size: size))
        map.delegate = self
        map.overrideUserInterfaceStyle = .light
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = false
        map.layoutMargins = .zero
        map.preservesSuperviewLayoutMargins = false
        map.directionalLayoutMargins = .zero
        map.pointOfInterestFilter = thumbnail || mode == .tianditu ? .excludingAll : nil
        map.backgroundColor = SkyBasemapInstaller.backdrop
        window.addSubview(map)
        if route.count < 2, !thumbnail {
            let caption = Self.emptyCaption()
            caption.center = CGPoint(x: size.width / 2, y: size.height - max(0, overlap) - 12 - caption.bounds.height / 2)
            window.addSubview(caption)
        }
        window.isHidden = false
        self.window = window
        self.map = map
        installContent(on: map)
        show(route, on: map, mode: mode)
        MapLegalChrome.hideProviderChrome(on: map)
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

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        TrackAnnotationViews.view(for: annotation, on: mapView)
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        guard fullyRendered else { return }
        fullRenders += 1
        MapLegalChrome.hideProviderChrome(on: mapView)
        if thumbnail {
            // MapKit can nudge the camera during the first paint; lock the
            // centered edge-fit again before the snapshot.
            show(route, on: mapView, mode: mode)
        }
    }

    private func installContent(on map: MKMapView) {
        mode = SkyBasemapCenter.shared.mode
        tiles = SkyBasemapInstaller.attach(to: map, mode: mode, removing: tiles)
        map.pointOfInterestFilter = thumbnail || mode == .tianditu ? .excludingAll : nil
        map.removeOverlays(map.overlays.filter { $0 is TrackOverlay })
        map.removeAnnotations(map.annotations)
        let shown = TrackDatum.displayed(route, mode: mode)
        if shown.count >= 2 {
            let style: TrackStyle = thumbnail ? .recordList : .solid(TrackPaint.primary)
            map.addOverlay(TrackOverlay(points: shown, style: style))
            if !thumbnail, let first = shown.first?.coordinate {
                map.addAnnotation(EndpointAnnotation(coordinate: first, square: false))
            }
            if !thumbnail, shown.count >= 2, let last = shown.last?.coordinate {
                map.addAnnotation(EndpointAnnotation(coordinate: last, square: true))
            }
        } else if thumbnail, shown.count == 1 {
            // Neighborhood basemap only. The list card overlays the start pin in
            // SwiftUI so the mark color stays `#1E7DD6` with the distance figure.
        }
        MapLegalChrome.hideProviderChrome(on: map)
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
                    self.show(self.route, on: map, mode: current)
                }
                if let map = self.map {
                    MapLegalChrome.hideProviderChrome(on: map)
                }
                let idle = !TiandituTileActivity.busy
                let ready = self.fullRenders > 0 && idle && (current == .system || elapsed > 0.9)
                // Tianditu tiles with canReplaceMapContent need longer; finishing
                // early captures a solid black plate.
                let budget = current == .tianditu ? 9.0 : 6.0
                if ready || elapsed > budget {
                    self.finish()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let image = capture()
        if let continuation {
            continuation.resume(returning: image)
            self.continuation = nil
        } else {
            earlyImage = image
        }
    }

    private func capture() -> UIImage? {
        guard let window else { return nil }
        if let map {
            MapLegalChrome.hideProviderChrome(on: map)
        }
        let scale = scene.screen.scale > 0 ? scene.screen.scale : 3
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        // Keep opaque false so an unpainted Metal layer does not become a solid
        // black JPEG under Tianditu `canReplaceMapContent`.
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            SkyBasemapInstaller.backdrop.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        // Drop failed black plates so the list keeps the SwiftUI track stroke.
        if thumbnail, !RecordListThumbnailQuality.isUsable(image) {
            return nil
        }
        return image
    }

    /// Centers the track in the thumbnail. The longer ground axis meets the
    /// 5pt edge pad; the shorter axis stays centered. MapKit alone often parks
    /// the region toward the bottom of the square after tiles load — after the
    /// initial fit we measure the track in view points and pan/zoom so the
    /// bounding box keeps that 5pt inset. A single start pin uses a fixed
    /// neighborhood span.
    private func show(_ route: [GeoPoint], on map: MKMapView, mode: SkyBasemapMode) {
        let shown = TrackDatum.displayed(route, mode: mode)
        if thumbnail, shown.count == 1, let only = shown.first {
            map.layoutIfNeeded()
            let coordinate = only.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            map.setRegion(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: 420, longitudinalMeters: 420),
                animated: false
            )
            return
        }
        if thumbnail, let rect = Self.trackRect(route, mode: mode) {
            Self.frameThumbnailTrack(rect, on: map, viewSize: size)
            return
        }
        if let region = region(for: route, mode: mode) {
            map.setRegion(region, animated: false)
        }
    }

    /// Aspect-fill the track, leave `mapTrackEdgePad` on every edge, then correct
    /// any leftover MapKit bias in screen space so the bbox stays centered.
    static func frameThumbnailTrack(_ track: MKMapRect, on map: MKMapView, viewSize: CGSize) {
        map.layoutIfNeeded()
        let pad = CGFloat(RecordListCardLayout.mapTrackEdgePad)
        let bounds = map.bounds.size
        let fittedSize = bounds.width > 1 && bounds.height > 1 ? bounds : viewSize
        let fitted = aspectFilledMapRect(track, viewSize: fittedSize)
        map.setVisibleMapRect(
            fitted,
            edgePadding: UIEdgeInsets(top: pad, left: pad, bottom: pad, right: pad),
            animated: false
        )
        recenterTrack(track, on: map)
        refitTrackEdgePad(track, on: map, edgePad: pad)
        recenterTrack(track, on: map)
    }

    /// Pan so the track bbox center lands on the view center.
    static func recenterTrack(_ track: MKMapRect, on map: MKMapView) {
        guard let mid = trackCenterPoint(track, on: map) else { return }
        let target = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let dx = mid.x - target.x
        let dy = mid.y - target.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        let centerPt = map.convert(map.centerCoordinate, toPointTo: map)
        let shifted = CGPoint(x: centerPt.x + dx, y: centerPt.y + dy)
        let coordinate = map.convert(shifted, toCoordinateFrom: map)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        map.setCenter(coordinate, animated: false)
    }

    /// Zoom so the longer screen axis of the track meets `edgePad` from the sides.
    static func refitTrackEdgePad(_ track: MKMapRect, on map: MKMapView, edgePad: CGFloat) {
        guard let box = trackScreenBox(track, on: map) else { return }
        let longSpan = max(box.width, box.height, 1)
        let side = min(map.bounds.width, map.bounds.height)
        let target = max(side - edgePad * 2, 1)
        let factor = Double(longSpan / target)
        guard abs(factor - 1) > 0.02 else { return }
        let visible = map.visibleMapRect
        let width = visible.size.width * factor
        let height = visible.size.height * factor
        map.setVisibleMapRect(
            MKMapRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            ),
            animated: false
        )
    }

    private static func trackCenterPoint(_ track: MKMapRect, on map: MKMapView) -> CGPoint? {
        guard let box = trackScreenBox(track, on: map) else { return nil }
        return CGPoint(x: box.midX, y: box.midY)
    }

    private static func trackScreenBox(_ track: MKMapRect, on map: MKMapView) -> CGRect? {
        let topLeftCoord = MKMapPoint(x: track.minX, y: track.minY).coordinate
        let bottomRightCoord = MKMapPoint(x: track.maxX, y: track.maxY).coordinate
        guard CLLocationCoordinate2DIsValid(topLeftCoord),
              CLLocationCoordinate2DIsValid(bottomRightCoord) else { return nil }
        let topLeft = map.convert(topLeftCoord, toPointTo: map)
        let bottomRight = map.convert(bottomRightCoord, toPointTo: map)
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private static func trackRect(_ route: [GeoPoint], mode: SkyBasemapMode) -> MKMapRect? {
        let shown = TrackDatum.displayed(route, mode: mode)
        guard shown.count >= 2 else { return nil }
        var rect = MKMapRect.null
        for point in shown {
            let coordinate = point.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let mapPoint = MKMapPoint(coordinate)
            let dot = MKMapRect(origin: mapPoint, size: MKMapSize(width: 0, height: 0))
            rect = rect.union(dot)
        }
        guard !rect.isNull else { return nil }
        if rect.size.width < 1 {
            rect = rect.insetBy(dx: -0.5, dy: 0)
        }
        if rect.size.height < 1 {
            rect = rect.insetBy(dx: 0, dy: -0.5)
        }
        return rect
    }

    /// Grows the shorter map-rect axis until the rect aspect matches the view.
    /// The long track axis then meets the stroke inset and the short axis stays
    /// centered — same rule as `RecordThumbnailFit`.
    static func aspectFilledMapRect(_ rect: MKMapRect, viewSize: CGSize) -> MKMapRect {
        guard viewSize.width > 1, viewSize.height > 1, !rect.isNull else { return rect }
        var result = rect
        let viewAspect = Double(viewSize.width) / Double(viewSize.height)
        let mapWidth = max(result.size.width, 1)
        let mapHeight = max(result.size.height, 1)
        let mapAspect = mapWidth / mapHeight
        if mapAspect > viewAspect {
            let targetHeight = mapWidth / viewAspect
            let delta = (targetHeight - mapHeight) / 2
            result.origin.y -= delta
            result.size.height = targetHeight
        } else if mapAspect < viewAspect {
            let targetWidth = mapHeight * viewAspect
            let delta = (targetWidth - mapWidth) / 2
            result.origin.x -= delta
            result.size.width = targetWidth
        }
        return result
    }

    /// Scales an aspect-filled track rect so a point pad survives. Kept for
    /// checks; live thumbnails use `frameThumbnailTrack` (edge pad + screen fix).
    static func paddedVisibleMapRect(_ rect: MKMapRect, viewSize: CGSize, edgePad: Double) -> MKMapRect {
        let side = Double(min(viewSize.width, viewSize.height))
        let scale = RecordThumbnailFit.visibleMapScale(side: side, edgePad: edgePad)
        let width = rect.size.width * scale
        let height = rect.size.height * scale
        return MKMapRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func region(for route: [GeoPoint], mode: SkyBasemapMode) -> MKCoordinateRegion? {
        let shown = TrackDatum.displayed(route, mode: mode)
        if let fitted = GeoFit.region(shown.map(\.coordinate)) {
            return fitted
        }
        let fallback = ChinaCoordinate.display(fromStored: MapOrigin.fallback.coordinate, basemap: mode)
        return MKCoordinateRegion(
            center: fallback,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    }

    private static func emptyCaption() -> UIView {
        let label = UILabel()
        label.text = "这次没有轨迹"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
        label.textAlignment = .center
        label.backgroundColor = UIColor.white.withAlphaComponent(0.94)
        label.layer.cornerRadius = 14
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        let text = label.sizeThatFits(CGSize(width: 200, height: 20))
        label.frame = CGRect(x: 0, y: 0, width: ceil(text.width) + 24, height: ceil(text.height) + 16)
        label.layer.cornerRadius = label.bounds.height / 2
        return label
    }
}

/// Hides the provider line after MapKit lays it out, so a snapshot cannot
/// burn 法律信息 or the 高德地图 mark back in. Used for thumbnails and share images alike.
private final class ProviderChromeMapView: MKMapView {
    override func layoutSubviews() {
        super.layoutSubviews()
        MapLegalChrome.hideProviderChrome(on: self)
    }
}

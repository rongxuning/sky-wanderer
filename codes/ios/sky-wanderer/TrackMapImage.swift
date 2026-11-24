import MapKit
import UIKit

/// Share image from the same basemap and the same `TrackOverlay` as the screen.
/// This is an offscreen `MKMapView`, not an `MKMapSnapshotter` of the system map.
/// `thumbnail` drops the credit capsule, the legal line, the provider logo,
/// the empty-route caption, and the endpoint markers. The track is fitted to
/// the center with an equal inset on every edge. Record cards use it.
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
        let map: MKMapView = thumbnail
            ? ThumbnailMapView(frame: CGRect(origin: .zero, size: size))
            : MKMapView(frame: CGRect(origin: .zero, size: size))
        map.delegate = self
        map.overrideUserInterfaceStyle = .light
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = false
        map.pointOfInterestFilter = thumbnail || mode == .tianditu ? .excludingAll : nil
        map.backgroundColor = SkyBasemapInstaller.backdrop
        window.addSubview(map)
        if !thumbnail {
            let credit = BasemapCreditLabel()
            credit.setText(SkyBasemapCenter.shared.caption)
            let creditSize = credit.sizeThatFits(.zero)
            let creditY = size.height - max(0, overlap) - creditSize.height - 10
            credit.frame = CGRect(x: 12, y: max(8, creditY), width: creditSize.width, height: creditSize.height)
            credit.tag = 41
            window.addSubview(credit)
        }
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
        if thumbnail {
            MapLegalChrome.hideThumbnailChrome(on: map)
        }
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
        if thumbnail {
            MapLegalChrome.hideThumbnailChrome(on: mapView)
        } else {
            MapLegalChrome.setAppleAttributionHidden(SkyBasemapCenter.shared.mode == .tianditu, on: mapView)
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
            map.addOverlay(TrackOverlay(points: shown, style: .solid(TrackPaint.primary)))
            if !thumbnail, let first = shown.first?.coordinate {
                map.addAnnotation(EndpointAnnotation(coordinate: first, square: false))
            }
            if !thumbnail, shown.count >= 2, let last = shown.last?.coordinate {
                map.addAnnotation(EndpointAnnotation(coordinate: last, square: true))
            }
        }
        if let credit = window?.viewWithTag(41) as? BasemapCreditLabel {
            credit.setText(SkyBasemapCenter.shared.caption)
            let creditSize = credit.sizeThatFits(.zero)
            let creditY = size.height - max(0, overlap) - creditSize.height - 10
            credit.frame = CGRect(x: 12, y: max(8, creditY), width: creditSize.width, height: creditSize.height)
        }
        if thumbnail {
            MapLegalChrome.hideThumbnailChrome(on: map)
        } else {
            MapLegalChrome.setAppleAttributionHidden(mode == .tianditu, on: map)
        }
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
                if self.thumbnail, let map = self.map {
                    MapLegalChrome.hideThumbnailChrome(on: map)
                }
                let idle = !TiandituTileActivity.busy
                let ready = self.fullRenders > 0 && idle && (current == .system || elapsed > 0.9)
                if ready || elapsed > 6 {
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
        if thumbnail, let map {
            MapLegalChrome.hideThumbnailChrome(on: map)
        }
        let scale = scene.screen.scale > 0 ? scene.screen.scale : 3
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    /// Centers the track in the thumbnail. Equal point insets keep a gap on every edge.
    /// A straight north-south or east-west trace has a zero side; that side is opened
    /// just enough for MapKit to keep the line in the middle.
    private func show(_ route: [GeoPoint], on map: MKMapView, mode: SkyBasemapMode) {
        if thumbnail, let rect = Self.trackRect(route, mode: mode) {
            let pad = min(size.width, size.height) * CGFloat(RecordListCardLayout.mapTrackInsetFraction)
            let insets = UIEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
            map.setVisibleMapRect(rect, edgePadding: insets, animated: false)
            return
        }
        if let region = region(for: route, mode: mode) {
            map.setRegion(region, animated: false)
        }
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
/// burn 法律信息 or the 高德地图 mark back in.
private final class ThumbnailMapView: MKMapView {
    override func layoutSubviews() {
        super.layoutSubviews()
        MapLegalChrome.hideThumbnailChrome(on: self)
    }
}

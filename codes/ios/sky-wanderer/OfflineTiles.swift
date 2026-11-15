import MapKit
import SwiftUI
import UIKit

enum ZoomDragPhase {
    case began
    case changed(CGFloat)
    case ended
}

final class RouteMapContainer: UIView {
    let map = MKMapView()
    let zoomCover = UIView()
    let credit = BasemapCreditLabel()
    var onLayout: ((CGSize) -> Void)?
    var creditBottomInset: CGFloat = 0
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
        addSubview(credit)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setCredit(_ text: String?) {
        credit.setText(text)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds
        zoomCover.frame = bounds
        let size = credit.sizeThatFits(.zero)
        let y = bounds.height - creditBottomInset - size.height - 8
        credit.frame = CGRect(x: 12, y: max(8, y), width: size.width, height: size.height)
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
    var basemapMode: SkyBasemapMode
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
        map.backgroundColor = SkyBasemapInstaller.backdrop
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
        let modeChanged = coordinator.mode != basemapMode
        if modeChanged {
            coordinator.mode = basemapMode
            coordinator.prepareForDatumChange()
        }
        container.creditBottomInset = max(0, legalBottomInset)
        container.setCredit(basemapMode == .tianditu ? TiandituConfig.credit : nil)
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
                map: map
            )
        } else {
            if modeChanged {
                coordinator.replacePolyline(points, on: map)
                coordinator.replaceCheckpoints(checkpoints, on: map)
                coordinator.setKilometers(showsKilometerMarkers, points: points, on: map)
                coordinator.replaceTiles(on: map)
            } else if coordinator.checkpointKey != checkpointKey {
                coordinator.replaceCheckpoints(checkpoints, on: map)
            }
            if !modeChanged, coordinator.showsKilometers != showsKilometerMarkers {
                coordinator.setKilometers(showsKilometerMarkers, points: points, on: map)
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
        MapLegalChrome.setAppleAttributionHidden(basemapMode == .tianditu, on: map)
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
    var mode: SkyBasemapMode = .system
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
    private var tileOverlays: [MKTileOverlay] = []
    private var track: TrackOverlay?
    private var checkpointAnnotations: [CheckpointAnnotation] = []
    private var kilometerAnnotations: [KilometerAnnotation] = []

    private struct FitInputs {
        var routeID: String
        var width: CGFloat
        var height: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var mode: SkyBasemapMode
    }

    func prepareForDatumChange() {
        userAdjusted = false
        userAdjusting = false
        pendingFit = false
        fitted = nil
        fittedInputs = nil
    }

    func install(
        routeID: String,
        points: [GeoPoint],
        checkpoints: [RouteCheckpointMark],
        showsKilometerMarkers: Bool,
        map: MKMapView
    ) {
        self.routeID = routeID
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
        tileOverlays = SkyBasemapInstaller.attach(to: map, mode: mode, removing: tileOverlays)
        MapLegalChrome.setAppleAttributionHidden(mode == .tianditu, on: map)
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
        TrackMapDrawing.renderer(for: overlay)
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        MapLegalChrome.setAppleAttributionHidden(mode == .tianditu, on: mapView)
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

    func replacePolyline(_ points: [GeoPoint], on map: MKMapView) {
        if let track {
            map.removeOverlay(track)
        }
        track = nil
        routePoints = points
        let shown = TrackDatum.displayed(points, mode: mode)
        guard shown.count >= 2 else { return }
        let colored = TrackOverlay(points: shown, style: .elevation)
        map.addOverlay(colored)
        track = colored
    }

    func setKilometers(_ visible: Bool, points: [GeoPoint], on map: MKMapView) {
        showsKilometers = visible
        let shown = TrackDatum.displayed(points, mode: mode)
        cachedMarkers = visible ? RouteKilometers.markers(along: shown) : []
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
            let stored = CLLocationCoordinate2D(latitude: mark.latitude, longitude: mark.longitude)
            return CheckpointAnnotation(
                name: mark.name,
                coordinate: ChinaCoordinate.display(fromStored: stored, basemap: mode)
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
            bottom: bottomInset,
            mode: mode
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
        let shown = TrackDatum.displayed(routePoints, mode: mode)
        var latitudes = shown.map(\.latitude)
        var longitudes = shown.map(\.longitude)
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
            && fittedInputs.mode == mode
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
        if let track {
            map.removeOverlay(track)
            map.addOverlay(track)
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

import MapKit
import SwiftUI
import UIKit

enum TrackCreditPlacement {
    /// Start map. The round button owns the bottom center.
    case topCenter
    /// Live, record, and the library. Sits above the sheet or the tool card.
    case bottomLeading
}

struct TrackVertex: Equatable, Identifiable {
    var id: Int
    var latitude: Double
    var longitude: Double
    var label: String
}

/// Phone map for start, live, record detail, and the route library.
/// The track is `TrackOverlay`. Tiles are Tianditu, or the system map after fallback.
struct SkyTrackMap: UIViewRepresentable {
    var route: [GeoPoint]
    var planned: [GeoPoint] = []
    var teammates: [TeammateLive] = []
    var showsUser: Bool = false
    var userCoordinate: CLLocationCoordinate2D? = nil
    var showsEndpoints: Bool = false
    var basemapMode: SkyBasemapMode
    var bottomInset: CGFloat = 0
    var obscuredTopFraction: Double = 0
    var obscuredBottomFraction: Double = 0
    var fitToken: Int = 0
    var creditPlacement: TrackCreditPlacement = .bottomLeading
    var creditBottomInset: CGFloat = 8
    var scrollEnabled: Bool = true
    var vertices: [TrackVertex] = []
    /// Library editing fits once. The other maps follow `RouteMap`'s refit.
    var refitsOnChange: Bool = true
    var onTap: ((CLLocationCoordinate2D) -> Void)? = nil
    var onVertexDrag: ((Int, CLLocationCoordinate2D) -> Void)? = nil

    func makeCoordinator() -> SkyTrackMapCoordinator {
        SkyTrackMapCoordinator()
    }

    func makeUIView(context: Context) -> SkyMapContainer {
        let container = SkyMapContainer()
        let map = container.map
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.insetsLayoutMarginsFromSafeArea = false
        map.accessibilityLabel = "地图"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(SkyTrackMapCoordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(SkyTrackMapCoordinator.handleVertexPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        map.addGestureRecognizer(pan)
        context.coordinator.tap = tap
        context.coordinator.vertexPan = pan
        let coordinator = context.coordinator
        container.onLayout = { [weak container, weak coordinator] in
            guard let container, let coordinator else { return }
            coordinator.noteLayout(container)
        }
        return container
    }

    func updateUIView(_ container: SkyMapContainer, context: Context) {
        let map = container.map
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        coordinator.onVertexDrag = onVertexDrag
        coordinator.mode = basemapMode
        coordinator.showsUser = showsUser
        coordinator.userCoordinate = userCoordinate
        coordinator.showsEndpoints = showsEndpoints
        coordinator.obscuredTopFraction = obscuredTopFraction
        coordinator.obscuredBottomFraction = obscuredBottomFraction
        coordinator.fitToken = fitToken
        coordinator.refitsOnChange = refitsOnChange
        coordinator.bottomInset = bottomInset
        container.placement = creditPlacement
        container.creditBottomInset = max(creditBottomInset, bottomInset)
        container.setCredit(SkyBasemapCenter.shared.caption)
        map.isScrollEnabled = scrollEnabled
        map.isZoomEnabled = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = showsUser
        map.pointOfInterestFilter = basemapMode == .tianditu ? .excludingAll : nil
        let inset = max(0, bottomInset)
        if abs(map.layoutMargins.bottom - inset) > 0.5 {
            var margins = map.layoutMargins
            margins.bottom = inset
            map.layoutMargins = margins
        }
        coordinator.tap?.isEnabled = onTap != nil
        coordinator.vertexPan?.isEnabled = onVertexDrag != nil
        coordinator.sync(
            route: route,
            planned: planned,
            teammates: teammates,
            vertices: vertices,
            map: map
        )
        MapLegalChrome.setAppleAttributionHidden(basemapMode == .tianditu, on: map)
    }
}

final class SkyMapContainer: UIView {
    let map = MKMapView()
    let credit = BasemapCreditLabel()
    var placement: TrackCreditPlacement = .bottomLeading
    var creditBottomInset: CGFloat = 8
    var onLayout: (() -> Void)?
    private var notifying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.backgroundColor = SkyBasemapInstaller.backdrop
        addSubview(map)
        addSubview(credit)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setCredit(_ text: String) {
        credit.setText(text)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds
        let size = credit.sizeThatFits(.zero)
        switch placement {
        case .topCenter:
            let top = max(safeAreaInsets.top, 47) + 8
            credit.frame = CGRect(x: (bounds.width - size.width) / 2, y: top, width: size.width, height: size.height)
        case .bottomLeading:
            let y = bounds.height - creditBottomInset - size.height - 8
            credit.frame = CGRect(x: 12, y: max(8, y), width: size.width, height: size.height)
        }
        guard !notifying else { return }
        notifying = true
        onLayout?()
        notifying = false
    }
}

final class SkyTrackMapCoordinator: NSObject, MKMapViewDelegate {
    var onTap: ((CLLocationCoordinate2D) -> Void)?
    var onVertexDrag: ((Int, CLLocationCoordinate2D) -> Void)?
    var mode: SkyBasemapMode = .system
    var showsUser = false
    var userCoordinate: CLLocationCoordinate2D?
    var showsEndpoints = false
    var obscuredTopFraction = 0.0
    var obscuredBottomFraction = 0.0
    var fitToken = 0
    var refitsOnChange = true
    var bottomInset: CGFloat = 0
    var tap: UITapGestureRecognizer?
    var vertexPan: UIPanGestureRecognizer?

    private var tiles: [MKTileOverlay] = []
    private var routeOverlay: TrackOverlay?
    private var plannedOverlay: TrackOverlay?
    private var endpointAnnotations: [EndpointAnnotation] = []
    private var teammateAnnotations: [TeammateAnnotation] = []
    private var vertexAnnotations: [VertexAnnotation] = []
    private var appliedMode: SkyBasemapMode?
    private var appliedRoute: [GeoPoint] = []
    private var appliedPlanned: [GeoPoint] = []
    private var appliedTeammates: [TeammateLive] = []
    private var appliedVertices: [TrackVertex] = []
    private var appliedEndpoints = false
    private var framedUser = false
    private var didFit = false
    private var lastFitToken = -1
    private var lastSize = CGSize.zero
    private var dragIndex: Int?

    func noteLayout(_ container: SkyMapContainer) {
        let size = container.map.bounds.size
        guard size.width > 40, size.height > 40 else { return }
        let sizeChanged = abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5
        lastSize = size
        guard sizeChanged else { return }
        if !didFit || (refitsOnChange && obscuredTopFraction > 0.02) {
            fit(on: container.map)
        }
    }

    func sync(
        route: [GeoPoint],
        planned: [GeoPoint],
        teammates: [TeammateLive],
        vertices: [TrackVertex],
        map: MKMapView
    ) {
        let modeChanged = appliedMode != mode
        let routeDirty = route != appliedRoute
        let plannedDirty = planned != appliedPlanned
        let endpointsDirty = appliedEndpoints != showsEndpoints
        if modeChanged {
            appliedMode = mode
            didFit = false
            tiles = SkyBasemapInstaller.attach(to: map, mode: mode, removing: tiles)
        }
        if modeChanged || routeDirty || endpointsDirty {
            appliedRoute = route
            appliedEndpoints = showsEndpoints
            replace(route, style: .solid(TrackPaint.primary), existing: &routeOverlay, on: map)
            replaceEndpoints(route, on: map)
        }
        if modeChanged || plannedDirty {
            appliedPlanned = planned
            replace(planned, style: .solid(TrackPaint.planned), existing: &plannedOverlay, on: map)
        }
        if modeChanged || teammates != appliedTeammates {
            appliedTeammates = teammates
            replaceTeammates(teammates, on: map)
        }
        if modeChanged || vertices != appliedVertices {
            appliedVertices = vertices
            replaceVertices(vertices, on: map)
        }
        if modeChanged || routeDirty || plannedDirty, let routeOverlay {
            map.removeOverlay(routeOverlay)
            map.addOverlay(routeOverlay)
        }
        let firstUser = showsUser && userCoordinate != nil && !framedUser
        if firstUser { framedUser = true }
        let tokenChanged = fitToken != lastFitToken
        if tokenChanged { lastFitToken = fitToken }
        let followContent = refitsOnChange && (routeDirty || plannedDirty)
        if modeChanged || tokenChanged || firstUser || followContent || !didFit {
            fit(on: map)
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        TrackMapDrawing.renderer(for: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        TrackAnnotationViews.view(for: annotation, on: mapView)
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        MapLegalChrome.setAppleAttributionHidden(mode == .tianditu, on: mapView)
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let map = gesture.view as? MKMapView else { return }
        let display = map.convert(gesture.location(in: map), toCoordinateFrom: map)
        onTap?(ChinaCoordinate.stored(fromDisplay: display, basemap: mode))
    }

    @objc func handleVertexPan(_ gesture: UIPanGestureRecognizer) {
        guard let map = gesture.view as? MKMapView else { return }
        let display = map.convert(gesture.location(in: map), toCoordinateFrom: map)
        let stored = ChinaCoordinate.stored(fromDisplay: display, basemap: mode)
        switch gesture.state {
        case .began:
            dragIndex = nearestVertex(to: gesture.location(in: map), on: map)
            guard let dragIndex else { return }
            onVertexDrag?(dragIndex, stored)
        case .changed:
            guard let dragIndex else { return }
            onVertexDrag?(dragIndex, stored)
        default:
            dragIndex = nil
        }
    }

    private func nearestVertex(to point: CGPoint, on map: MKMapView) -> Int? {
        var best: (Int, CGFloat)?
        for note in vertexAnnotations {
            let location = map.convert(note.coordinate, toPointTo: map)
            let distance = hypot(location.x - point.x, location.y - point.y)
            if distance <= 44, best == nil || distance < best!.1 {
                best = (note.index, distance)
            }
        }
        return best?.0
    }

    private func replace(
        _ points: [GeoPoint],
        style: TrackStyle,
        existing: inout TrackOverlay?,
        on map: MKMapView
    ) {
        if let existing {
            map.removeOverlay(existing)
        }
        existing = nil
        let shown = TrackDatum.displayed(points, mode: mode)
        guard shown.count >= 2 else { return }
        let overlay = TrackOverlay(points: shown, style: style)
        map.addOverlay(overlay)
        existing = overlay
    }

    private func replaceEndpoints(_ points: [GeoPoint], on map: MKMapView) {
        if !endpointAnnotations.isEmpty {
            map.removeAnnotations(endpointAnnotations)
            endpointAnnotations = []
        }
        guard showsEndpoints, let first = points.first else { return }
        let start = displayed(first.coordinate)
        var notes = [EndpointAnnotation(coordinate: start, square: false)]
        if points.count >= 2, let last = points.last {
            notes.append(EndpointAnnotation(coordinate: displayed(last.coordinate), square: true))
        }
        endpointAnnotations = notes
        map.addAnnotations(notes)
    }

    private func replaceTeammates(_ mates: [TeammateLive], on map: MKMapView) {
        if !teammateAnnotations.isEmpty {
            map.removeAnnotations(teammateAnnotations)
        }
        let notes = mates.map { mate in
            TeammateAnnotation(name: mate.name, coordinate: displayed(mate.coordinate))
        }
        teammateAnnotations = notes
        map.addAnnotations(notes)
    }

    private func replaceVertices(_ vertices: [TrackVertex], on map: MKMapView) {
        if !vertexAnnotations.isEmpty {
            map.removeAnnotations(vertexAnnotations)
        }
        let notes = vertices.map { vertex in
            VertexAnnotation(
                index: vertex.id,
                label: vertex.label,
                coordinate: displayed(CLLocationCoordinate2D(latitude: vertex.latitude, longitude: vertex.longitude))
            )
        }
        vertexAnnotations = notes
        map.addAnnotations(notes)
    }

    private func displayed(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        ChinaCoordinate.display(fromStored: coordinate, basemap: mode)
    }

    private func fit(on map: MKMapView) {
        guard map.bounds.width > 40, map.bounds.height > 40 else { return }
        let hasLine = appliedRoute.count >= 2 || appliedPlanned.count >= 2 || !appliedTeammates.isEmpty
        if showsUser, !hasLine {
            map.setUserTrackingMode(.follow, animated: false)
            didFit = true
            return
        }
        if map.userTrackingMode != .none {
            map.setUserTrackingMode(.none, animated: false)
        }
        guard let region = camera(on: map) else { return }
        didFit = true
        if regionClose(map.region, to: region) { return }
        map.setRegion(region, animated: false)
    }

    private func camera(on map: MKMapView) -> MKCoordinateRegion? {
        var coordinates = TrackDatum.displayed(appliedRoute, mode: mode).map(\.coordinate)
        coordinates += TrackDatum.displayed(appliedPlanned, mode: mode).map(\.coordinate)
        coordinates += appliedTeammates.map { displayed($0.coordinate) }
        if showsUser, let userCoordinate, !coordinates.isEmpty {
            coordinates.append(displayed(userCoordinate))
        }
        guard let region = GeoFit.region(coordinates) else { return nil }
        if obscuredTopFraction > 0.02 {
            return GeoFit.visibleRegion(
                region,
                in: map.bounds.size,
                topFraction: obscuredTopFraction,
                bottomFraction: obscuredBottomFraction
            )
        }
        let fraction = obscuredBottomFraction
        guard fraction > 0.05, fraction < 0.85 else { return region }
        let visible = 1 - fraction
        guard visible > 0.1 else { return region }
        var shifted = region
        shifted.span.latitudeDelta = region.span.latitudeDelta / visible
        shifted.center.latitude = region.center.latitude - shifted.span.latitudeDelta * fraction / 2
        return shifted
    }

    private func regionClose(_ region: MKCoordinateRegion, to camera: MKCoordinateRegion) -> Bool {
        let latitude = max(camera.span.latitudeDelta, 0.0000001)
        let longitude = max(camera.span.longitudeDelta, 0.0000001)
        return abs(region.center.latitude - camera.center.latitude) < 0.000001
            && abs(region.center.longitude - camera.center.longitude) < 0.000001
            && abs(region.span.latitudeDelta - camera.span.latitudeDelta) / latitude < 0.02
            && abs(region.span.longitudeDelta - camera.span.longitudeDelta) / longitude < 0.02
    }
}

enum TrackAnnotationViews {
    static func view(for annotation: MKAnnotation, on map: MKMapView) -> MKAnnotationView? {
        if let mark = annotation as? EndpointAnnotation {
            let view = map.dequeueReusableAnnotationView(withIdentifier: EndpointMarkerView.reuseID) as? EndpointMarkerView
                ?? EndpointMarkerView(annotation: mark, reuseIdentifier: EndpointMarkerView.reuseID)
            view.annotation = mark
            view.apply(square: mark.square)
            return view
        }
        if let mark = annotation as? TeammateAnnotation {
            let view = map.dequeueReusableAnnotationView(withIdentifier: TeammateMarkerView.reuseID) as? TeammateMarkerView
                ?? TeammateMarkerView(annotation: mark, reuseIdentifier: TeammateMarkerView.reuseID)
            view.annotation = mark
            view.apply(name: mark.title ?? "")
            return view
        }
        if let mark = annotation as? VertexAnnotation {
            let view = map.dequeueReusableAnnotationView(withIdentifier: VertexMarkerView.reuseID) as? VertexMarkerView
                ?? VertexMarkerView(annotation: mark, reuseIdentifier: VertexMarkerView.reuseID)
            view.annotation = mark
            view.apply(label: mark.label)
            return view
        }
        return nil
    }
}

final class EndpointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let square: Bool

    init(coordinate: CLLocationCoordinate2D, square: Bool) {
        self.coordinate = coordinate
        self.square = square
        super.init()
    }
}

final class EndpointMarkerView: MKAnnotationView {
    static let reuseID = "track-endpoint"

    private let mark = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        mark.backgroundColor = TrackPaint.primary
        mark.layer.borderColor = UIColor.white.cgColor
        mark.layer.borderWidth = 2
        mark.isUserInteractionEnabled = false
        addSubview(mark)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
        zPriority = .max
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(square: Bool) {
        let side: CGFloat = 14
        mark.frame = CGRect(x: 0, y: 0, width: side, height: side)
        mark.layer.cornerRadius = square ? 3 : side / 2
        bounds = mark.bounds
        centerOffset = .zero
        accessibilityLabel = square ? "终点" : "起点"
        isAccessibilityElement = true
    }
}

final class TeammateAnnotation: NSObject, MKAnnotation {
    let title: String?
    let coordinate: CLLocationCoordinate2D

    init(name: String, coordinate: CLLocationCoordinate2D) {
        title = name
        self.coordinate = coordinate
        super.init()
    }
}

final class TeammateMarkerView: MKAnnotationView {
    static let reuseID = "track-teammate"

    private let nameLabel = UILabel()
    private let dot = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        nameLabel.font = .systemFont(ofSize: 10, weight: .bold)
        nameLabel.textColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
        nameLabel.textAlignment = .center
        dot.backgroundColor = UIColor(red: 2 / 255, green: 132 / 255, blue: 199 / 255, alpha: 1)
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        addSubview(nameLabel)
        addSubview(dot)
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(name: String) {
        nameLabel.text = name
        let text = nameLabel.sizeThatFits(CGSize(width: 120, height: 14))
        let width = max(10, ceil(text.width))
        nameLabel.frame = CGRect(x: 0, y: 0, width: width, height: 12)
        dot.frame = CGRect(x: (width - 10) / 2, y: 14, width: 10, height: 10)
        dot.layer.cornerRadius = 5
        bounds = CGRect(x: 0, y: 0, width: width, height: 24)
        centerOffset = CGPoint(x: 0, y: -bounds.midY)
        accessibilityLabel = name
        isAccessibilityElement = true
    }
}

final class VertexAnnotation: NSObject, MKAnnotation {
    let index: Int
    let label: String
    let coordinate: CLLocationCoordinate2D

    init(index: Int, label: String, coordinate: CLLocationCoordinate2D) {
        self.index = index
        self.label = label
        self.coordinate = coordinate
        super.init()
    }
}

final class VertexMarkerView: MKAnnotationView {
    static let reuseID = "track-vertex"

    private let badge = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
        badge.textAlignment = .center
        badge.backgroundColor = UIColor(red: 125 / 255, green: 211 / 255, blue: 252 / 255, alpha: 1)
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.borderWidth = 2
        badge.clipsToBounds = true
        addSubview(badge)
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
        zPriority = .max
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(label: String) {
        badge.text = label
        badge.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        badge.layer.cornerRadius = 11
        bounds = badge.bounds
        centerOffset = .zero
        isAccessibilityElement = true
        accessibilityLabel = label
    }
}

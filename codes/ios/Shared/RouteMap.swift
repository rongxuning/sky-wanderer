import MapKit
import SwiftUI

struct RouteMap: View {
    var route: [GeoPoint]
    var planned: [GeoPoint] = []
    var teammates: [TeammateLive] = []
    var showsUser: Bool = false
    var userCoordinate: CLLocationCoordinate2D? = nil
    var cornerRadius: CGFloat = 0
    /// Recorded-route stroke. Other screens keep the historical cobalt default.
    var routeColor: Color = Color.omniCobalt
    /// Planned-route stroke. Other screens keep the historical ice default.
    var plannedColor: Color = Color.omniIce
    var routeLineWidth: CGFloat = 4
    /// Pushes the legal label above a bottom sheet. `0` leaves the map's own safe area.
    var bottomInset: CGFloat = 0
    /// Fraction of the map covered from the bottom. Shifts the camera so the track stays visible.
    var obscuredBottomFraction: Double = 0
    /// Fraction of the map covered from the top. With the bottom fraction, fits the track
    /// into the clear band between a toolbar and a sheet.
    var obscuredTopFraction: Double = 0
    /// Start dot and end square. Off unless a detail screen asks for them.
    var showsEndpoints: Bool = false
    /// Hides the compass and other Map controls. The legal label stays.
    var hidesMapControls: Bool = false
    /// Increment to fit the camera back to the route.
    var fitToken: Int = 0
    /// Detail can switch styles. Other screens keep the standard map.
    var style: MapStyle = .standard

    @State private var position: MapCameraPosition = .automatic
    @State private var framedUser = false
    /// Updated as soon as layout reports a size, so a later fit in the same turn sees it.
    @State private var mapSize = RouteMapSizeBox()

    var body: some View {
        map
    }

    private var map: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            if showsUser {
                UserAnnotation()
            }
            if planned.count >= 2 {
                MapPolyline(coordinates: planned.map(\.coordinate))
                    .stroke(plannedColor, lineWidth: 4)
            }
            if route.count >= 2 {
                MapPolyline(coordinates: route.map(\.coordinate))
                    .stroke(routeColor, lineWidth: routeLineWidth)
            }
            if showsEndpoints, let start = route.first {
                Annotation("起点", coordinate: start.coordinate, anchor: .center) {
                    endpointMark(square: false)
                        .accessibilityLabel("起点")
                }
                .annotationTitles(.hidden)
            }
            if showsEndpoints, route.count >= 2, let end = route.last {
                Annotation("终点", coordinate: end.coordinate, anchor: .center) {
                    endpointMark(square: true)
                        .accessibilityLabel("终点")
                }
                .annotationTitles(.hidden)
            }
            ForEach(teammates) { mate in
                Annotation(mate.name, coordinate: mate.coordinate) {
                    VStack(spacing: 2) {
                        Text(mate.name)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.omniInk)
                        Circle()
                            .fill(Color.omniCobalt)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                }
            }
        }
        .mapStyle(style)
        .modifier(RouteMapControlModifier(hidden: hidesMapControls))
        .modifier(RouteMapBottomInset(length: bottomInset))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: RouteMapSizeKey.self, value: geo.size)
            }
        }
        .onPreferenceChange(RouteMapSizeKey.self) { size in
            guard size.width > 1, size.height > 1, size != mapSize.value else { return }
            mapSize.value = size
            if obscuredTopFraction > 0.02 {
                frameCamera()
            }
        }
        .onAppear {
            frameCamera()
            if userCoordinate != nil {
                framedUser = true
            }
        }
        .onChange(of: route.count) { _, _ in frameCamera() }
        .onChange(of: planned) { _, _ in frameCamera() }
        .onChange(of: userCoordinate?.latitude) { _, _ in frameUserOnce() }
        .onChange(of: userCoordinate?.longitude) { _, _ in frameUserOnce() }
        .onChange(of: fitToken) { _, _ in frameCamera() }
        .onChange(of: obscuredTopFraction) { _, _ in frameCamera() }
        .onChange(of: obscuredBottomFraction) { _, _ in frameCamera() }
    }

    private func endpointMark(square: Bool) -> some View {
        let side: CGFloat = 14
        return Group {
            if square {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(routeColor)
                    .frame(width: side, height: side)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.white, lineWidth: 2)
                    )
            } else {
                Circle()
                    .fill(routeColor)
                    .frame(width: side, height: side)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
        }
        .shadow(color: Color.black.opacity(0.22), radius: 2, y: 1)
    }

    /// The first user fix is part of the frame. Later fixes do not move the camera.
    private func frameUserOnce() {
        guard showsUser, userCoordinate != nil, !framedUser else { return }
        framedUser = true
        frameCamera()
    }

    private func frameCamera() {
        var coords = route.map(\.coordinate) + planned.map(\.coordinate) + teammates.map(\.coordinate)
        let hasLine = !route.isEmpty || !planned.isEmpty || !teammates.isEmpty
        if showsUser, let userCoordinate, hasLine {
            coords.append(userCoordinate)
        }
        if showsUser, !hasLine {
            position = .userLocation(fallback: .automatic)
            return
        }
        guard let region = GeoFit.region(coords) else {
            if showsUser {
                position = .userLocation(fallback: .automatic)
            }
            return
        }
        position = .region(biased(region))
    }

    /// Bottom sheet keeps the original latitude-only shift. A top obstruction fits the
    /// track into the clear band, using the measured map size so a wide route stays centered.
    private func biased(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        if obscuredTopFraction > 0.02 {
            return GeoFit.visibleRegion(
                region,
                in: mapSize.value,
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
}

private final class RouteMapSizeBox {
    var value = CGSize.zero
}

private struct RouteMapSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

private struct RouteMapBottomInset: ViewModifier {
    var length: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if length > 0 {
            content.safeAreaPadding(.bottom, length)
        } else {
            content
        }
    }
}

private struct RouteMapControlModifier: ViewModifier {
    var hidden: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if hidden {
            content.mapControls { }
        } else {
            content
        }
    }
}

enum GeoFit {
    static func region(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.008, (maxLat - minLat) * 1.6),
            longitudeDelta: max(0.008, (maxLon - minLon) * 1.6)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// The region MapKit should display so `fitted` sits in the vertical band that is not
    /// covered from the top or the bottom. Fractions are of the map view's height.
    /// MapKit aspect-fits a region to the whole view, so latitude grows until that band
    /// contains `fitted`, and the original center lands on the band's center.
    static func visibleRegion(
        _ fitted: MKCoordinateRegion,
        in viewSize: CGSize,
        topFraction: Double,
        bottomFraction: Double
    ) -> MKCoordinateRegion {
        var top = max(topFraction, 0)
        var bottom = max(bottomFraction, 0)
        var obscured = top + bottom
        guard obscured > 0.02 else { return fitted }
        if obscured > 0.85 {
            let scale = 0.85 / obscured
            top *= scale
            bottom *= scale
            obscured = 0.85
        }
        let visible = 1 - obscured
        guard viewSize.width > 1, viewSize.height > 1 else {
            return latitudeShift(fitted, top: top, bottom: bottom, visible: visible)
        }
        let aspect = viewSize.width / viewSize.height
        let cosine = cos(fitted.center.latitude * Double.pi / 180)
        guard cosine > 0.2 else {
            return latitudeShift(fitted, top: top, bottom: bottom, visible: visible)
        }
        let secant = 1 / cosine
        let latitudeForBand = fitted.span.latitudeDelta / visible
        let latitudeForWidth = fitted.span.longitudeDelta / (aspect * secant)
        let latitudeDelta = max(latitudeForBand, latitudeForWidth)
        let longitudeDelta = latitudeDelta * aspect * secant
        let centerLatitude = fitted.center.latitude - latitudeDelta * (bottom - top) / 2
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: min(85, max(-85, centerLatitude)),
                longitude: fitted.center.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    /// Same vertical fit when the view size is not known yet. Longitude stays put;
    /// MapKit may still widen the latitude span to match the view.
    private static func latitudeShift(
        _ fitted: MKCoordinateRegion,
        top: Double,
        bottom: Double,
        visible: Double
    ) -> MKCoordinateRegion {
        var shifted = fitted
        shifted.span.latitudeDelta = fitted.span.latitudeDelta / visible
        shifted.center.latitude = fitted.center.latitude - shifted.span.latitudeDelta * (bottom - top) / 2
        return shifted
    }
}

final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var coordinate: CLLocationCoordinate2D?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }
}

import CoreLocation

/// Display-only WGS-84 → GCJ-02. Stored GPS and Health samples stay WGS-84.
///
/// Tianditu `ter_w` is CGCS2000, which is close enough to WGS-84 to draw stored
/// tracks unchanged once `canReplaceMapContent` replaces the basemap. Nothing in
/// this repo shows MapKit still offsetting overlays after that replacement, so
/// `shiftTracksOnTianditu` stays false. Turn it on only if a mainland device
/// shows the track missing the Tianditu roads (or missing MapKit's user dot).
///
/// The system basemap in mainland China is Gaode's GCJ-02 map. MapKit does not
/// document converting developer overlays, so those tracks are shifted for
/// display. Turn `shiftTracksOnSystemMap` off if a mainland device shows MapKit
/// already applying that shift (a second one would miss the roads).
enum ChinaCoordinate {
    static let shiftTracksOnTianditu = false
    static let shiftTracksOnSystemMap = true

    private static let axis = 6378245.0
    private static let eccentricitySquared = 0.00669342162296594323

    static func shiftsTracks(on mode: SkyBasemapMode) -> Bool {
        switch mode {
        case .tianditu:
            return shiftTracksOnTianditu
        case .system:
            return shiftTracksOnSystemMap
        }
    }

    static func display(fromStored coordinate: CLLocationCoordinate2D, basemap: SkyBasemapMode) -> CLLocationCoordinate2D {
        guard shiftsTracks(on: basemap), coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            return coordinate
        }
        return gcj(from: coordinate)
    }

    /// Inverse of `display`. Map taps come back in the basemap's datum.
    static func stored(fromDisplay coordinate: CLLocationCoordinate2D, basemap: SkyBasemapMode) -> CLLocationCoordinate2D {
        guard shiftsTracks(on: basemap), coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            return coordinate
        }
        return wgs(fromGCJ: coordinate)
    }

    static func gcj(from wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let latitude = wgs.latitude
        let longitude = wgs.longitude
        guard isOffsetRegion(latitude: latitude, longitude: longitude) else { return wgs }
        var deltaLatitude = transformLatitude(longitude - 105.0, latitude - 35.0)
        var deltaLongitude = transformLongitude(longitude - 105.0, latitude - 35.0)
        let radianLatitude = latitude / 180.0 * Double.pi
        var magic = sin(radianLatitude)
        magic = 1 - eccentricitySquared * magic * magic
        let square = sqrt(magic)
        deltaLatitude = (deltaLatitude * 180.0) / ((axis * (1 - eccentricitySquared)) / (magic * square) * Double.pi)
        deltaLongitude = (deltaLongitude * 180.0) / (axis / square * cos(radianLatitude) * Double.pi)
        return CLLocationCoordinate2D(latitude: latitude + deltaLatitude, longitude: longitude + deltaLongitude)
    }

    static func wgs(fromGCJ gcjCoordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isOffsetRegion(latitude: gcjCoordinate.latitude, longitude: gcjCoordinate.longitude) else {
            return gcjCoordinate
        }
        var guess = gcjCoordinate
        for _ in 0..<10 {
            let shifted = gcj(from: guess)
            let deltaLatitude = shifted.latitude - gcjCoordinate.latitude
            let deltaLongitude = shifted.longitude - gcjCoordinate.longitude
            if abs(deltaLatitude) < 1e-8, abs(deltaLongitude) < 1e-8 { break }
            guess = CLLocationCoordinate2D(
                latitude: guess.latitude - deltaLatitude,
                longitude: guess.longitude - deltaLongitude
            )
        }
        return guess
    }

    /// Coarse box from the public GCJ offset. Outside it, the point is unchanged.
    /// Hong Kong and Macao sit inside the box and use the same Gaode offset.
    private static func isOffsetRegion(latitude: Double, longitude: Double) -> Bool {
        longitude > 73.66 && longitude < 135.05 && latitude > 3.86 && latitude < 53.55
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var value = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        value += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        value += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        value += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return value
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var value = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        value += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        value += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        value += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return value
    }
}

enum TrackDatum {
    static func displayed(_ points: [GeoPoint], mode: SkyBasemapMode) -> [GeoPoint] {
        guard ChinaCoordinate.shiftsTracks(on: mode) else { return points }
        return points.map { point in
            let shown = ChinaCoordinate.gcj(from: point.coordinate)
            return GeoPoint(
                latitude: shown.latitude,
                longitude: shown.longitude,
                altitude: point.altitude,
                timestamp: point.timestamp
            )
        }
    }
}

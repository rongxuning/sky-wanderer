import Foundation

/// GPX for a finished workout track. `addGPXRoutes` is the route store; this only builds the file it already imports.
enum WorkoutTrackExport {
    /// Planned-route checkpoints win. A free run uses one CP per full kilometer, with the track altitude.
    static func gpx(name: String, points: [GeoPoint], course: [RouteWaypoint]) -> Data? {
        guard points.count >= 2 else { return nil }
        let waypoints = course.isEmpty ? kilometerCourse(points) : courseWithElevation(course, track: points)
        return Data(document(name: name, points: points, waypoints: waypoints).utf8)
    }

    static func kilometerCourse(_ points: [GeoPoint]) -> [RouteWaypoint] {
        RouteKilometers.markers(along: points).map { marker in
            RouteWaypoint(
                name: "CP\(marker.kilometer)",
                latitude: marker.latitude,
                longitude: marker.longitude,
                elevation: marker.altitude,
                cutoff: nil
            )
        }
    }

    private static func courseWithElevation(_ course: [RouteWaypoint], track: [GeoPoint]) -> [RouteWaypoint] {
        course.map { waypoint in
            guard waypoint.elevation == nil else { return waypoint }
            var copy = waypoint
            copy.elevation = nearestAltitude(waypoint, track: track)
            return copy
        }
    }

    private static func nearestAltitude(_ waypoint: RouteWaypoint, track: [GeoPoint]) -> Double? {
        let probe = GeoPoint(latitude: waypoint.latitude, longitude: waypoint.longitude, altitude: 0, timestamp: nil)
        var best = Double.greatestFiniteMagnitude
        var altitude: Double?
        for point in track {
            let distance = RouteStats.flatMeters(probe, point)
            if distance < best {
                best = distance
                altitude = point.altitude
            }
        }
        return altitude
    }

    private static func document(name: String, points: [GeoPoint], waypoints: [RouteWaypoint]) -> String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<gpx version=\"1.1\" creator=\"sky-wanderer\" xmlns=\"http://www.topografix.com/GPX/1/1\">",
            "<metadata><name>\(escape(name))</name></metadata>"
        ]
        for waypoint in waypoints where abs(waypoint.latitude) <= 90 && abs(waypoint.longitude) <= 180 {
            lines.append(
                "<wpt lat=\"\(number(waypoint.latitude))\" lon=\"\(number(waypoint.longitude))\">\(elevation(waypoint.elevation))<name>\(escape(waypoint.name))</name></wpt>"
            )
        }
        lines.append("<trk><name>\(escape(name))</name><trkseg>")
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime]
        for point in points {
            var body = elevation(point.altitude)
            if let timestamp = point.timestamp {
                body += "<time>\(clock.string(from: timestamp))</time>"
            }
            lines.append("<trkpt lat=\"\(number(point.latitude))\" lon=\"\(number(point.longitude))\">\(body)</trkpt>")
        }
        lines.append("</trkseg></trk></gpx>")
        return lines.joined()
    }

    private static func elevation(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return "<ele>\(number(value))</ele>"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Reverse-geocodes a route start to province + city for the list card.
enum RouteStartRegionLookup {
    /// Looks up province and city. Returns nil only when the geocoder errors so a later pass can retry.
    static func lookup(latitude: Double, longitude: Double) async -> RouteStartRegion? {
        #if canImport(CoreLocation)
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(
                location,
                preferredLocale: Locale(identifier: "zh_CN")
            )
            guard let mark = marks.first else {
                return RouteStartRegion(province: nil, city: nil)
            }
            return RouteStartRegion(
                province: clean(mark.administrativeArea),
                city: clean(mark.locality)
            )
        } catch {
            return nil
        }
        #else
        return RouteStartRegion(province: nil, city: nil)
        #endif
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

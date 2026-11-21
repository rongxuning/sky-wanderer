import ActivityKit
import Foundation

struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var elapsed: TimeInterval
        var distanceMeters: Double
        var paceSecPerKm: Double
        var heartRate: Double
        var paused: Bool
    }

    var sportTitle: String
}

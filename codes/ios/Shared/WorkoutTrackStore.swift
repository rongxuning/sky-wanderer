import Foundation

/// Full GPS track for one workout, under Application Support `workout-tracks/<id>.json`.
///
/// `phone.json` keeps a short polyline for the records list. Detail, export, and
/// planned-route reuse call `points(for:)` to read the full file.
enum WorkoutTrackStore {
    static let folder = "workout-tracks"
    /// Max points kept inside `WorkoutRecord.route` for list cards and thumbnails.
    static let summaryLimit = 64

    static func filename(for workoutID: UUID) -> String {
        "\(folder)/\(workoutID.uuidString).json"
    }

    /// Writes the full track. Returns the relative filename, or nil if the write fails.
    @discardableResult
    static func save(_ points: [GeoPoint], workoutID: UUID) -> String? {
        guard !points.isEmpty else { return nil }
        let name = filename(for: workoutID)
        guard let url = try? url(forRelative: name) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(points)
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func load(filename: String?) -> [GeoPoint]? {
        guard let url = try? url(forRelative: filename) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([GeoPoint].self, from: data)
    }

    static func delete(filename: String?) {
        guard let url = try? url(forRelative: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func delete(workoutID: UUID) {
        delete(filename: filename(for: workoutID))
    }

    /// Evenly samples so the list polyline stays small. Keeps endpoints.
    static func summarize(_ points: [GeoPoint], limit: Int = summaryLimit) -> [GeoPoint] {
        guard limit > 1, points.count > limit else { return points }
        let lastIndex = points.count - 1
        var result: [GeoPoint] = []
        result.reserveCapacity(limit)
        var seen = Set<Int>()
        for slot in 0..<limit {
            let index = Int((Double(slot) * Double(lastIndex) / Double(limit - 1)).rounded())
            if seen.insert(index).inserted {
                result.append(points[index])
            }
        }
        return result
    }

    /// Full track when a side file exists; otherwise the in-record polyline.
    static func points(for workout: WorkoutRecord) -> [GeoPoint] {
        if let loaded = load(filename: workout.routeTrackFilename), !loaded.isEmpty {
            return loaded
        }
        return workout.route
    }

    /// Moves a long in-record track into its side file and leaves a list summary.
    /// Returns true when the record changed.
    @discardableResult
    static func detach(_ workout: inout WorkoutRecord) -> Bool {
        // Already externalized: do not reload the full file on every launch.
        if let filename = workout.routeTrackFilename, !filename.isEmpty {
            var changed = false
            if workout.route.count > summaryLimit {
                workout.route = summarize(workout.route)
                changed = true
            }
            if workout.routePointCount <= 0 {
                if let loaded = load(filename: filename), !loaded.isEmpty {
                    workout.routePointCount = loaded.count
                    changed = true
                } else if workout.routePointCount != workout.route.count {
                    workout.routePointCount = workout.route.count
                    changed = true
                }
            }
            return changed
        }

        let full = workout.route
        guard !full.isEmpty else {
            if workout.routePointCount != 0 {
                workout.routePointCount = 0
                return true
            }
            return false
        }

        // Short tracks stay in phone.json; no side file needed.
        if full.count <= summaryLimit {
            if workout.routePointCount != full.count {
                workout.routePointCount = full.count
                return true
            }
            return false
        }

        guard let filename = save(full, workoutID: workout.id) else {
            // Keep the full polyline in phone.json when the side file cannot be written.
            if workout.routePointCount != full.count {
                workout.routePointCount = full.count
                return true
            }
            return false
        }
        let summary = summarize(full)
        var changed = false
        if workout.routeTrackFilename != filename {
            workout.routeTrackFilename = filename
            changed = true
        }
        if workout.routePointCount != full.count {
            workout.routePointCount = full.count
            changed = true
        }
        if workout.route != summary {
            workout.route = summary
            changed = true
        }
        return changed
    }

    /// Detaches every workout that still embeds a long track. Returns whether any row changed.
    @discardableResult
    static func migrate(_ workouts: inout [WorkoutRecord]) -> Bool {
        var changed = false
        for index in workouts.indices {
            if detach(&workouts[index]) {
                changed = true
            }
        }
        return changed
    }

    private static func url(forRelative name: String?) throws -> URL {
        guard let name, !name.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let file = URL(fileURLWithPath: name).lastPathComponent
        guard file.hasSuffix(".json"), file != ".json", !file.contains("..") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let stored = "\(folder)/\(file)"
        guard name == stored || name == file else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = try AppFiles.directory().appendingPathComponent(folder, isDirectory: true)
        return directory.appendingPathComponent(file)
    }
}

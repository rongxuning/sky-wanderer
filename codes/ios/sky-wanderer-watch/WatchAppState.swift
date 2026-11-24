import Combine
import Foundation

@MainActor
final class WatchAppState: ObservableObject {
    @Published private(set) var database: Database

    private let filename = "watch.json"

    init() {
        if var loaded = AppFiles.load(filename), loaded.seeded {
            let before = loaded.workouts.count
            let routeCount = loaded.routes.count
            loaded.workouts.removeAll { SampleLibrary.isSeededWorkout($0) }
            let needsLines = loaded.workouts.contains { RecordMotivation.storedLine($0.motivationLine) == nil }
            Self.ensurePresetRoute(&loaded)
            RecordMotivation.assignMissing(&loaded.workouts)
            database = loaded
            if loaded.workouts.count != before || needsLines || loaded.routes.count != routeCount {
                AppFiles.save(loaded, name: filename)
            }
        } else {
            var fresh = Database()
            fresh.posts = SampleLibrary.posts()
            fresh.seeded = true
            Self.ensurePresetRoute(&fresh)
            database = fresh
            AppFiles.save(fresh, name: filename)
        }
    }

    var workouts: [WorkoutRecord] {
        database.workouts
            .filter { !SampleLibrary.isSeededWorkout($0) }
            .sorted { $0.start > $1.start }
    }

    var routes: [SavedRoute] {
        database.routes.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .presetRunning
            }
            let left = lhs.importedAt ?? .distantPast
            let right = rhs.importedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var members: [TeammateProfile] {
        SampleLibrary.teammates.filter { database.selectedTeammateIDs.contains($0.id) }
    }

    func stats(for window: StatsWindow) -> TrainingStats {
        RecordStats.make(workouts: workouts, window: window)
    }

    func estimate() -> TrainingEstimateSummary {
        TrainingEstimate.summarize(workouts: workouts)
    }

    func route(id: String) -> SavedRoute? {
        database.routes.first { $0.id == id }
    }

    func toggleTeammate(_ id: String) {
        mutate { database in
            if let index = database.selectedTeammateIDs.firstIndex(of: id) {
                database.selectedTeammateIDs.remove(at: index)
            } else {
                database.selectedTeammateIDs.append(id)
            }
        }
    }

    func add(_ record: WorkoutRecord) {
        guard !SampleLibrary.isSeededWorkout(record) else { return }
        mutate { database in
            let previous = database.workouts.first { existing in
                if existing.id == record.id { return true }
                if let healthID = record.healthKitUUID, existing.healthKitUUID == healthID {
                    return true
                }
                return false
            }
            database.workouts.removeAll { $0.id == record.id }
            if let healthID = record.healthKitUUID {
                database.workouts.removeAll { $0.healthKitUUID == healthID }
            }
            var record = record
            if RecordMotivation.storedLine(record.motivationLine) == nil {
                record.motivationLine = RecordMotivation.storedLine(previous?.motivationLine)
            }
            database.workouts.append(record)
            database.workouts.sort { $0.start > $1.start }
            RecordMotivation.assignMissing(&database.workouts)
        }
    }

    func importFromApple() async {
        guard AppleHealth.available else { return }
        do {
            try await AppleHealth.authorize()
        } catch {
            return
        }
        let outcome = await RecordsRefresh.performAsync {
            try await AppleActivitySource().importWorkouts()
        }
        guard !outcome.failed, !outcome.cancelled else { return }
        mutate { database in
            WorkoutImport.merge(outcome.records, into: &database.workouts)
        }
    }

    private static func ensurePresetRoute(_ database: inout Database) {
        guard !database.routes.contains(where: { $0.id == SavedRoute.presetRunningID }) else { return }
        database.routes.insert(SampleLibrary.presetRunningRoute(), at: 0)
    }

    private func mutate(_ body: (inout Database) -> Void) {
        var copy = database
        body(&copy)
        database = copy
        AppFiles.save(copy, name: filename)
    }
}

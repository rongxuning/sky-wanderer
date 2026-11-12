import Foundation

// swiftc -swift-version 5 codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/Shared/Formatting.swift \
//   codes/ios/Shared/RecordsRefresh.swift \
//   codes/ios/records-refresh-check/main.swift \
//   -o /tmp/records-refresh-check && /tmp/records-refresh-check

/// SampleLibrary's preset route names this. The check does not compile LiveSession.
enum MapOrigin {
    static let fallback = GeoPoint(latitude: 31.24, longitude: 121.49, altitude: 12, timestamp: nil)
}

let failureLock = NSLock()
var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failureLock.lock()
        failures.append(message)
        failureLock.unlock()
    }
}

let storedStart = Date(timeIntervalSince1970: 1_762_790_000) // 2026-11-10 12:13:20 UTC

func makeWorkout(start: Date, healthKitUUID: String) -> WorkoutRecord {
    WorkoutRecord(
        id: UUID(),
        sport: .running,
        start: start,
        end: start.addingTimeInterval(30 * 60),
        distanceMeters: 5_000,
        energyKilocalories: 300,
        averageHeartRate: 140,
        averageCadence: 170,
        elevationGainMeters: 40,
        route: [],
        splits: [],
        heartRate: [],
        cadenceSeries: [],
        paceSeries: [],
        stride: [],
        elevation: [],
        groundContact: [],
        power: [],
        origin: .apple,
        healthKitUUID: healthKitUUID
    )
}

struct ImportFailure: Error {}

/// Stands in for a HealthKit query. `release` resumes it so the check can exit
/// without leaving the shared import's continuation hanging.
final class StuckImport: @unchecked Sendable {
    private let lock = NSLock()
    private var resume: (() -> Void)?
    private var released = false

    func store(_ resume: @escaping () -> Void) {
        lock.lock()
        if released {
            lock.unlock()
            resume()
            return
        }
        self.resume = resume
        lock.unlock()
    }

    func release() {
        lock.lock()
        released = true
        let resume = self.resume
        self.resume = nil
        lock.unlock()
        resume?()
    }
}

final class OutcomeBox: @unchecked Sendable {
    var outcome: RecordsRefresh.Outcome?
}

/// The check process's main thread stays in `dispatchMain`. Waiting here does not
/// block the thread the importer is required to leave free.
func awaitOutcome(
    _ body: @escaping @Sendable () async -> RecordsRefresh.Outcome
) -> RecordsRefresh.Outcome {
    let ready = DispatchSemaphore(value: 0)
    let box = OutcomeBox()
    DispatchQueue.global(qos: .userInitiated).async {
        Task {
            box.outcome = await body()
            ready.signal()
        }
    }
    let result = ready.wait(timeout: .now() + 5)
    check(result == .success, "refresh returned within 5s")
    return box.outcome ?? .failure
}

func finish(_ name: String) {
    if failures.isEmpty {
        print("\(name) ok")
        exit(0)
    }
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}

DispatchQueue.global(qos: .userInitiated).async {
    let offMain = awaitOutcome {
        await RecordsRefresh.perform {
            let onMain = Thread.isMainThread
            check(onMain == false, "import work runs off the main thread, saw main=\(onMain)")
            return [makeWorkout(start: storedStart.addingTimeInterval(48 * 60 * 60), healthKitUUID: "HK-NEW")]
        }
    }
    check(offMain.failed == false && offMain.cancelled == false, "successful import is not an error")
    check(offMain.records.count == 1, "successful import keeps the new workout")

    var listed = [makeWorkout(start: storedStart, healthKitUUID: "HK-OLD")]
    WorkoutImport.merge(offMain.records, into: &listed)
    check(listed.first?.healthKitUUID == "HK-NEW", "a newer imported workout is first in the records list")
    check(listed.contains { $0.healthKitUUID == "HK-OLD" }, "refresh keeps the workout that was already listed")

    let empty = awaitOutcome {
        await RecordsRefresh.perform { [] }
    }
    check(empty.failed == false && empty.cancelled == false && empty.records.isEmpty, "an empty import still finishes")

    let failed = awaitOutcome {
        await RecordsRefresh.perform { () throws -> [WorkoutRecord] in
            throw ImportFailure()
        }
    }
    check(failed.failed && failed.records.isEmpty && failed.cancelled == false, "a thrown import finishes as a failure")

    let asyncOffMain = awaitOutcome {
        await RecordsRefresh.performAsync {
            let onMain = Thread.isMainThread
            check(onMain == false, "async import work runs off the main thread, saw main=\(onMain)")
            return []
        }
    }
    check(asyncOffMain.failed == false && asyncOffMain.records.isEmpty, "async empty import finishes")

    let stuck = StuckImport()
    let cancelled = awaitOutcome {
        let task = Task {
            await RecordsRefresh.waitFor {
                await withCheckedContinuation { (continuation: CheckedContinuation<RecordsRefresh.Outcome, Never>) in
                    stuck.store {
                        continuation.resume(returning: .empty)
                    }
                }
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let outcome = await task.value
        // The shared import is not cancelled with the spinner. Let it finish so
        // the check does not leak the continuation it used as a stand-in.
        stuck.release()
        return outcome
    }
    check(cancelled.cancelled, "cancelling the refresh ends the wait")
    check(cancelled.failed == false, "cancellation is not reported as an import failure")

    let session = RefreshSession()
    session.complete(RecordsRefresh.Outcome(records: offMain.records, failed: false, cancelled: false))
    session.cancel()
    let kept = awaitOutcome { await session.wait() }
    check(kept.records.count == 1 && kept.cancelled == false, "a finished import is not replaced by a later cancel")

    finish("records-refresh-check")
}
dispatchMain()

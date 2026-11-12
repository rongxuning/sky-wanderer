import Foundation

/// Records pull-to-refresh and the tab's Health import.
///
/// The spinner is already on screen when this runs. HealthKit delivers query
/// handlers on a queue that also has to make progress, and the handler used to
/// resume the main-actor import inline. That left the main thread inside the
/// callback, so the next query never finished and `WorkoutImport.merge` never
/// ran. The list stayed on the last saved workout.
///
/// `perform` / `performAsync` run the import off the main thread and always
/// return, including when the import throws or finds nothing. `waitFor` returns
/// on cancellation too, so the spinner can end while a shared import is still
/// free to publish workouts it already read.
enum RecordsRefresh {
    struct Outcome: Equatable {
        var records: [WorkoutRecord]
        /// The import threw. An empty `records` with `failed == false` is a real
        /// read that found no running or hiking workouts.
        var failed: Bool
        /// The refresh waiter stopped because the pull was cancelled. Not an error.
        var cancelled: Bool

        static let empty = Outcome(records: [], failed: false, cancelled: false)
        static let failure = Outcome(records: [], failed: true, cancelled: false)
        static let cancelledWait = Outcome(records: [], failed: false, cancelled: true)
    }

    private static let queue = DispatchQueue(label: "sky.records.refresh", qos: .userInitiated)

    /// Runs `work` off the main thread. A throw becomes `failure`. An empty array
    /// is a successful empty import.
    static func perform(
        _ work: @escaping @Sendable () throws -> [WorkoutRecord]
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                let outcome: Outcome
                do {
                    outcome = Outcome(records: try work(), failed: false, cancelled: false)
                } catch {
                    outcome = .failure
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Async import (HealthKit queries and series builds). Same completion rules as `perform`.
    static func performAsync(
        _ work: @escaping @Sendable () async throws -> [WorkoutRecord]
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                let task = Task {
                    let outcome: Outcome
                    do {
                        outcome = Outcome(records: try await work(), failed: false, cancelled: false)
                    } catch is CancellationError {
                        outcome = .cancelledWait
                    } catch {
                        outcome = .failure
                    }
                    continuation.resume(returning: outcome)
                }
                withExtendedLifetime(task) {}
            }
        }
    }

    /// Waits until `operation` finishes, or until this task is cancelled.
    /// Cancellation does not cancel `operation`: a shared import can still merge.
    static func waitFor(
        _ operation: @escaping @Sendable () async -> Outcome
    ) async -> Outcome {
        let session = RefreshSession()
        let worker = Task.detached {
            let outcome = await operation()
            session.complete(outcome)
        }
        let outcome = await withTaskCancellationHandler {
            await session.wait()
        } onCancel: {
            session.cancel()
        }
        withExtendedLifetime(worker) {}
        return outcome
    }
}

/// One refresh wait. The first `complete` or `cancel` wins. A second call does not
/// resume the continuation again.
final class RefreshSession: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RecordsRefresh.Outcome, Never>?
    private var outcome: RecordsRefresh.Outcome?

    func wait() async -> RecordsRefresh.Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete(_ outcome: RecordsRefresh.Outcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }

    /// Ends the wait so the spinner can stop. Ignored once an import has already won.
    func cancel() {
        complete(.cancelledWait)
    }
}

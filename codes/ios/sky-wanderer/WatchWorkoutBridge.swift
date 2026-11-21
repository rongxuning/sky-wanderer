import Foundation
import HealthKit
import WatchConnectivity

/// Starts this workout on the paired watch and waits for the mirrored session.
/// The phone keeps its own GPS and pedometer when the watch is absent or silent.
@MainActor
enum WatchWorkoutBridge {
    static func mirroredSession(for sport: SportKind) async -> HKWorkoutSession? {
        guard await WatchLink.shared.canLaunchWatchApp() else { return nil }
        return await WatchMirrorGate.shared.request(sport)
    }
}

final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private let lock = NSLock()
    private var activation: CheckedContinuation<Void, Never>?

    func canLaunchWatchApp() async -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                self.activation = continuation
                self.lock.unlock()
                session.activate()
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.finishActivation()
                }
            }
        }
        return session.isPaired && session.isWatchAppInstalled
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        self.finishActivation()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    private func finishActivation() {
        lock.lock()
        let continuation = activation
        activation = nil
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
final class WatchMirrorGate {
    static let shared = WatchMirrorGate()
    private var waiter: CheckedContinuation<HKWorkoutSession?, Never>?
    /// False after a timeout, so a late mirror is ended instead of becoming a second workout.
    private var acceptLate = false

    func request(_ sport: SportKind) async -> HKWorkoutSession? {
        acceptLate = true
        AppleHealth.store.workoutSessionMirroringStartHandler = { session in
            Task { @MainActor in
                WatchMirrorGate.shared.receive(session)
            }
        }
        let launched = await launch(sport)
        guard launched else {
            acceptLate = false
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.finish(nil)
            }
        }
    }

    private func launch(_ sport: SportKind) async -> Bool {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = sport.hkActivity
        configuration.locationType = .outdoor
        return await withCheckedContinuation { continuation in
            AppleHealth.store.startWatchApp(with: configuration) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private func receive(_ session: HKWorkoutSession) {
        guard acceptLate else {
            session.end()
            return
        }
        finish(session)
    }

    private func finish(_ session: HKWorkoutSession?) {
        let continuation = waiter
        waiter = nil
        if continuation == nil {
            session?.end()
            return
        }
        if session == nil {
            acceptLate = false
        }
        continuation.resume(returning: session)
    }
}

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
    /// Arrived before the waiter was installed. Delivered as soon as the waiter exists.
    private var held: HKWorkoutSession?
    /// Already returned to the phone. A second callback for this object must not end it.
    private var delivered: HKWorkoutSession?
    /// False after delivery, launch failure, or timeout. A different session is ended.
    private var accept = false

    func request(_ sport: SportKind) async -> HKWorkoutSession? {
        accept = true
        held = nil
        delivered = nil
        AppleHealth.store.workoutSessionMirroringStartHandler = { session in
            Task { @MainActor in
                WatchMirrorGate.shared.receive(session)
            }
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            if let held {
                self.held = nil
                deliver(held)
            }
            Task { @MainActor in
                let launched = await self.launch(sport)
                if !launched {
                    self.giveUp(resumeNil: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.giveUp(resumeNil: self.waiter != nil)
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
        if session === delivered || session === held { return }
        guard accept else {
            session.end()
            return
        }
        if waiter != nil {
            deliver(session)
        } else {
            held = session
        }
    }

    private func deliver(_ session: HKWorkoutSession) {
        let continuation = waiter
        waiter = nil
        delivered = session
        accept = false
        continuation?.resume(returning: session)
    }

    /// Launch failed or the wait expired. Ends a session that was never handed to the phone.
    private func giveUp(resumeNil: Bool) {
        accept = false
        let extra = held
        held = nil
        extra?.end()
        guard resumeNil, let continuation = waiter else { return }
        waiter = nil
        continuation.resume(returning: nil)
    }
}

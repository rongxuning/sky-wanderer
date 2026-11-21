import Foundation
import HealthKit
import UIKit
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

final class WatchLink: NSObject, WCSessionDelegate, PhoneWatchLiveSink {
    static let shared = WatchLink()
    private let lock = NSLock()
    private var activation: CheckedContinuation<Void, Never>?
    /// Tiny JPEG for the live map puck. Sent with the first active snapshot of a session.
    private var pendingAvatarJPEG: Data?
    private var pendingAvatarName = ""
    private var didSendAvatar = false

    func canLaunchWatchApp() async -> Bool {
        guard await activateIfNeeded() else { return false }
        let session = WCSession.default
        return session.isPaired && session.isWatchAppInstalled
    }

    @MainActor
    func prepareLiveAvatar(image: UIImage?, name: String) {
        pendingAvatarName = name
        didSendAvatar = false
        guard let image else {
            pendingAvatarJPEG = nil
            return
        }
        let side: CGFloat = 72
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let square = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        pendingAvatarJPEG = square.jpegData(compressionQuality: 0.55)
    }

    @MainActor
    func pushLive(_ snapshot: PhoneWatchLiveSnapshot) {
        guard WCSession.isSupported() else { return }
        Task { @MainActor in
            guard await self.activateIfNeeded() else { return }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            guard var payload = try? snapshot.dictionary() else { return }
            if snapshot.active, !self.didSendAvatar {
                if let jpeg = self.pendingAvatarJPEG {
                    payload[PhoneWatchLiveSnapshot.avatarContextKey] = jpeg
                }
                if !self.pendingAvatarName.isEmpty {
                    payload[PhoneWatchLiveSnapshot.nameContextKey] = self.pendingAvatarName
                }
                self.didSendAvatar = true
            }
            if !snapshot.active {
                self.didSendAvatar = false
            }
            try? session.updateApplicationContext(payload)
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { _ in }
            }
        }
    }

    @MainActor
    func endLive() {
        pushLive(.idle())
    }

    @discardableResult
    private func activateIfNeeded() async -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        session.delegate = self
        if session.activationState == .activated { return true }
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
        return session.activationState == .activated
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
    /// Bumped on every request so a previous wait cannot clear the next one.
    private var generation = 0
    /// Watch unlock / Health prompt often needs more than a few seconds.
    private static let mirrorWaitNanoseconds: UInt64 = 20_000_000_000

    func request(_ sport: SportKind) async -> HKWorkoutSession? {
        generation += 1
        let token = generation
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
                guard token == self.generation else { return }
                if !launched {
                    self.giveUp(resumeNil: true)
                    return
                }
                try? await Task.sleep(nanoseconds: Self.mirrorWaitNanoseconds)
                guard token == self.generation else { return }
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

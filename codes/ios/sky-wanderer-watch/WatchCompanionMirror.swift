import Foundation
import UIKit
import WatchConnectivity

/// Receives phone live snapshots over WatchConnectivity and opens the companion workout UI.
@MainActor
final class WatchCompanionMirror: NSObject, ObservableObject {
    static let shared = WatchCompanionMirror()

    @Published private(set) var snapshot = PhoneWatchLiveSnapshot.idle()
    @Published private(set) var userAvatar: UIImage?
    @Published private(set) var userName = ""
    @Published var showingPhoneWorkout = false

    private var activated = false

    func activate() {
        guard !activated else { return }
        activated = true
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// HealthKit `startWatchApp` landed. Show the companion screens even before the first payload.
    func notePhoneLaunch(sport: SportKind) {
        if !snapshot.active {
            snapshot = PhoneWatchLiveSnapshot.from(
                sport: sport,
                elapsed: 0,
                distanceMeters: 0,
                paceSecPerKm: 0,
                heartRate: 0,
                cadence: 0,
                altitudeMeters: 0,
                paused: false,
                userFix: nil,
                route: [],
                kilometers: []
            )
        }
        showingPhoneWorkout = true
    }

    func apply(_ next: PhoneWatchLiveSnapshot) {
        snapshot = next
        if next.active {
            showingPhoneWorkout = true
        } else if showingPhoneWorkout {
            showingPhoneWorkout = false
            userAvatar = nil
            userName = ""
        }
    }

    private func ingest(_ dictionary: [String: Any]) {
        if let jpeg = dictionary[PhoneWatchLiveSnapshot.avatarContextKey] as? Data, let image = UIImage(data: jpeg) {
            userAvatar = image
        }
        if let name = dictionary[PhoneWatchLiveSnapshot.nameContextKey] as? String {
            userName = name
        }
        guard let next = PhoneWatchLiveSnapshot.decode(from: dictionary) else { return }
        apply(next)
    }
}

extension WatchCompanionMirror: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        let context = session.receivedApplicationContext
        Task { @MainActor in
            if !context.isEmpty {
                self.ingest(context)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.ingest(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.ingest(message)
        }
    }
}


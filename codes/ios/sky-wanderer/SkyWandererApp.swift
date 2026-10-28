import SwiftUI

@main
struct SkyWandererApp: App {
    @StateObject private var app = PhoneAppState()
    @StateObject private var draft = WorkoutDraft()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(draft)
                .tint(Color.omniCobalt)
        }
    }
}

enum TrainRoute: Hashable {
    case start
    case team
    case live
    case layout
}

enum RecordRoute: Hashable {
    case detail(UUID)
}

enum MeRoute: Hashable {
    case layout
}

enum MapRoute: Hashable {
    case editor
}

struct RootView: View {
    @EnvironmentObject private var app: PhoneAppState

    var body: some View {
        Group {
            if app.isLoggedIn {
                SkyHome()
            } else {
                AuthFlow()
            }
        }
        .preferredColorScheme(.light)
    }
}

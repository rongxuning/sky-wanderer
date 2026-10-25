import SwiftUI

enum HomeRoute: Hashable {
    case settings
    case scan
    case records
    case routes
    case social
    case me
}

struct SkyHome: View {
    @EnvironmentObject private var app: PhoneAppState
    @StateObject private var solar = SolarLocation()
    @State private var path = NavigationPath()
    @State private var agentText = ""
    @State private var showAgentNote = false
    @State private var showLogin = false

    var body: some View {
        NavigationStack(path: $path) {
            home
                .navigationDestination(for: HomeRoute.self) { homeDestination($0) }
                .navigationDestination(for: TrainRoute.self) { trainDestination($0) }
                .navigationDestination(for: RecordRoute.self) { recordDestination($0) }
                .navigationDestination(for: MapRoute.self) { mapDestination($0) }
                .navigationDestination(for: MeRoute.self) { meDestination($0) }
        }
        .onChange(of: app.finishedToken) { _, token in
            guard token > 0 else { return }
            var next = NavigationPath()
            next.append(HomeRoute.records)
            path = next
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    threadList
                }
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            composer
        }
        .background(SkyHomeColor.page.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear { solar.start() }
        .alert("Sky", isPresented: $showAgentNote) {
            Button("好", role: .cancel) {}
        } message: {
            Text("agent 入口稍后接通")
        }
        .modifier(LoginCover(isPresented: $showLogin))
    }

    private var topBar: some View {
        HStack {
            roundButton(systemName: "gearshape", label: "设置") {
                path.append(HomeRoute.settings)
            }
            Spacer()
            roundButton(systemName: "qrcode.viewfinder", label: "扫一扫") {
                path.append(HomeRoute.scan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var hero: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let daylight = SolarClock.isDaylight(
                at: timeline.date,
                latitude: solar.coordinate.latitude,
                longitude: solar.coordinate.longitude
            )
            VStack(spacing: 8) {
                Image(daylight ? "SkyAvatarDay" : "SkyAvatarNight")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 196, height: 196)
                    .accessibilityLabel(daylight ? "Sky，日间" : "Sky，夜间")
                Text("Sky")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(SkyHomeColor.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
    }

    private var threadList: some View {
        VStack(spacing: 2) {
            threadRow(
                title: "训练",
                subtitle: trainingSubtitle,
                face: .circle,
                color: SkyHomeColor.train
            ) {
                if app.activeSession?.phase == .running {
                    path.append(TrainRoute.live)
                } else {
                    path.append(TrainRoute.start)
                }
            }
            threadRow(
                title: "记录",
                subtitle: recordsSubtitle,
                face: .blob,
                color: SkyHomeColor.record
            ) {
                path.append(HomeRoute.records)
            }
            threadRow(
                title: "路线",
                subtitle: routesSubtitle,
                face: .tile,
                color: SkyHomeColor.route
            ) {
                path.append(HomeRoute.routes)
            }
        }
        .padding(.horizontal, 16)
    }

    private var trainingSubtitle: String {
        app.activeSession?.phase == .running ? "回到进行中的运动" : "开始徒步或跑步"
    }

    private var recordsSubtitle: String {
        app.workouts.isEmpty ? "还没有徒步或跑步" : "\(app.workouts.count) 次徒步和跑步"
    }

    private var routesSubtitle: String {
        app.savedRoutes.isEmpty ? "地图上的路线" : "\(app.savedRoutes.count) 条已保存路线"
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button(action: openAccount) {
                Text(accountMark)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SkyHomeColor.ink)
                    .frame(width: 44, height: 44)
                    .background(SkyHomeColor.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(app.isLoggedIn ? "账号" : "未登录")

            TextField("发消息", text: $agentText)
                .font(.system(size: 16))
                .foregroundStyle(SkyHomeColor.ink)
                .submitLabel(.send)
                .onSubmit(noteAgent)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(SkyHomeColor.chip, in: Capsule())
                .accessibilityLabel("发给 Sky")
            Button(action: noteAgent) {
                Image(systemName: "mic")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SkyHomeColor.ink)
                    .frame(width: 44, height: 44)
                    .background(SkyHomeColor.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("语音")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(SkyHomeColor.page)
    }

    private var accountMark: String {
        guard app.isLoggedIn, let name = app.account?.name, !name.isEmpty else { return "未" }
        return String(name.prefix(1))
    }

    private func openAccount() {
        if app.isLoggedIn {
            path.append(HomeRoute.me)
        } else {
            showLogin = true
        }
    }

    private func noteAgent() {
        agentText = ""
        showAgentNote = true
    }

    private func roundButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SkyHomeColor.ink)
                .frame(width: 42, height: 42)
                .background(SkyHomeColor.chip, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func threadRow(
        title: String,
        subtitle: String,
        face: ThreadFace.Kind,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                ThreadFace(kind: face, color: color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SkyHomeColor.ink)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(SkyHomeColor.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func homeDestination(_ route: HomeRoute) -> some View {
        switch route {
        case .settings:
            SkySettingsView()
        case .scan:
            ScanQRView()
        case .records:
            RecordsView()
        case .routes:
            MapLibraryView()
        case .social:
            SocialFeedView()
        case .me:
            MeView()
        }
    }

    @ViewBuilder
    private func trainDestination(_ route: TrainRoute) -> some View {
        switch route {
        case .start:
            StartMapView(path: $path)
        case .team:
            TeamPickerView()
        case .live:
            LiveWorkoutView()
        case .layout:
            LayoutEditor()
        }
    }

    @ViewBuilder
    private func recordDestination(_ route: RecordRoute) -> some View {
        if case .detail(let id) = route {
            WorkoutDetailView(workoutID: id)
        }
    }

    @ViewBuilder
    private func mapDestination(_ route: MapRoute) -> some View {
        if case .editor = route {
            PresetRouteEditor()
        }
    }

    @ViewBuilder
    private func meDestination(_ route: MeRoute) -> some View {
        if case .layout = route {
            LayoutEditor()
        }
    }
}

private enum SkyHomeColor {
    static let page = Color.white
    static let chip = Color(red: 241 / 255, green: 241 / 255, blue: 244 / 255)
    static let ink = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let train = Color(red: 47 / 255, green: 124 / 255, blue: 246 / 255)
    static let record = Color(red: 140 / 255, green: 90 / 255, blue: 60 / 255)
    static let route = Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
}

private struct ThreadFace: View {
    enum Kind {
        case circle
        case blob
        case tile
    }

    var kind: Kind
    var color: Color

    var body: some View {
        ZStack {
            shape
            HStack(spacing: 5) {
                Capsule()
                    .frame(width: 5.5, height: 11)
                Capsule()
                    .frame(width: 5.5, height: 13)
                    .offset(y: -1)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shape: some View {
        switch kind {
        case .circle:
            Circle()
                .fill(color)
                .frame(width: 44, height: 44)
        case .blob:
            Ellipse()
                .fill(color)
                .frame(width: 46, height: 38)
                .rotationEffect(.degrees(-8))
        case .tile:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color)
                .frame(width: 40, height: 40)
                .rotationEffect(.degrees(-10))
        }
    }
}

private struct LoginCover: ViewModifier {
    @EnvironmentObject private var app: PhoneAppState
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            AuthFlow()
                .onChange(of: app.isLoggedIn) { _, loggedIn in
                    if loggedIn { isPresented = false }
                }
        }
    }
}

struct SkySettingsView: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var showLogin = false

    var body: some View {
        List {
            Section("账号") {
                if let account = app.account {
                    LabeledContent("昵称", value: account.name)
                    Button("退出登录", role: .destructive) {
                        app.logout()
                    }
                } else {
                    Button("登录") { showLogin = true }
                }
            }
            Section {
                NavigationLink(value: HomeRoute.social) {
                    Text("社交")
                }
                if app.isLoggedIn {
                    NavigationLink(value: HomeRoute.me) {
                        Text("健康与训练")
                    }
                }
            }
            Section {
                Text("首页形象按当地日出和日落切换。没有定位权限时，用上海附近的位置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarHidden(false)
        .modifier(LoginCover(isPresented: $showLogin))
    }
}

struct ScanQRView: View {
    var body: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(SkyHomeColor.ink.opacity(0.85), lineWidth: 3)
                .frame(width: 220, height: 220)
                .overlay {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(SkyHomeColor.secondary)
                }
            Text("扫码稍后接通")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkyHomeColor.ink)
            Text("相机扫码会在下一步接上。")
                .font(.system(size: 14))
                .foregroundStyle(SkyHomeColor.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyHomeColor.page.ignoresSafeArea())
        .navigationTitle("扫一扫")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarHidden(false)
    }
}

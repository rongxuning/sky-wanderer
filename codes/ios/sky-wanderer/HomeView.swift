import SwiftUI

enum HomeRoute: Hashable {
    case settings
    case scan
    case records
    case routes
    case social
    case me
}

enum SkyPage: String, Identifiable {
    case train
    case records
    case routes
    case social
    case me

    var id: String { rawValue }
}

struct SkyHome: View {
    @EnvironmentObject private var app: PhoneAppState
    @StateObject private var solar = SolarLocation()
    @State private var path = NavigationPath()
    @State private var agentText = ""
    @State private var showAgentNote = false
    @State private var showWheel = false
    @FocusState private var composerFocused: Bool

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
            showWheel = false
            var next = NavigationPath()
            next.append(HomeRoute.records)
            path = next
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    hero
                    Spacer(minLength: 0)
                }
                if showWheel {
                    Color.black.opacity(0.16)
                        .contentShape(Rectangle())
                        .onTapGesture { showWheel = false }
                        .accessibilityHidden(true)
                    PageWheel(entries: pageEntries, onSelect: openPage, onCancel: { showWheel = false })
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showWheel)
            bottomBar
        }
        .background(SkyHomeColor.page.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear { solar.start() }
        .onChange(of: composerFocused) { _, focused in
            if focused { showWheel = false }
        }
        .alert("Sky", isPresented: $showAgentNote) {
            Button("好", role: .cancel) {}
        } message: {
            Text("agent 入口稍后接通")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            roundButton(systemName: "gearshape", label: "设置") {
                path.append(HomeRoute.settings)
            }
            accountButton
            Spacer(minLength: 0)
            roundButton(systemName: "qrcode.viewfinder", label: "扫一扫") {
                path.append(HomeRoute.scan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var accountButton: some View {
        Button(action: openAccount) {
            Text(accountMark)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SkyHomeColor.ink)
                .frame(width: 42, height: 42)
                .background {
                    if app.isLoggedIn {
                        Circle().fill(SkyHomeColor.chip)
                    } else {
                        Circle()
                            .stroke(SkyHomeColor.secondary, lineWidth: 1.5)
                            .padding(1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.isLoggedIn ? "账号" : "未登录")
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
            .padding(.vertical, 8)
        }
    }

    private var pageEntries: [PageWheelEntry] {
        [
            PageWheelEntry(
                id: SkyPage.train.rawValue,
                title: "训练",
                subtitle: trainingSubtitle,
                symbol: "figure.run",
                tint: SkyHomeColor.train
            ),
            PageWheelEntry(
                id: SkyPage.records.rawValue,
                title: "记录",
                subtitle: recordsSubtitle,
                symbol: "list.bullet",
                tint: SkyHomeColor.record
            ),
            PageWheelEntry(
                id: SkyPage.routes.rawValue,
                title: "路线",
                subtitle: routesSubtitle,
                symbol: "map",
                tint: SkyHomeColor.route
            ),
            PageWheelEntry(
                id: SkyPage.social.rawValue,
                title: "社交",
                subtitle: "分享和示例动态",
                symbol: "person.2",
                tint: SkyHomeColor.social
            ),
            PageWheelEntry(
                id: SkyPage.me.rawValue,
                title: "我",
                subtitle: "健康与训练",
                symbol: "person",
                tint: SkyHomeColor.me
            ),
        ]
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

    private var bottomBar: some View {
        HStack(spacing: 10) {
            roundButton(
                systemName: showWheel ? "xmark" : "circle.grid.2x2",
                label: showWheel ? "关闭页面" : "页面",
                size: 44
            ) {
                if showWheel {
                    showWheel = false
                } else {
                    composerFocused = false
                    showWheel = true
                }
            }

            TextField("发消息", text: $agentText)
                .font(.system(size: 16))
                .foregroundStyle(SkyHomeColor.ink)
                .focused($composerFocused)
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
        guard app.isLoggedIn else { return }
        path.append(HomeRoute.me)
    }

    private func openPage(_ entry: PageWheelEntry) {
        guard let page = SkyPage(rawValue: entry.id) else { return }
        showWheel = false
        switch page {
        case .train:
            if app.activeSession?.phase == .running {
                path.append(TrainRoute.live)
            } else {
                path.append(TrainRoute.start)
            }
        case .records:
            path.append(HomeRoute.records)
        case .routes:
            path.append(HomeRoute.routes)
        case .social:
            path.append(HomeRoute.social)
        case .me:
            guard app.isLoggedIn else { return }
            path.append(HomeRoute.me)
        }
    }

    private func noteAgent() {
        showWheel = false
        agentText = ""
        showAgentNote = true
    }

    private func roundButton(systemName: String, label: String, size: CGFloat = 42, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SkyHomeColor.ink)
                .frame(width: size, height: size)
                .background(SkyHomeColor.chip, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

enum SkyHomeColor {
    static let page = Color.white
    static let chip = Color(red: 241 / 255, green: 241 / 255, blue: 244 / 255)
    static let ink = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let train = Color(red: 47 / 255, green: 124 / 255, blue: 246 / 255)
    static let record = Color(red: 140 / 255, green: 90 / 255, blue: 60 / 255)
    static let route = Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
    static let social = Color(red: 15 / 255, green: 143 / 255, blue: 122 / 255)
    static let me = Color(red: 90 / 255, green: 98 / 255, blue: 112 / 255)
}

struct SkySettingsView: View {
    @EnvironmentObject private var app: PhoneAppState

    var body: some View {
        List {
            Section("账号") {
                if let account = app.account {
                    LabeledContent("昵称", value: account.name)
                    Button("退出登录", role: .destructive) {
                        app.logout()
                    }
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

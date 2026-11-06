import SwiftUI

enum HomeRoute: Hashable {
    case settings
    case scan
    case records
    case routes
    case social
    case me
}

private enum SkyTab: Hashable {
    case records
    case analysis
    case training
    case routes
}

struct SkyHome: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var tab: SkyTab = .records
    @State private var recordsPath = NavigationPath()
    @State private var analysisPath = NavigationPath()
    @State private var trainingPath = NavigationPath()
    @State private var routesPath = NavigationPath()
    @State private var showLogin = false

    private var showsTabBar: Bool {
        switch tab {
        case .records: recordsPath.isEmpty
        case .analysis: analysisPath.isEmpty
        case .training: trainingPath.isEmpty
        case .routes: routesPath.isEmpty
        }
    }

    var body: some View {
        ZStack {
            stack(path: $recordsPath) {
                tabScreen {
                    RecordFeedView()
                }
            }
            .opacity(tab == .records ? 1 : 0)
            .zIndex(tab == .records ? 1 : 0)
            .allowsHitTesting(tab == .records)
            .accessibilityHidden(tab != .records)

            stack(path: $analysisPath) {
                tabScreen {
                    AnalysisPage()
                }
            }
            .opacity(tab == .analysis ? 1 : 0)
            .zIndex(tab == .analysis ? 1 : 0)
            .allowsHitTesting(tab == .analysis)
            .accessibilityHidden(tab != .analysis)

            stack(path: $trainingPath) {
                tabScreen {
                    TrainingPlaceholder(path: $trainingPath)
                }
            }
            .opacity(tab == .training ? 1 : 0)
            .zIndex(tab == .training ? 1 : 0)
            .allowsHitTesting(tab == .training)
            .accessibilityHidden(tab != .training)

            stack(path: $routesPath) {
                tabScreen {
                    RoutesLibraryView(embeddedInHome: true)
                }
            }
            .opacity(tab == .routes ? 1 : 0)
            .zIndex(tab == .routes ? 1 : 0)
            .allowsHitTesting(tab == .routes)
            .accessibilityHidden(tab != .routes)
        }
        .background(SkyTheme.Color.grouped.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: showsTabBar ? 8 : 0) {
            if showsTabBar {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: SkyTheme.Spacing.controlGap) {
                        AccountAvatarButton {
                            openAccount()
                        }
                        SkyGlassTabBar(selection: $tab)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                SkyTabBarMetrics.width(in: length)
                            }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 4)
            }
        }
        .onChange(of: app.finishedToken) { _, token in
            guard token > 0 else { return }
            returnToRecords()
        }
        .onChange(of: app.isLoggedIn) { _, loggedIn in
            showLogin = false
            guard !loggedIn else { return }
            returnToRecords()
        }
        .fullScreenCover(isPresented: $showLogin) {
            AuthFlow()
        }
    }

    private func stack<Content: View>(
        path: Binding<NavigationPath>,
        @ViewBuilder root: () -> Content
    ) -> some View {
        NavigationStack(path: path) {
            root()
                .navigationDestination(for: HomeRoute.self) { route in
                    SkyDestinations.home(route, presentLogin: { showLogin = true })
                }
                .navigationDestination(for: TrainRoute.self) { route in
                    SkyDestinations.train(route, path: path)
                }
                .navigationDestination(for: RecordRoute.self) { route in
                    SkyDestinations.record(route)
                }
                .navigationDestination(for: MapRoute.self) { route in
                    SkyDestinations.map(route)
                }
                .navigationDestination(for: MeRoute.self) { route in
                    SkyDestinations.me(route)
                }
        }
    }

    private func tabScreen<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkyTheme.Color.grouped)
            .navigationBarHidden(true)
            .toolbar(.hidden, for: .navigationBar)
    }

    private func openAccount() {
        if app.isLoggedIn {
            switch tab {
            case .records:
                recordsPath.append(HomeRoute.me)
            case .analysis:
                analysisPath.append(HomeRoute.me)
            case .training:
                trainingPath.append(HomeRoute.me)
            case .routes:
                routesPath.append(HomeRoute.me)
            }
        } else {
            showLogin = true
        }
    }

    /// Finished workouts and logout both land on an empty records stack.
    private func returnToRecords() {
        recordsPath = NavigationPath()
        analysisPath = NavigationPath()
        trainingPath = NavigationPath()
        routesPath = NavigationPath()
        tab = .records
    }
}

private enum SkyDestinations {
    @ViewBuilder
    static func home(
        _ route: HomeRoute,
        presentLogin: @escaping () -> Void
    ) -> some View {
        switch route {
        case .settings:
            SkySettingsView(onLogin: presentLogin)
        case .scan:
            ScanQRView()
        case .records:
            RecordFeedView()
        case .routes:
            RoutesLibraryView()
        case .social:
            SocialFeedView()
        case .me:
            MeView()
        }
    }

    @ViewBuilder
    static func train(_ route: TrainRoute, path: Binding<NavigationPath>) -> some View {
        switch route {
        case .start:
            StartMapView(path: path)
        case .team:
            TeamPickerView()
        case .live:
            LiveWorkoutView()
        case .layout:
            LayoutEditor()
        }
    }

    @ViewBuilder
    static func record(_ route: RecordRoute) -> some View {
        if case .detail(let id) = route {
            WorkoutDetailView(workoutID: id)
        }
    }

    @ViewBuilder
    static func map(_ route: MapRoute) -> some View {
        switch route {
        case .editor:
            PresetRouteEditor()
        case .detail(let id):
            RouteDetailView(routeID: id)
        }
    }

    @ViewBuilder
    static func me(_ route: MeRoute) -> some View {
        switch route {
        case .avatar:
            MeAvatarScreen()
        case .username:
            MeUsernameScreen()
        case .password:
            MePasswordScreen()
        case .health:
            MeHealthScreen()
        case .trainingAuthorization:
            MeTrainingAuthorizationScreen()
        case .notifications:
            MeNotificationScreen()
        case .sdkList:
            MeSDKListScreen()
        }
    }
}

private struct AccountAvatarButton: View {
    @EnvironmentObject private var app: PhoneAppState
    var action: () -> Void

    /// Glass plate matches the tab bar: a 44pt control plus the bar's 2pt padding on each edge.
    private static let plate = SkyTheme.Spacing.touchMin + 4
    private static let artwork: CGFloat = 40

    var body: some View {
        Button(action: action) {
            avatar
                .frame(width: Self.artwork, height: Self.artwork)
                .frame(width: Self.plate, height: Self.plate)
                .skyFloatingGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.isLoggedIn ? "我的" : "登录")
    }

    @ViewBuilder
    private var avatar: some View {
        if app.isLoggedIn {
            AccountAvatarFace(name: app.account?.name ?? "", image: app.accountAvatar, diameter: Self.artwork)
        } else {
            ScenicAvatar()
        }
    }
}

/// Circular landscape stand-in for the logged-out avatar. Home tab bar and workout detail share it.
struct ScenicAvatar: View {
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack {
                LinearGradient(
                    colors: [SkyTheme.Color.primary, SkyTheme.Color.cardBorder],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Ellipse()
                    .fill(SkyTheme.Color.card.opacity(0.88))
                    .frame(width: width * 0.36, height: height * 0.16)
                    .position(x: width * 0.64, y: height * 0.28)
                hill(width: width, height: height, crest: 0.58, controlY: 0.36, color: SkyTheme.Color.primary.opacity(0.45))
                hill(width: width, height: height, crest: 0.74, controlY: 0.9, color: SkyTheme.Color.success)
                hill(width: width, height: height, crest: 0.86, controlY: 0.78, color: SkyTheme.Color.success.opacity(0.72))
            }
        }
        .clipShape(Circle())
        .overlay {
            Circle().stroke(SkyTheme.Color.card, lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }

    private func hill(width: CGFloat, height: CGFloat, crest: CGFloat, controlY: CGFloat, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: height * crest))
            path.addQuadCurve(
                to: CGPoint(x: width, y: height * (crest - 0.06)),
                control: CGPoint(x: width * 0.48, y: height * controlY)
            )
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: 0, y: height))
            path.closeSubpath()
        }
        .fill(color)
    }
}

private struct TrainingPlaceholder: View {
    @EnvironmentObject private var app: PhoneAppState
    @Binding var path: NavigationPath

    private var running: Bool {
        app.activeSession?.phase == .running
    }

    var body: some View {
        VStack(spacing: SkyTheme.Spacing.screenInset) {
            Spacer(minLength: 0)
            Image(systemName: running ? "figure.run" : "dumbbell")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.primary)
                .accessibilityHidden(true)
            Text(running ? "训练进行中" : "准备开始")
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.ink)
            Text(running ? "可以回到正在进行的运动。" : "开始徒步或跑步。运动数据会留在这台手机上。")
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: openTraining) {
                Text(running ? "回到运动" : "开始训练")
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.onPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: SkyTheme.Spacing.touchMin)
            }
            .buttonStyle(SkyPrimaryButtonStyle())
            .padding(.horizontal, 32)
            .padding(.top, SkyTheme.Spacing.related)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyTheme.Color.grouped)
    }

    private func openTraining() {
        if running {
            path.append(TrainRoute.live)
        } else {
            path.append(TrainRoute.start)
        }
    }
}

private struct SkyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? SkyTheme.Color.primaryPressed : SkyTheme.Color.primary,
                in: Capsule()
            )
    }
}

private extension View {
    /// Frosted plate shared by the home tab capsule and the avatar button.
    func skyFloatingGlass<S: InsettableShape>(in shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.strokeBorder(SkyTheme.Color.card.opacity(0.5), lineWidth: 0.5)
            }
            .shadow(
                color: SkyTheme.Shadow.card.color.opacity(0.08),
                radius: 16,
                y: 4
            )
    }
}

/// Capsule width inside the centered avatar + tabs cluster.
/// Four tabs, still under the design-system ceiling of five.
/// Three tabs used 70% of the width left after the avatar, the gap, and the screen insets.
/// Four two-character labels keep that per-tab width (70% × 4/3). That share is capped at the leftover width.
/// The capsule is also at least four touch targets.
private enum SkyTabBarMetrics {
    static let tabCount: CGFloat = 4

    static func width(in containerWidth: CGFloat) -> CGFloat {
        let avatar = SkyTheme.Spacing.touchMin + 4
        let besideCluster = containerWidth
            - SkyTheme.Spacing.screenInset * 2
            - avatar
            - SkyTheme.Spacing.controlGap
        let fraction = min(0.7 * tabCount / 3, 1)
        let narrowed = besideCluster * fraction
        let minimum = SkyTheme.Spacing.touchMin * tabCount
        return max(narrowed, minimum)
    }
}

private struct SkyGlassTabBar: View {
    @Binding var selection: SkyTab

    var body: some View {
        HStack(spacing: 0) {
            item(.records, symbol: "book", title: "记录")
            item(.analysis, symbol: "chart.bar", title: "分析")
            item(.training, symbol: "figure.run", title: "训练")
            item(.routes, symbol: "map", title: "路线")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .skyFloatingGlass(in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func item(_ tab: SkyTab, symbol: String, title: String) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: selected ? filled(symbol) : symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 20)
                Text(title)
                    .font(SkyTheme.Font.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(selected ? SkyTheme.Color.primary : SkyTheme.Color.secondary)
            .frame(
                minWidth: SkyTheme.Spacing.touchMin,
                maxWidth: .infinity,
                minHeight: SkyTheme.Spacing.touchMin
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Outline symbols stay outline when a filled twin does not exist.
    private func filled(_ symbol: String) -> String {
        switch symbol {
        case "book": return "book.fill"
        case "chart.bar": return "chart.bar.fill"
        case "map": return "map.fill"
        default: return symbol
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
    var onLogin: () -> Void = {}

    var body: some View {
        List {
            Section("账号") {
                if let account = app.account {
                    LabeledContent("昵称", value: account.name)
                    Button("退出登录", role: .destructive) {
                        app.logout()
                    }
                } else {
                    Button("登录", action: onLogin)
                }
            }
            Section {
                NavigationLink(value: HomeRoute.social) {
                    Text("社交")
                }
                if app.isLoggedIn {
                    NavigationLink(value: HomeRoute.me) {
                        Text("我的")
                    }
                }
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

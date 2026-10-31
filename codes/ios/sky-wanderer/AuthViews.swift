import SwiftUI

/// Pushed login routes. Email register and forgot-password stay on the login card.
enum AuthRoute: Hashable {
    case phone
}

struct AuthFlow: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LoginView(path: $path)
                .navigationDestination(for: AuthRoute.self) { route in
                    switch route {
                    case .phone:
                        PhoneVerifyView()
                    }
                }
        }
        .background(LoginSkyBackground())
        .presentationBackground {
            LoginSkyBackground()
        }
        .interactiveDismissDisabled(true)
        .preferredColorScheme(.light)
    }
}

private enum LoginCardMode {
    case login
    case register
}

private enum LoginCardField: Hashable {
    case email
    case displayName
    case password
    case confirmPassword
}

private enum LoginCardNotice: Equatable {
    case failure(String)
    case hint(String)
    case success(String)

    var text: String {
        switch self {
        case .failure(let text), .hint(let text), .success(let text):
            return text
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var app: PhoneAppState
    @Binding var path: NavigationPath
    @State private var mode: LoginCardMode = .login
    @State private var email = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var notice: LoginCardNotice?
    @State private var showNote = false
    @State private var busy = false
    @FocusState private var focusedField: LoginCardField?

    var body: some View {
        ZStack {
            LoginSkyBackground()
            VStack(spacing: 0) {
                topBar
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 8)
                            titleBlock
                            accountCard
                                .padding(.top, 28)
                                .padding(.horizontal, 22)
                            agreement
                                .padding(.top, 16)
                                .padding(.bottom, 12)
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                }
            }
        }
        .navigationBarHidden(true)
        .alert("登录说明", isPresented: $showNote) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loginNote)
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                showNote = true
            } label: {
                Image(systemName: "info")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoginColor.ink.opacity(0.82))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle().strokeBorder(LoginColor.ink.opacity(0.82), lineWidth: 1.35)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("登录说明")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private var titleBlock: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: -2) {
                Text("Sky")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(LoginColor.sky)
                    .tracking(-0.8)
                Text("Wanderer")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(LoginColor.ink)
                    .tracking(-0.4)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    private var agreement: some View {
        Text("登录即表示同意用户协议与隐私政策")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(LoginColor.footer)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private var accountCard: some View {
        VStack(spacing: 0) {
            providerIcons
                .disabled(busy)
                .opacity(busy ? 0.72 : 1)

            orDivider
                .padding(.top, 16)

            accountFields
                .padding(.top, 14)
                .animation(.easeInOut(duration: 0.2), value: mode)

            if let notice {
                Text(notice.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(noticeColor(notice))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            } else if !app.banner.isEmpty {
                Text(app.banner)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }

            Button(action: submitAccount) {
                Text(mode == .login ? "登录" : "创建账号")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        LoginCardPalette.green,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(LoginPillPressStyle())
            .disabled(busy)
            .opacity(busy ? 0.72 : 1)
            .padding(.top, 14)
            .accessibilityLabel(mode == .login ? "登录" : "创建账号")

            accountLinks
                .padding(.top, 10)
                .disabled(busy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .preferredColorScheme(.dark)
        .background(LoginCardPalette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white, lineWidth: 4)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
    }

    private var providerIcons: some View {
        HStack(spacing: 28) {
            providerIconButton("本机手机号登录", fill: LoginCardPalette.green, action: openPhone) {
                CarrierPhoneMark(tint: .white)
                    .scaleEffect(1.35)
            }
            providerIconButton("微信登录", fill: LoginCardPalette.button, action: signInWeChat) {
                WeChatMark()
                    .scaleEffect(1.2)
            }
            providerIconButton("Google 登录", fill: LoginCardPalette.button, action: signInGoogle) {
                GoogleMark()
                    .scaleEffect(1.4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func providerIconButton<Icon: View>(
        _ label: String,
        fill: Color,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 50, height: 50)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(LoginPillPressStyle())
        .accessibilityLabel(label)
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 1)
            Text("or")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.55))
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("or")
    }

    private var accountFields: some View {
        VStack(spacing: 10) {
            cardField(
                "邮箱",
                text: $email,
                icon: "envelope",
                field: .email,
                contentType: .emailAddress,
                keyboard: .emailAddress,
                submit: { focusedField = mode == .login ? .password : .displayName }
            )
            if mode == .register {
                cardField(
                    "显示名称",
                    text: $displayName,
                    icon: "person",
                    field: .displayName,
                    contentType: .name,
                    submit: { focusedField = .password }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            cardField(
                "密码",
                text: $password,
                icon: "lock",
                field: .password,
                secure: true,
                contentType: mode == .login ? .password : .newPassword,
                submit: { focusedField = mode == .login ? nil : .confirmPassword }
            )
            if mode == .register {
                cardField(
                    "确认密码",
                    text: $confirmPassword,
                    icon: "lock",
                    field: .confirmPassword,
                    secure: true,
                    contentType: .newPassword,
                    submit: { focusedField = nil }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func cardField(
        _ placeholder: String,
        text: Binding<String>,
        icon: String,
        field: LoginCardField,
        secure: Bool = false,
        contentType: UITextContentType?,
        keyboard: UIKeyboardType = .default,
        submit: @escaping () -> Void
    ) -> some View {
        let prompt = Text(placeholder).foregroundStyle(LoginCardPalette.caption)
        return HStack(spacing: 8) {
            Group {
                if secure {
                    SecureField("", text: editing(text), prompt: prompt)
                } else {
                    TextField("", text: editing(text), prompt: prompt)
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .focused($focusedField, equals: field)
            .foregroundStyle(.white)
            .tint(.white)
            .submitLabel(isLastField(field) ? .done : .next)
            .onSubmit(submit)

            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LoginCardPalette.caption)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(LoginCardPalette.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var accountLinks: some View {
        HStack(spacing: 8) {
            if mode == .login {
                Button(action: forgotPassword) {
                    Text("忘记密码？")
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(LoginCardPalette.caption)
                .accessibilityLabel("忘记密码")
            }
            Spacer(minLength: 8)
            Button(action: switchMode) {
                Text(mode == .login ? "注册账号" : "返回登录")
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.white)
        }
        .font(.system(size: 13, weight: .medium))
        .buttonStyle(.plain)
    }

    private func forgotPassword() {
        focusedField = nil
        notice = .hint("暂不支持在线重置密码")
    }

    /// Typing clears a notice. Direct state writes (mode switch, fake register) do not.
    private func editing(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { updated in
                if text.wrappedValue != updated {
                    notice = nil
                }
                text.wrappedValue = updated
            }
        )
    }

    private func isLastField(_ field: LoginCardField) -> Bool {
        switch mode {
        case .login:
            return field == .password
        case .register:
            return field == .confirmPassword
        }
    }

    private func noticeColor(_ notice: LoginCardNotice) -> Color {
        switch notice {
        case .failure:
            return LoginCardPalette.failure
        case .hint:
            return Color.white.opacity(0.92)
        case .success:
            return LoginCardPalette.green
        }
    }

    private func openPhone() {
        focusedField = nil
        notice = nil
        path.append(AuthRoute.phone)
    }

    private func switchMode() {
        focusedField = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            mode = mode == .login ? .register : .login
            password = ""
            confirmPassword = ""
            displayName = ""
            notice = nil
        }
    }

    /// Local checks only. Email and password accounts are not wired to a service yet.
    private func submitAccount() {
        focusedField = nil
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else {
            notice = .failure("请输入邮箱")
            return
        }
        guard password.count >= 8 else {
            notice = .failure("密码至少 8 位")
            return
        }
        if mode == .register {
            guard !normalizedName.isEmpty else {
                notice = .failure("请输入显示名称")
                return
            }
            guard password == confirmPassword else {
                notice = .failure("两次输入的密码不一致")
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                mode = .login
                password = ""
                confirmPassword = ""
                displayName = ""
                notice = .success("注册成功，请登录")
            }
            return
        }
        notice = .hint("帐号密码登录即将开通")
    }

    private var loginNote: String {
        if SkyAuthConfig.usesLocalDirectory {
            return "手机号使用本机演示验证码 \(IdentityDemoCode.token)，不会发送短信。微信和 Google 使用本机占位身份，还没有接上微信或 Google 的登录服务。邮箱登录即将开通。"
        }
        return "手机号会发送短信验证码。微信和 Google 会打开授权页，由 \(SkyAuthConfig.hostLabel) 核对身份。短信或开放平台密钥还没配好时，登录会提示还没有配置。邮箱登录即将开通。"
    }

    private func signInWeChat() {
        guard !busy else { return }
        focusedField = nil
        notice = nil
        busy = true
        Task {
            defer { busy = false }
            await finish { try await app.signInWeChat() }
        }
    }

    private func signInGoogle() {
        guard !busy else { return }
        focusedField = nil
        notice = nil
        busy = true
        Task {
            defer { busy = false }
            await finish { try await app.signInGoogle() }
        }
    }

    private func finish(_ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            notice = nil
        } catch let failure as AuthFailure {
            notice = .failure(failure.message)
        } catch {
            notice = .failure("登录没有完成")
        }
    }
}

struct PhoneVerifyView: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var preparedPhone: String?
    @State private var codeHint: String?
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        ZStack {
            LoginSkyBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("验证手机号")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(LoginColor.sky)
                    Text(SkyAuthConfig.usesLocalDirectory
                        ? "输入本机号码。下一步只在这台手机上显示演示验证码，不会发短信。"
                        : "输入手机号。验证码会发到这个号码。")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(LoginColor.footer)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    loginField("手机号", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .padding(.top, 22)
                        .onChange(of: phone) { _, _ in
                            preparedPhone = nil
                            codeHint = nil
                            code = ""
                        }
                    if preparedPhone == nil {
                        LoginPrimaryButton(busy ? "发送中" : "获取验证码", action: requestCode)
                            .padding(.top, 18)
                    } else {
                        if let codeHint {
                            Text(SkyAuthConfig.usesLocalDirectory
                                ? "本地演示。验证码不会发到手机，也没有位数或有效期。请原样输入下面的演示验证码。"
                                : "服务器开了演示模式。验证码不会发到手机。请原样输入下面的演示验证码。")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(LoginColor.footer)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 18)
                            Text(codeHint)
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundStyle(LoginColor.sky)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 10)
                        } else {
                            Text("验证码已发送，5 分钟内有效。")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(LoginColor.footer)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 18)
                        }
                        loginField("验证码", text: $code, capitalization: .characters)
                            .textContentType(.oneTimeCode)
                            .padding(.top, 12)
                        LoginPrimaryButton(busy ? "登录中" : "登录", action: submit)
                            .padding(.top, 18)
                    }
                    if !error.isEmpty {
                        LoginErrorText(message: error)
                            .padding(.top, 14)
                    }
                }
                .frame(maxWidth: 312)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 17, weight: .regular))
                    }
                    .foregroundStyle(LoginColor.ink.opacity(0.86))
                }
                .buttonStyle(.plain)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestCode() {
        guard !busy else { return }
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preparedPhone = nil
            codeHint = nil
            error = "请填写手机号"
            return
        }
        busy = true
        error = ""
        Task {
            defer { busy = false }
            do {
                let ticket = try await app.requestPhoneCode(phone: trimmed)
                preparedPhone = ticket.phone
                codeHint = ticket.demoCode
                error = ""
            } catch let failure as AuthFailure {
                preparedPhone = nil
                codeHint = nil
                error = failure.message
            } catch {
                preparedPhone = nil
                codeHint = nil
                self.error = "登录没有完成"
            }
        }
    }

    private func submit() {
        guard !busy else { return }
        guard let preparedPhone else {
            error = "请先获取验证码"
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await app.signInPhone(phone: preparedPhone, demoCode: code)
                error = ""
            } catch let failure as AuthFailure {
                error = failure.message
            } catch {
                self.error = "登录没有完成"
            }
        }
    }
}

// MARK: - Sky background

private enum LoginColor {
    static let sky = Color(red: 22 / 255, green: 72 / 255, blue: 184 / 255)
    static let ink = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let footer = Color(red: 78 / 255, green: 93 / 255, blue: 110 / 255)
}

private enum LoginCardPalette {
    static let card = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let button = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    static let field = Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255)
    static let green = Color(red: 30 / 255, green: 158 / 255, blue: 74 / 255)
    static let caption = Color.white.opacity(0.55)
    static let failure = Color(red: 1, green: 0.45, blue: 0.42)
}

private enum LoginWash {
    case deep
    case light
    case pale

    var stops: [Color] {
        switch self {
        case .deep:
            return [
                Color(red: 56 / 255, green: 132 / 255, blue: 214 / 255),
                Color(red: 126 / 255, green: 186 / 255, blue: 238 / 255),
                Color(red: 198 / 255, green: 228 / 255, blue: 250 / 255),
                Color(red: 232 / 255, green: 245 / 255, blue: 253 / 255),
            ]
        case .light:
            return [
                Color(red: 96 / 255, green: 170 / 255, blue: 236 / 255),
                Color(red: 168 / 255, green: 214 / 255, blue: 248 / 255),
                Color(red: 214 / 255, green: 236 / 255, blue: 252 / 255),
                Color(red: 242 / 255, green: 249 / 255, blue: 254 / 255),
            ]
        case .pale:
            return [
                Color(red: 140 / 255, green: 198 / 255, blue: 244 / 255),
                Color(red: 196 / 255, green: 226 / 255, blue: 250 / 255),
                Color(red: 228 / 255, green: 242 / 255, blue: 253 / 255),
                Color(red: 247 / 255, green: 251 / 255, blue: 255 / 255),
            ]
        }
    }
}

/// Full-screen sky. Three blue gradients cross-fade; soft washes stay in front.
/// `CanvasBackground` only breathes a pale ice tint on white, so the login screen keeps its own sky.
private struct LoginSkyBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reduceMotion {
                washStack(phase: 1.0 / 3.0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let phase = time.truncatingRemainder(dividingBy: 9) / 9
                    washStack(phase: phase)
                }
            }
            LoginSkyWashes()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func washStack(phase: Double) -> some View {
        let weight = breathWeights(phase)
        return ZStack {
            gradient(.deep).opacity(weight.deep)
            gradient(.light).opacity(weight.light)
            gradient(.pale).opacity(weight.pale)
        }
    }

    private func gradient(_ wash: LoginWash) -> some View {
        LinearGradient(colors: wash.stops, startPoint: .top, endPoint: .bottom)
    }

    /// One turn visits deep, then light, then pale, then deep again.
    private func breathWeights(_ phase: Double) -> (deep: Double, light: Double, pale: Double) {
        let wrapped = phase - floor(phase)
        let scaled = wrapped * 3
        let index = Int(scaled) % 3
        let fraction = scaled - Double(Int(scaled))
        var weights = [0.0, 0.0, 0.0]
        weights[index] = 1 - fraction
        weights[(index + 1) % 3] = fraction
        return (weights[0], weights[1], weights[2])
    }
}

private struct LoginSkyWashes: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifted = false

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color(red: 36 / 255, green: 112 / 255, blue: 196 / 255).opacity(0.55))
                .frame(width: 640, height: 240)
                .blur(radius: 36)
                .offset(x: drifted ? -24 : 10, y: -300)
            Ellipse()
                .fill(Color(red: 92 / 255, green: 168 / 255, blue: 230 / 255).opacity(0.5))
                .frame(width: 520, height: 200)
                .blur(radius: 32)
                .offset(x: drifted ? 36 : -20, y: -150)
            Ellipse()
                .fill(Color.white.opacity(0.38))
                .frame(width: 460, height: 180)
                .blur(radius: 28)
                .offset(x: drifted ? -12 : 28, y: -20)
            Ellipse()
                .fill(Color(red: 186 / 255, green: 220 / 255, blue: 246 / 255).opacity(0.55))
                .frame(width: 680, height: 260)
                .blur(radius: 30)
                .offset(y: 220)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                drifted = true
            }
        }
    }
}

// MARK: - Controls

private struct LoginPrimaryButton: View {
    var title: String
    var action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(LoginColor.sky, in: Capsule())
        }
        .buttonStyle(LoginPillPressStyle())
    }
}

private struct LoginPillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.74 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LoginErrorText: View {
    var message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.62, green: 0.13, blue: 0.16))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

private func loginField(
    _ placeholder: String,
    text: Binding<String>,
    capitalization: TextInputAutocapitalization = .never
) -> some View {
    TextField(placeholder, text: text)
        .textInputAutocapitalization(capitalization)
        .autocorrectionDisabled()
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(LoginColor.ink)
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 0.8)
        }
}

private struct CarrierPhoneMark: View {
    var tint: Color = Color(red: 0.13, green: 0.68, blue: 0.42)

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            Image(systemName: "person.fill")
                .font(.system(size: 14, weight: .semibold))
            Image(systemName: "iphone")
                .font(.system(size: 10, weight: .medium))
                .offset(y: -1)
        }
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

private struct WeChatMark: View {
    private let green = Color(red: 0.07, green: 0.75, blue: 0.35)

    var body: some View {
        ZStack {
            bubble
                .scaleEffect(1)
                .offset(x: -3.5, y: 2.5)
            bubble
                .scaleEffect(0.72)
                .offset(x: 5, y: -4)
        }
        .frame(width: 22, height: 20)
        .accessibilityHidden(true)
    }

    private var bubble: some View {
        ZStack {
            Circle()
                .fill(green)
                .frame(width: 13, height: 13)
            HStack(spacing: 2.2) {
                Circle().fill(.white).frame(width: 2, height: 2)
                Circle().fill(.white).frame(width: 2, height: 2)
            }
            .offset(y: -0.4)
        }
    }
}

private struct GoogleMark: View {
    private let blue = Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255)
    private let red = Color(red: 234 / 255, green: 67 / 255, blue: 53 / 255)
    private let yellow = Color(red: 251 / 255, green: 188 / 255, blue: 5 / 255)
    private let green = Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255)

    var body: some View {
        ZStack {
            arc(red, from: 0.74, to: 1)
            arc(red, from: 0, to: 0.10)
            arc(blue, from: 0.10, to: 0.22)
            arc(green, from: 0.30, to: 0.55)
            arc(yellow, from: 0.55, to: 0.74)
            Capsule()
                .fill(blue)
                .frame(width: 8, height: 2.5)
                .offset(x: 3.2)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    private func arc(_ color: Color, from start: CGFloat, to end: CGFloat) -> some View {
        Circle()
            .trim(from: start, to: end)
            .stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .butt))
            .rotationEffect(.degrees(-90))
            .padding(1.2)
    }
}

#Preview {
    AuthFlow()
        .environmentObject(PhoneAppState())
}

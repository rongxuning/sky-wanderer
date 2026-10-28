import SwiftUI

/// Login routes. Register, forgot-password, and reset are not entry points.
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

struct LoginView: View {
    @EnvironmentObject private var app: PhoneAppState
    @Binding var path: NavigationPath
    @State private var error = ""
    @State private var showNote = false
    @State private var busy = false

    var body: some View {
        ZStack {
            LoginSkyBackground()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 24)
                titleBlock
                providerButtons
                    .padding(.top, 36)
                if !error.isEmpty {
                    LoginErrorText(message: error)
                        .padding(.top, 14)
                        .padding(.horizontal, 28)
                } else if !app.banner.isEmpty {
                    Text(app.banner)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoginColor.sky)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                        .padding(.horizontal, 28)
                }
                Spacer(minLength: 24)
                Text("登录即表示同意用户协议与隐私政策")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(LoginColor.footer)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
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

    private var providerButtons: some View {
        VStack(spacing: 12) {
            LoginProviderButton("本机手机号登录", action: openPhone) {
                CarrierPhoneMark()
            }
            LoginProviderButton("微信登录", action: signInWeChat) {
                WeChatMark()
            }
            LoginProviderButton("Google 登录", action: signInGoogle) {
                GoogleMark()
            }
        }
        .frame(maxWidth: 312)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
    }

    private func openPhone() {
        error = ""
        path.append(AuthRoute.phone)
    }

    private var loginNote: String {
        if SkyAuthConfig.usesLocalDirectory {
            return "手机号使用本机演示验证码 \(IdentityDemoCode.token)，不会发送短信。微信和 Google 使用本机占位身份，还没有接上微信或 Google 的登录服务。"
        }
        return "手机号会发送短信验证码。微信和 Google 会打开授权页，由 \(SkyAuthConfig.hostLabel) 核对身份。短信或开放平台密钥还没配好时，登录会提示还没有配置。"
    }

    private func signInWeChat() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            await finish { try await app.signInWeChat() }
        }
    }

    private func signInGoogle() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            await finish { try await app.signInGoogle() }
        }
    }

    private func finish(_ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            error = ""
        } catch let failure as AuthFailure {
            error = failure.message
        } catch {
            self.error = "登录没有完成"
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
    static let buttonText = Color(red: 28 / 255, green: 32 / 255, blue: 38 / 255)
    static let chevron = Color(red: 142 / 255, green: 152 / 255, blue: 164 / 255)
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

private struct LoginProviderButton<Icon: View>: View {
    var title: String
    var action: () -> Void
    var icon: Icon

    init(_ title: String, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                icon
                    .frame(width: 32, height: 24, alignment: .leading)
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LoginColor.buttonText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoginColor.chevron)
                    .frame(width: 18, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color.white.opacity(0.74))
                }
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.92), lineWidth: 0.8)
            }
            .shadow(color: Color(red: 0.25, green: 0.45, blue: 0.72).opacity(0.12), radius: 10, y: 5)
        }
        .buttonStyle(LoginPillPressStyle())
    }
}

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
    private let green = Color(red: 0.13, green: 0.68, blue: 0.42)

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            Image(systemName: "person.fill")
                .font(.system(size: 14, weight: .semibold))
            Image(systemName: "iphone")
                .font(.system(size: 10, weight: .medium))
                .offset(y: -1)
        }
        .foregroundStyle(green)
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

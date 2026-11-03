import SwiftUI

/// Pushed login routes. Email register and forgot-password stay on the login screen.
enum AuthRoute: Hashable {
    case phone
}

struct AuthFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LoginView(path: $path, onClose: { dismiss() })
                .navigationDestination(for: AuthRoute.self) { route in
                    switch route {
                    case .phone:
                        PhoneVerifyView()
                    }
                }
        }
        .background(SkyTheme.Color.background.ignoresSafeArea())
        .presentationBackground(SkyTheme.Color.background)
        .tint(SkyTheme.Color.primary)
        .preferredColorScheme(.light)
    }
}

private enum LoginMode {
    case login
    case register
}

private enum LoginField: Hashable {
    case email
    case displayName
    case password
    case confirmPassword
}

private enum LoginNotice: Equatable {
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
    var onClose: () -> Void = {}
    @State private var mode: LoginMode = .login
    @State private var email = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var notice: LoginNotice?
    @State private var showNote = false
    @State private var busy = false
    @FocusState private var focusedField: LoginField?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 0) {
                    titleBlock
                        .padding(.top, SkyTheme.Spacing.section)
                    providerButtons
                        .padding(.top, SkyTheme.Spacing.section)
                        .disabled(busy)
                        .opacity(busy ? 0.72 : 1)
                    credentialColumn
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, SkyTheme.Spacing.section)
                    agreement
                        .padding(.top, SkyTheme.Spacing.section)
                        .padding(.bottom, SkyTheme.Spacing.section)
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .background(SkyTheme.Color.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .alert("登录说明", isPresented: $showNote) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loginNote)
        }
    }

    private var topBar: some View {
        HStack {
            barButton(systemName: "xmark", label: "关闭", action: onClose)
            Spacer()
            barButton(systemName: "info.circle", label: "登录说明") {
                showNote = true
            }
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
    }

    private func barButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.ink)
                .frame(width: SkyTheme.Spacing.touchMin, height: SkyTheme.Spacing.touchMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var titleBlock: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sky")
                    .font(SkyTheme.Font.largeTitle)
                    .foregroundStyle(SkyTheme.Color.primary)
                Text("Wanderer")
                    .font(SkyTheme.Font.title)
                    .foregroundStyle(SkyTheme.Color.ink)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    private var agreement: some View {
        Text("登录即表示同意用户协议与隐私政策")
            .font(SkyTheme.Font.caption)
            .foregroundStyle(SkyTheme.Color.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// Phone, WeChat, and Google as equal circles. Titles stay off the control.
    private var providerButtons: some View {
        HStack(spacing: SkyTheme.Spacing.controlGap) {
            providerButton("本机手机号登录", action: openPhone) {
                CarrierPhoneMark(tint: SkyTheme.Color.primary)
            }
            providerButton("微信登录", action: signInWeChat) {
                WeChatMark()
            }
            providerButton("Google 登录", action: signInGoogle) {
                GoogleMark()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Visible title stays off the control. `label` is the VoiceOver name.
    /// The control is a fixed square so the outline stays a circle instead of a stretched capsule.
    private func providerButton<Icon: View>(
        _ label: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 22, height: 22)
        }
        .buttonStyle(SkyCircleOutlineButtonStyle())
        .fixedSize()
        .accessibilityLabel(label)
    }

    /// Divider, fields, primary button, and account links. 60% of the login content width.
    private var credentialColumn: some View {
        CenteredFractionLayout(fraction: 0.6) {
            VStack(spacing: 0) {
                orDivider
                accountFields
                    .padding(.top, SkyTheme.Spacing.section)
                    .animation(.easeInOut(duration: 0.2), value: mode)
                if let notice {
                    Text(notice.text)
                        .font(SkyTheme.Font.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(noticeColor(notice))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, SkyTheme.Spacing.related)
                        .transition(.opacity)
                } else if !app.banner.isEmpty {
                    Text(app.banner)
                        .font(SkyTheme.Font.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, SkyTheme.Spacing.related)
                }
                LoginPrimaryButton(mode == .login ? "登录" : "创建账号", action: submitAccount)
                    .disabled(busy)
                    .opacity(busy ? 0.72 : 1)
                    .padding(.top, SkyTheme.Spacing.screenInset)
                accountLinks
                    .padding(.top, SkyTheme.Spacing.related)
                    .disabled(busy)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(SkyTheme.Color.separator)
                .frame(height: 1)
            Text("或")
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
            Rectangle()
                .fill(SkyTheme.Color.separator)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("或")
    }

    private var accountFields: some View {
        VStack(spacing: SkyTheme.Spacing.related) {
            accountField(
                "邮箱",
                text: $email,
                icon: "envelope",
                field: .email,
                contentType: .emailAddress,
                keyboard: .emailAddress,
                submit: { focusedField = mode == .login ? .password : .displayName }
            )
            if mode == .register {
                accountField(
                    "显示名称",
                    text: $displayName,
                    icon: "person",
                    field: .displayName,
                    contentType: .name,
                    submit: { focusedField = .password }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            accountField(
                "密码",
                text: $password,
                icon: "lock",
                field: .password,
                secure: true,
                contentType: mode == .login ? .password : .newPassword,
                submit: { focusedField = mode == .login ? nil : .confirmPassword }
            )
            if mode == .register {
                accountField(
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

    private func accountField(
        _ placeholder: String,
        text: Binding<String>,
        icon: String,
        field: LoginField,
        secure: Bool = false,
        contentType: UITextContentType?,
        keyboard: UIKeyboardType = .default,
        submit: @escaping () -> Void
    ) -> some View {
        let prompt = Text(placeholder).foregroundStyle(SkyTheme.Color.secondary)
        return HStack(spacing: SkyTheme.Spacing.related) {
            Image(systemName: icon)
                .font(SkyTheme.Font.body)
                .foregroundStyle(SkyTheme.Color.secondary)
                .accessibilityHidden(true)
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
            .font(SkyTheme.Font.body)
            .foregroundStyle(SkyTheme.Color.ink)
            .tint(SkyTheme.Color.primary)
            .submitLabel(isLastField(field) ? .done : .next)
            .onSubmit(submit)
        }
        .skyInputChrome()
    }

    private var accountLinks: some View {
        HStack(spacing: SkyTheme.Spacing.related) {
            if mode == .login {
                Button(action: forgotPassword) {
                    Text("忘记密码？")
                        .frame(minHeight: SkyTheme.Spacing.touchMin)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("忘记密码")
                .transition(.opacity)
            }
            Spacer(minLength: SkyTheme.Spacing.related)
            Button(action: switchMode) {
                Text(mode == .login ? "注册账号" : "返回登录")
                    .frame(minHeight: SkyTheme.Spacing.touchMin)
                    .contentShape(Rectangle())
            }
        }
        .font(SkyTheme.Font.callout)
        .buttonStyle(SkyTextButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private func forgotPassword() {
        focusedField = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            notice = .hint("暂不支持在线重置密码")
        }
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

    private func isLastField(_ field: LoginField) -> Bool {
        switch mode {
        case .login:
            return field == .password
        case .register:
            return field == .confirmPassword
        }
    }

    private func noticeColor(_ notice: LoginNotice) -> Color {
        switch notice {
        case .failure:
            return SkyTheme.Color.danger
        case .hint:
            return SkyTheme.Color.secondary
        case .success:
            return SkyTheme.Color.success
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("验证手机号")
                    .font(SkyTheme.Font.title)
                    .foregroundStyle(SkyTheme.Color.ink)
                Text(SkyAuthConfig.usesLocalDirectory
                    ? "输入本机号码。下一步只在这台手机上显示演示验证码，不会发短信。"
                    : "输入手机号。验证码会发到这个号码。")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SkyTheme.Spacing.related)
                loginField(
                    "手机号",
                    text: $phone,
                    keyboard: .phonePad,
                    contentType: .telephoneNumber
                )
                    .padding(.top, SkyTheme.Spacing.section)
                    .onChange(of: phone) { _, _ in
                        preparedPhone = nil
                        codeHint = nil
                        code = ""
                    }
                if preparedPhone == nil {
                    LoginPrimaryButton(busy ? "发送中" : "获取验证码", action: requestCode)
                        .disabled(busy)
                        .opacity(busy ? 0.72 : 1)
                        .padding(.top, SkyTheme.Spacing.screenInset)
                } else {
                    if let codeHint {
                        Text(SkyAuthConfig.usesLocalDirectory
                            ? "本地演示。验证码不会发到手机，也没有位数或有效期。请原样输入下面的演示验证码。"
                            : "服务器开了演示模式。验证码不会发到手机。请原样输入下面的演示验证码。")
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(SkyTheme.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, SkyTheme.Spacing.section)
                        Text(codeHint)
                            .font(SkyTheme.Font.largeTitle)
                            .foregroundStyle(SkyTheme.Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, SkyTheme.Spacing.related)
                    } else {
                        Text("验证码已发送，5 分钟内有效。")
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(SkyTheme.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, SkyTheme.Spacing.section)
                    }
                    loginField(
                        "验证码",
                        text: $code,
                        capitalization: .characters,
                        contentType: .oneTimeCode
                    )
                        .padding(.top, SkyTheme.Spacing.screenInset)
                    LoginPrimaryButton(busy ? "登录中" : "登录", action: submit)
                        .disabled(busy)
                        .opacity(busy ? 0.72 : 1)
                        .padding(.top, SkyTheme.Spacing.screenInset)
                }
                if !error.isEmpty {
                    LoginErrorText(message: error)
                        .padding(.top, SkyTheme.Spacing.screenInset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, SkyTheme.Spacing.screenInset)
            .padding(.bottom, SkyTheme.Spacing.section)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(SkyTheme.Color.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(SkyTheme.Font.headline)
                        Text("返回")
                            .font(SkyTheme.Font.body)
                    }
                    .foregroundStyle(SkyTheme.Color.primary)
                    .frame(minHeight: SkyTheme.Spacing.touchMin)
                }
                .buttonStyle(.plain)
            }
        }
        .toolbarBackground(SkyTheme.Color.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.onPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.vertical, SkyTheme.Spacing.related)
                .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
        }
        .buttonStyle(SkyPrimaryButtonStyle())
    }
}

private struct SkyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? SkyTheme.Color.primaryPressed : SkyTheme.Color.primary,
                in: Capsule()
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Sizes its child to `fraction` of the proposed width so the parent can center that column.
private struct CenteredFractionLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let fullWidth = proposal.width else {
            return child.sizeThatFits(.unspecified)
        }
        let childWidth = fullWidth * fraction
        let size = child.sizeThatFits(ProposedViewSize(width: childWidth, height: nil))
        return CGSize(width: childWidth, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let child = subviews.first else { return }
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let size = child.sizeThatFits(childProposal)
        let origin = CGPoint(
            x: bounds.minX + max(0, (bounds.width - size.width) / 2),
            y: bounds.minY
        )
        child.place(at: origin, proposal: childProposal)
    }
}

/// Compact circular outline. Diameter is the 44pt touch target; the glyph stays centered inside.
private struct SkyCircleOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let stroke = configuration.isPressed ? SkyTheme.Color.primaryPressed : SkyTheme.Color.primary
        configuration.label
            .frame(width: SkyTheme.Spacing.touchMin, height: SkyTheme.Spacing.touchMin)
            .background(Circle().strokeBorder(stroke, lineWidth: 1.5))
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SkyTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? SkyTheme.Color.primaryPressed : SkyTheme.Color.primary)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LoginErrorText: View {
    var message: String

    var body: some View {
        Text(message)
            .font(SkyTheme.Font.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(SkyTheme.Color.danger)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

private extension View {
    func skyInputChrome() -> some View {
        padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.vertical, SkyTheme.Spacing.related)
            .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
            .background(
                SkyTheme.Color.grouped,
                in: RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous)
            )
    }
}

private func loginField(
    _ placeholder: String,
    text: Binding<String>,
    capitalization: TextInputAutocapitalization = .never,
    keyboard: UIKeyboardType = .default,
    contentType: UITextContentType? = nil
) -> some View {
    TextField(
        "",
        text: text,
        prompt: Text(placeholder).foregroundStyle(SkyTheme.Color.secondary)
    )
    .textContentType(contentType)
    .keyboardType(keyboard)
    .textInputAutocapitalization(capitalization)
    .autocorrectionDisabled()
    .font(SkyTheme.Font.body)
    .foregroundStyle(SkyTheme.Color.ink)
    .tint(SkyTheme.Color.primary)
    .skyInputChrome()
}

private struct CarrierPhoneMark: View {
    var tint: Color = SkyTheme.Color.primary

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

/// WeChat green stays on the glyph only. Button chrome uses `SkyTheme`.
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

/// Google brand colors stay on the glyph only. Button chrome uses `SkyTheme`.
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

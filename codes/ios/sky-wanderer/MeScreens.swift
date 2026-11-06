import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct PickedPhoto: Transferable {
    var data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedPhoto(data: data)
        }
    }
}

private enum MeNotice: Equatable {
    case failure(String)
    case success(String)

    var text: String {
        switch self {
        case .failure(let text), .success(let text):
            return text
        }
    }

    var color: Color {
        switch self {
        case .failure: return SkyTheme.Color.danger
        case .success: return SkyTheme.Color.success
        }
    }
}

struct MePushScreen<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SkyTheme.Color.grouped.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .navigationBarHidden(false)
            .toolbarBackground(SkyTheme.Color.grouped, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(SkyTheme.Color.primary)
    }
}

struct MeAvatarScreen: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var pickerItem: PhotosPickerItem?
    @State private var busy = false
    @State private var notice: MeNotice?

    var body: some View {
        MePushScreen(title: "头像") {
            ScrollView {
                VStack(spacing: SkyTheme.Spacing.section) {
                    AccountAvatarFace(name: displayName, image: app.accountAvatar, diameter: 120)
                        .padding(.top, SkyTheme.Spacing.section)
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text(app.account?.avatarFilename == nil ? "从相册选择" : "更换头像")
                            .font(SkyTheme.Font.headline)
                            .foregroundStyle(SkyTheme.Color.onPrimary)
                            .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
                            .background(SkyTheme.Color.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .opacity(busy ? 0.72 : 1)
                    .accessibilityLabel("从相册选择头像")
                    if app.account?.avatarFilename != nil {
                        Button("恢复文字头像", action: clear)
                            .font(SkyTheme.Font.headline)
                            .foregroundStyle(SkyTheme.Color.primary)
                            .frame(minHeight: SkyTheme.Spacing.touchMin)
                            .disabled(busy)
                    }
                    Text(MeProfileCopy.avatarNote(usesLocalDirectory: SkyAuthConfig.usesLocalDirectory))
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice {
                        Text(notice.text)
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(notice.color)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.bottom, SkyTheme.Spacing.section)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await save(item) }
        }
    }

    private var displayName: String {
        let name = app.account?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "我" : name
    }

    private func save(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false }
        do {
            guard let photo = try await item.loadTransferable(type: PickedPhoto.self) else {
                notice = .failure("没有读到这张照片")
                return
            }
            try app.setAvatarImage(photo.data)
            notice = .success("已保存在这台手机")
        } catch let error as AuthFailure {
            notice = .failure(error.message)
        } catch {
            notice = .failure("这张照片没法保存")
        }
    }

    private func clear() {
        app.clearAvatar()
        notice = .success("已改回文字头像")
    }
}

struct MeUsernameScreen: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loaded = false
    @State private var notice: MeNotice?
    @FocusState private var focused: Bool

    var body: some View {
        MePushScreen(title: "用户名") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField(
                        "",
                        text: $name,
                        prompt: Text("用户名").foregroundStyle(SkyTheme.Color.secondary)
                    )
                    .focused($focused)
                    .textContentType(.nickname)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .font(SkyTheme.Font.body)
                    .foregroundStyle(SkyTheme.Color.ink)
                    .tint(SkyTheme.Color.primary)
                    .meInputChrome()
                    .padding(.top, SkyTheme.Spacing.section)
                    .onChange(of: name) { _, _ in notice = nil }
                    Text(MeProfileCopy.displayNameNote(usesLocalDirectory: SkyAuthConfig.usesLocalDirectory))
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SkyTheme.Spacing.related)
                    if let notice {
                        Text(notice.text)
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(notice.color)
                            .padding(.top, SkyTheme.Spacing.related)
                    }
                    MeCapsuleButton(title: "保存", action: save)
                        .padding(.top, SkyTheme.Spacing.section)
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.bottom, SkyTheme.Spacing.section)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = app.account?.name ?? ""
        }
    }

    private func save() {
        focused = false
        do {
            try app.updateDisplayName(name)
            dismiss()
        } catch let error as AuthFailure {
            notice = .failure(error.message)
        } catch {
            notice = .failure("用户名没有保存")
        }
    }
}

struct MePasswordScreen: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var notice: MeNotice?
    @FocusState private var field: Field?

    private enum Field: Hashable {
        case current
        case newPassword
        case confirm
    }

    var body: some View {
        MePushScreen(title: "修改密码") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(mode.screenNote)
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SkyTheme.Spacing.section)
                    if mode == .localChange {
                        secure("当前密码", text: $current, field: .current, content: .password)
                            .padding(.top, SkyTheme.Spacing.screenInset)
                    }
                    secure("新密码", text: $newPassword, field: .newPassword, content: .newPassword)
                        .padding(.top, SkyTheme.Spacing.screenInset)
                    secure("确认新密码", text: $confirm, field: .confirm, content: .newPassword)
                        .padding(.top, SkyTheme.Spacing.related)
                    if let notice {
                        Text(notice.text)
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(notice.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, SkyTheme.Spacing.related)
                    }
                    MeCapsuleButton(title: mode.saveTitle, action: save)
                        .padding(.top, SkyTheme.Spacing.section)
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.bottom, SkyTheme.Spacing.section)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
    }

    private var mode: MePasswordMode {
        MePasswordMode.resolve(
            usesLocalDirectory: SkyAuthConfig.usesLocalDirectory,
            hasPassword: !(app.account?.passwordHash.isEmpty ?? true)
        )
    }

    private func secure(
        _ placeholder: String,
        text: Binding<String>,
        field: Field,
        content: UITextContentType
    ) -> some View {
        SecureField(
            "",
            text: text,
            prompt: Text(placeholder).foregroundStyle(SkyTheme.Color.secondary)
        )
        .focused($field, equals: field)
        .textContentType(content)
        .submitLabel(field == .confirm ? .done : .next)
        .onSubmit {
            switch field {
            case .current: self.field = .newPassword
            case .newPassword: self.field = .confirm
            case .confirm: save()
            }
        }
        .font(SkyTheme.Font.body)
        .foregroundStyle(SkyTheme.Color.ink)
        .tint(SkyTheme.Color.primary)
        .meInputChrome()
    }

    private func save() {
        field = nil
        if mode == .remoteUnavailable {
            notice = .failure(mode.screenNote)
            return
        }
        do {
            try app.changePassword(current: current, newPassword: newPassword, confirm: confirm)
            dismiss()
        } catch let error as AuthFailure {
            notice = .failure(error.message)
        } catch {
            notice = .failure("密码没有保存")
        }
    }
}

struct MeHealthScreen: View {
    @EnvironmentObject private var app: PhoneAppState
    @StateObject private var health = MeHealth()

    var body: some View {
        MePushScreen(title: "健康") {
            ScrollView {
                VStack(alignment: .leading, spacing: SkyTheme.Spacing.section) {
                    if !health.note.isEmpty {
                        Text(health.note)
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(SkyTheme.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: SkyTheme.Spacing.related) {
                        stat("心率", value: "\(Int(health.heartRate.rounded()))", unit: "次/分", sample: health.heartIsSample)
                        stat("睡眠", value: String(format: "%.1f", health.sleepHours), unit: "小时", sample: health.sleepIsSample)
                        stat("步数", value: "\(health.steps)", unit: "步", sample: health.stepsAreSample)
                    }
                    .padding(SkyTheme.Spacing.cardPadding)
                    .meCard()
                    VStack(alignment: .leading, spacing: SkyTheme.Spacing.related) {
                        Text("训练估计，不是医疗建议")
                            .font(SkyTheme.Font.headline)
                            .foregroundStyle(SkyTheme.Color.ink)
                        estimate("体能储备", "\(app.estimate.reserve)")
                        estimate("训练负荷", "\(app.estimate.recentLoad)")
                        estimate("休息时间建议", app.estimate.restHint)
                        Text("近 7 日负荷来自每次的训练时间和平均心率。")
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(SkyTheme.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(SkyTheme.Spacing.cardPadding)
                    .meCard()
                    Button("重新读取", action: reload)
                        .font(SkyTheme.Font.headline)
                        .foregroundStyle(SkyTheme.Color.primary)
                        .frame(minHeight: SkyTheme.Spacing.touchMin)
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.top, SkyTheme.Spacing.screenInset)
                .padding(.bottom, SkyTheme.Spacing.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .task { await health.refresh() }
    }

    private func reload() {
        Task { await health.refresh() }
    }

    private func stat(_ title: String, value: String, unit: String, sample: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
            Text(value)
                .font(SkyTheme.Font.title2)
                .foregroundStyle(SkyTheme.Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
            Text(sample ? "示例" : " ")
                .font(SkyTheme.Font.caption)
                .foregroundStyle(sample ? SkyTheme.Color.primary : Color.clear)
                .accessibilityHidden(!sample)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value) \(unit)\(sample ? "，示例" : "")")
    }

    private func estimate(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SkyTheme.Spacing.related) {
            Text(title)
                .font(SkyTheme.Font.subheadline)
                .foregroundStyle(SkyTheme.Color.ink)
            Spacer(minLength: SkyTheme.Spacing.related)
            Text(value)
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct MeTrainingAuthorizationScreen: View {
    @State private var status = MeTrainingShareState.notDetermined
    @State private var busy = false
    @State private var notice: MeNotice?

    var body: some View {
        MePushScreen(title: "训练授权") {
            ScrollView {
                VStack(alignment: .leading, spacing: SkyTheme.Spacing.screenInset) {
                    Text(status.title)
                        .font(SkyTheme.Font.title2)
                        .foregroundStyle(SkyTheme.Color.ink)
                        .padding(.top, SkyTheme.Spacing.section)
                    Text(status.detail)
                        .font(SkyTheme.Font.subheadline)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MeCapsuleButton(title: busy ? "请求中" : "请求授权", action: request)
                        .disabled(busy || status == .unavailable)
                        .opacity(busy || status == .unavailable ? 0.72 : 1)
                    if let notice {
                        Text(notice.text)
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(notice.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.bottom, SkyTheme.Spacing.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .task { status = AppleHealth.workoutShareAuthorization() }
    }

    private func request() {
        guard !busy else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                try await AppleHealth.authorize()
                notice = .success("已向系统请求授权。")
            } catch {
                notice = .failure("这台设备没有健康数据，授权请求没有发出。")
            }
            status = AppleHealth.workoutShareAuthorization()
        }
    }
}

struct MeNotificationScreen: View {
    var body: some View {
        MePushScreen(title: "通知设置") {
            List {
                Section {
                    ForEach(MeNotificationPreference.allCases) { kind in
                        Toggle(isOn: binding(kind)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title)
                                    .font(SkyTheme.Font.headline)
                                    .foregroundStyle(SkyTheme.Color.ink)
                                Text(kind.detail)
                                    .font(SkyTheme.Font.footnote)
                                    .foregroundStyle(SkyTheme.Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                        }
                        .tint(SkyTheme.Color.primary)
                        .meRow()
                    }
                } footer: {
                    Text(MeProfileCopy.notificationFootnote)
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func binding(_ kind: MeNotificationPreference) -> Binding<Bool> {
        Binding(
            get: { kind.isOn() },
            set: { kind.setOn($0) }
        )
    }
}

struct MeSDKListScreen: View {
    var body: some View {
        MePushScreen(title: "第三方 SDK 清单") {
            List {
                Section {
                    Text(MeSDKCatalog.intro)
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                        .meRow()
                }
                Section {
                    ForEach(MeSDKCatalog.services) { entry in
                        sdkRow(entry, badge: entry.shipsBinary ? nil : "未嵌入")
                    }
                } header: {
                    Text("外部服务")
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .textCase(nil)
                }
                Section {
                    ForEach(MeSDKCatalog.appleFrameworks) { entry in
                        sdkRow(entry, badge: "系统")
                    }
                } header: {
                    Text("Apple 系统框架")
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func sdkRow(_ entry: MeSDKEntry, badge: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: SkyTheme.Spacing.related) {
                Text(entry.name)
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.ink)
                Spacer(minLength: SkyTheme.Spacing.related)
                if let badge {
                    Text(badge)
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
            }
            Text(entry.provider)
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
            Text(entry.purpose)
                .font(SkyTheme.Font.subheadline)
                .foregroundStyle(SkyTheme.Color.ink)
            Text(entry.data)
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .meRow()
    }
}

private extension View {
    func meCard() -> some View {
        background(SkyTheme.Color.card, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
                    .stroke(SkyTheme.Color.cardBorder, lineWidth: 1)
            }
    }
}

import SwiftUI
import UIKit

/// Signed-in profile. The home avatar pushes this when a session exists.
struct MeView: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var confirmLogout = false

    var body: some View {
        Group {
            if app.isLoggedIn {
                profileList
            } else {
                loggedOut
            }
        }
        .background(SkyTheme.Color.grouped.ignoresSafeArea())
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarHidden(false)
        .toolbarBackground(SkyTheme.Color.grouped, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(SkyTheme.Color.primary)
        .sheet(isPresented: $confirmLogout) {
            MeLogoutSheet {
                app.logout()
            }
            .presentationDetents([.height(340), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(SkyTheme.Color.background)
        }
    }

    private var profileList: some View {
        List {
            Section {
                NavigationLink(value: MeRoute.avatar) {
                    profileHeader
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityLabel("更换头像，\(displayName)")
                .meRow()

                meLink("用户名", value: displayName, route: .username)
                meLink("修改密码", value: passwordMode.rowValue, route: .password)
            }

            Section {
                meLink("健康", value: nil, route: .health)
                meLink("训练授权", value: nil, route: .trainingAuthorization)
            } header: {
                meHeader("健康与训练")
            }

            Section {
                meLink("通知设置", value: nil, route: .notifications)
                meLink("第三方 SDK 清单", value: nil, route: .sdkList)
            } header: {
                meHeader("隐私")
            }

            Section {
                Button {
                    confirmLogout = true
                } label: {
                    Text("退出登录")
                        .font(SkyTheme.Font.headline)
                        .foregroundStyle(SkyTheme.Color.danger)
                        .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.listRowMin)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("退出登录")
                .meRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var profileHeader: some View {
        VStack(spacing: SkyTheme.Spacing.related) {
            AccountAvatarFace(
                name: displayName,
                image: app.accountAvatar,
                diameter: 88,
                ring: SkyTheme.Color.cardBorder
            )
            Text(displayName)
                .font(SkyTheme.Font.largeTitle)
                .foregroundStyle(SkyTheme.Color.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let email = emailLine {
                Text(email)
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(1)
            }
            Text("更换头像")
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SkyTheme.Spacing.related)
    }

    private var loggedOut: some View {
        VStack(spacing: SkyTheme.Spacing.related) {
            Spacer(minLength: 0)
            Text("请先登录")
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.ink)
            Text("登录后可以查看头像、用户名和健康授权。")
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayName: String {
        let name = app.account?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "我" : name
    }

    private var emailLine: String? {
        let email = app.account?.email.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? nil : email
    }

    private var passwordMode: MePasswordMode {
        MePasswordMode.resolve(
            usesLocalDirectory: SkyAuthConfig.usesLocalDirectory,
            hasPassword: !(app.account?.passwordHash.isEmpty ?? true)
        )
    }

    private func meLink(_ title: String, value: String?, route: MeRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: SkyTheme.Spacing.related) {
                Text(title)
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.ink)
                Spacer(minLength: SkyTheme.Spacing.related)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(SkyTheme.Font.subheadline)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: SkyTheme.Spacing.listRowMin)
        }
        .meRow()
    }

    private func meHeader(_ title: String) -> some View {
        Text(title)
            .font(SkyTheme.Font.footnote)
            .foregroundStyle(SkyTheme.Color.secondary)
            .textCase(nil)
    }
}

struct AccountAvatarFace: View {
    var name: String
    var image: UIImage?
    var diameter: CGFloat
    var ring: Color = SkyTheme.Color.card

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(mark)
                    .font(diameter >= 72 ? SkyTheme.Font.largeTitle : SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.onPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SkyTheme.Color.primary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(ring, lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }

    private var mark: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "我" }
        return String(first)
    }
}

struct MeLogoutSheet: View {
    var confirm: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SkyTheme.Spacing.screenInset) {
                Text("退出登录")
                    .font(SkyTheme.Font.title2)
                    .foregroundStyle(SkyTheme.Color.ink)
                Text("退出后，这台手机上的运动记录还在。再次登录可以回到账号。")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MeCapsuleButton(title: "退出登录", role: .danger) {
                    dismiss()
                    confirm()
                }
                    .padding(.top, SkyTheme.Spacing.related)
                    .accessibilityLabel("确认退出登录")
                Button("取消") { dismiss() }
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.primary)
                    .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
            }
            .padding(SkyTheme.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(SkyTheme.Color.background)
    }

    @Environment(\.dismiss) private var dismiss
}

struct MeCapsuleButton: View {
    enum Role {
        case primary
        case danger
    }

    var title: String
    var role: Role = .primary
    var action: () -> Void

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
        .buttonStyle(MeCapsuleButtonStyle(role: role))
    }
}

struct MeCapsuleButtonStyle: ButtonStyle {
    var role: MeCapsuleButton.Role = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        switch role {
        case .primary:
            return pressed ? SkyTheme.Color.primaryPressed : SkyTheme.Color.primary
        case .danger:
            return pressed ? SkyTheme.Color.danger.opacity(0.88) : SkyTheme.Color.danger
        }
    }
}

extension View {
    func meRow() -> some View {
        listRowBackground(SkyTheme.Color.card)
            .listRowSeparatorTint(SkyTheme.Color.separator)
    }

    func meInputChrome() -> some View {
        padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.vertical, SkyTheme.Spacing.related)
            .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
            .background(
                SkyTheme.Color.background,
                in: RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous)
                    .stroke(SkyTheme.Color.separator, lineWidth: 1)
            }
    }
}

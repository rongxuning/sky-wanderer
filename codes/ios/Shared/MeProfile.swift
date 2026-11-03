import Foundation

/// Local rules for the Me screens. The account service has no profile or password route,
/// so these checks stay on the device. `codes/ios/me-profile-check` exercises them.
enum MeProfileRules {
    static let maxNameLength = 24
    static let minPasswordLength = 8

    static func normalizedName(_ raw: String) -> Result<String, MeProfileError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.emptyName) }
        if name.count > maxNameLength { return .failure(.nameTooLong) }
        return .success(name)
    }

    /// `current` is required only when this account already has a password.
    /// The new password is returned unchanged, including spaces.
    static func validatePasswordChange(
        current: String,
        new: String,
        confirm: String,
        hasExistingPassword: Bool
    ) -> Result<String, MeProfileError> {
        if hasExistingPassword && current.isEmpty {
            return .failure(.currentPasswordRequired)
        }
        if new.count < minPasswordLength {
            return .failure(.passwordTooShort)
        }
        if new != confirm {
            return .failure(.passwordMismatch)
        }
        return .success(new)
    }
}

enum MeProfileError: Error, Equatable {
    case emptyName
    case nameTooLong
    case passwordTooShort
    case passwordMismatch
    case currentPasswordRequired
    case notSignedIn

    var message: String {
        switch self {
        case .emptyName:
            return "请填写用户名"
        case .nameTooLong:
            return "用户名最多 \(MeProfileRules.maxNameLength) 个字"
        case .passwordTooShort:
            return "密码至少 \(MeProfileRules.minPasswordLength) 位"
        case .passwordMismatch:
            return "两次输入的密码不一致"
        case .currentPasswordRequired:
            return "请填写当前密码"
        case .notSignedIn:
            return "请先登录"
        }
    }
}

enum MePasswordMode: Equatable {
    case localChange
    case localSet
    case remoteUnavailable

    static func resolve(usesLocalDirectory: Bool, hasPassword: Bool) -> MePasswordMode {
        guard usesLocalDirectory else { return .remoteUnavailable }
        return hasPassword ? .localChange : .localSet
    }

    var rowValue: String {
        switch self {
        case .localChange: return "已设置"
        case .localSet: return "未设置"
        case .remoteUnavailable: return "即将开通"
        }
    }

    var screenNote: String {
        switch self {
        case .localChange:
            return "需要当前密码。新密码至少 \(MeProfileRules.minPasswordLength) 位，只保存在这台手机上。"
        case .localSet:
            return "这个登录方式还没有密码。设置后只保存在这台手机上，至少 \(MeProfileRules.minPasswordLength) 位。"
        case .remoteUnavailable:
            return "修改密码还没有接到账号服务。线上账号的密码不会在这里改变。"
        }
    }

    var saveTitle: String {
        switch self {
        case .localSet: return "设置密码"
        case .localChange, .remoteUnavailable: return "保存新密码"
        }
    }
}

enum MeProfileCopy {
    static func displayNameNote(usesLocalDirectory: Bool) -> String {
        if usesLocalDirectory {
            return "用户名保存在这台手机上。"
        }
        return "用户名先改在这台手机上。账号服务还没有修改资料的接口，下次从服务器登录时会回到服务器上的名字。"
    }

    static func avatarNote(usesLocalDirectory: Bool) -> String {
        if usesLocalDirectory {
            return "头像只保存在这台手机上，不会上传。"
        }
        return "头像只保存在这台手机上。账号服务还没有头像接口，所以不会上传。"
    }

    static let notificationFootnote = "开关只保存在这台手机上。推送还没有接通，打开后也不会收到通知。"
}

/// Write permission for workouts. Read access stays opaque; HealthKit does not report it.
enum MeTrainingShareState: String, Equatable, CaseIterable {
    case unavailable
    case notDetermined
    case denied
    case authorized

    var title: String {
        switch self {
        case .unavailable: return "这台设备没有健康数据"
        case .notDetermined: return "还没有请求授权"
        case .denied: return "系统拒绝写入锻炼"
        case .authorized: return "可以写入锻炼"
        }
    }

    var detail: String {
        switch self {
        case .unavailable:
            return "训练授权需要健康 App。这台设备上只能先看说明。"
        case .notDetermined:
            return "授权后，徒步和跑步可以写入健康，包括路线、心率、距离和消耗。"
        case .denied:
            return "可以在系统设置的健康里重新打开写入。读取心率、睡眠和步数的开关也在那里。"
        case .authorized:
            return "新的徒步和跑步可以写入健康。读取心率、睡眠和步数是否打开，要在健康 App 里看，系统不会告诉应用。"
        }
    }
}

enum MeNotificationPreference: String, CaseIterable, Identifiable {
    case workout
    case health
    case team

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workout: return "运动结束"
        case .health: return "健康提醒"
        case .team: return "组队动态"
        }
    }

    var detail: String {
        switch self {
        case .workout: return "一次徒步或跑步保存后提醒"
        case .health: return "睡眠或步数有更新时提醒"
        case .team: return "队友开始或结束运动时提醒"
        }
    }

    private var key: String { "sky.me.notification." + rawValue }

    func isOn(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return false }
        return defaults.bool(forKey: key)
    }

    func setOn(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

struct MeSDKEntry: Equatable, Identifiable {
    var id: String
    var name: String
    var provider: String
    var purpose: String
    var data: String
    /// False when the app does not link that vendor's binary.
    var shipsBinary: Bool
}

enum MeSDKCatalog {
    static let intro = "这一版没有把第三方 SDK 打进安装包。下面是登录时可能联系的外部服务，以及本机使用的 Apple 框架。"

    static let services: [MeSDKEntry] = [
        MeSDKEntry(
            id: "wechat",
            name: "微信开放平台",
            provider: "深圳市腾讯计算机系统有限公司",
            purpose: "微信登录",
            data: "通过系统浏览器取得授权码。应用内不嵌入微信 SDK。",
            shipsBinary: false
        ),
        MeSDKEntry(
            id: "google",
            name: "Google 账号",
            provider: "Google",
            purpose: "Google 登录",
            data: "通过系统浏览器完成授权。应用内不嵌入 Google SDK。",
            shipsBinary: false
        )
    ]

    static let appleFrameworks: [MeSDKEntry] = [
        MeSDKEntry(
            id: "healthkit",
            name: "HealthKit",
            provider: "Apple",
            purpose: "心率、睡眠、步数和锻炼",
            data: "读写健康数据需要你在系统里授权。",
            shipsBinary: false
        ),
        MeSDKEntry(
            id: "mapkit",
            name: "MapKit",
            provider: "Apple",
            purpose: "地图和轨迹",
            data: "在本机绘制路线。",
            shipsBinary: false
        ),
        MeSDKEntry(
            id: "location",
            name: "Core Location",
            provider: "Apple",
            purpose: "定位",
            data: "运动中的位置，以及当地日出和日落。",
            shipsBinary: false
        ),
        MeSDKEntry(
            id: "auth",
            name: "AuthenticationServices",
            provider: "Apple",
            purpose: "浏览器登录",
            data: "打开微信和 Google 的授权页。",
            shipsBinary: false
        ),
        MeSDKEntry(
            id: "photos",
            name: "PhotosUI",
            provider: "Apple",
            purpose: "选择头像",
            data: "只读取你点选的那张照片。",
            shipsBinary: false
        )
    ]

    static var embedsThirdPartyBinary: Bool {
        services.contains { $0.shipsBinary }
    }
}

import Foundation

// swiftc codes/ios/Shared/MeProfile.swift codes/ios/me-profile-check/main.swift -o /tmp/me-profile-check && /tmp/me-profile-check

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

func expectName(_ raw: String, _ expected: String) {
    switch MeProfileRules.normalizedName(raw) {
    case .success(let name):
        check(name == expected, "name \(raw.debugDescription) became \(name.debugDescription)")
    case .failure(let error):
        check(false, "name \(raw.debugDescription) failed with \(error.message)")
    }
}

func expectNameError(_ raw: String, _ expected: MeProfileError) {
    switch MeProfileRules.normalizedName(raw) {
    case .success(let name):
        check(false, "name \(raw.debugDescription) succeeded as \(name)")
    case .failure(let error):
        check(error == expected, "name \(raw.debugDescription) error \(error) != \(expected)")
    }
}

expectName("  阿宁  ", "阿宁")
expectName(String(repeating: "宁", count: 24), String(repeating: "宁", count: 24))
expectNameError("   ", .emptyName)
expectNameError("", .emptyName)
expectNameError(String(repeating: "宁", count: 25), .nameTooLong)
check(MeProfileError.nameTooLong.message == "用户名最多 24 个字", "name length copy")

func expectPassword(
    current: String,
    new: String,
    confirm: String,
    hasExisting: Bool,
    expected: Result<String, MeProfileError>
) {
    let actual = MeProfileRules.validatePasswordChange(
        current: current,
        new: new,
        confirm: confirm,
        hasExistingPassword: hasExisting
    )
    check(actual == expected, "password \(current)/\(new)/\(confirm) has=\(hasExisting) -> \(actual) != \(expected)")
}

expectPassword(current: "old-pass", new: "12345678", confirm: "12345678", hasExisting: true, expected: .success("12345678"))
expectPassword(current: "", new: "12345678", confirm: "12345678", hasExisting: false, expected: .success("12345678"))
expectPassword(current: "", new: "12345678", confirm: "12345678", hasExisting: true, expected: .failure(.currentPasswordRequired))
expectPassword(current: "old-pass", new: "1234567", confirm: "1234567", hasExisting: true, expected: .failure(.passwordTooShort))
expectPassword(current: "old-pass", new: "12345678", confirm: "12345679", hasExisting: true, expected: .failure(.passwordMismatch))
expectPassword(current: "    ", new: "12345678", confirm: "12345678", hasExisting: true, expected: .success("12345678"))

check(MePasswordMode.resolve(usesLocalDirectory: true, hasPassword: true) == .localChange, "local change")
check(MePasswordMode.resolve(usesLocalDirectory: true, hasPassword: false) == .localSet, "local set")
check(MePasswordMode.resolve(usesLocalDirectory: false, hasPassword: true) == .remoteUnavailable, "remote with hash")
check(MePasswordMode.resolve(usesLocalDirectory: false, hasPassword: false) == .remoteUnavailable, "remote without hash")
check(MePasswordMode.localChange.rowValue == "已设置", "row set")
check(MePasswordMode.localSet.rowValue == "未设置", "row unset")
check(MePasswordMode.remoteUnavailable.rowValue == "即将开通", "row later")
check(MePasswordMode.localSet.saveTitle == "设置密码", "set title")
check(!MePasswordMode.remoteUnavailable.screenNote.isEmpty, "remote note")
check(MeProfileCopy.displayNameNote(usesLocalDirectory: true).contains("这台手机"), "local name note")
check(MeProfileCopy.displayNameNote(usesLocalDirectory: false).contains("账号服务"), "remote name note")
check(MeProfileCopy.avatarNote(usesLocalDirectory: false).contains("不会上传"), "avatar note")

let suiteName = "me-profile-check-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
check(MeNotificationPreference.allCases.allSatisfy { !$0.isOn(defaults: defaults) }, "notifications default off")
MeNotificationPreference.workout.setOn(true, defaults: defaults)
check(MeNotificationPreference.workout.isOn(defaults: defaults), "workout on")
check(!MeNotificationPreference.health.isOn(defaults: defaults), "health stays off")
let other = UserDefaults(suiteName: suiteName + "-other")!
check(!MeNotificationPreference.workout.isOn(defaults: other), "other suite untouched")

check(MeSDKCatalog.services.map(\.id) == ["wechat", "google"], "service order")
check(!MeSDKCatalog.embedsThirdPartyBinary, "no embedded sdk")
check(MeSDKCatalog.appleFrameworks.contains { $0.id == "healthkit" }, "healthkit listed")
check(MeSDKCatalog.appleFrameworks.contains { $0.id == "photos" }, "photos listed")
check(MeTrainingShareState.authorized.title == "可以写入锻炼", "share title")
check(MeTrainingShareState.allCases.allSatisfy { !$0.detail.isEmpty }, "share detail")

let copy = [
    MeSDKCatalog.intro,
    MeProfileCopy.notificationFootnote
] + MeSDKCatalog.services.flatMap { [$0.name, $0.provider, $0.purpose, $0.data] }
    + MeSDKCatalog.appleFrameworks.flatMap { [$0.name, $0.provider, $0.purpose, $0.data] }
    + MeTrainingShareState.allCases.flatMap { [$0.title, $0.detail] }
check(copy.allSatisfy { !$0.contains("—") && !$0.contains("–") }, "no em dash in copy")

if failures.isEmpty {
    print("ok")
} else {
    for failure in failures {
        fputs("FAIL \(failure)\n", stderr)
    }
    exit(1)
}

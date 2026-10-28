import CryptoKit
import Foundation
import SwiftUI
import UIKit

enum LocalDemoCode {
    /// Shown on the forgot-password screen after 获取验证码.
    /// This is a local demo. It is not emailed. There is no length rule and no expiry.
    static let token = "OMNI-LOCAL"
}

struct AuthFailure: Error, Identifiable {
    var id: String { message }
    var message: String
}

@MainActor
final class PhoneAppState: ObservableObject {
    @Published private(set) var database: Database
    @Published var banner = ""
    @Published var activeSession: LiveSession?
    @Published var finishedToken = 0

    private let filename = "phone.json"
    private var pendingResetEmail: String?
    private var verifiedResetEmail: String?

    init() {
        var loaded: Database
        if var existing = AppFiles.load(filename), existing.seeded {
            if existing.metricOrder.isEmpty {
                existing.metricOrder = LiveBlock.standard
            }
            Self.ensurePreset(&existing)
            loaded = existing
        } else {
            var fresh = Database()
            fresh.workouts = SampleLibrary.workouts()
            fresh.posts = SampleLibrary.posts()
            fresh.seeded = true
            Self.ensurePreset(&fresh)
            loaded = fresh
        }
        SessionContinuity.reconcile(&loaded, keychain: SessionKeychain.read())
        database = loaded
        AppFiles.save(loaded, name: filename)
        SessionKeychain.store(SessionContinuity.credential(in: loaded))
    }

    private static func ensurePreset(_ database: inout Database) {
        guard !database.routes.contains(where: { $0.kind == .presetRunning }) else { return }
        database.routes.insert(SampleLibrary.presetRunningRoute(), at: 0)
    }

    var account: Account? {
        guard let id = database.sessionAccountID else { return nil }
        return activeAccount(id: id)
    }

    /// Identities linked to the signed-in account. Empty when logged out.
    var identities: [AuthIdentity] {
        guard let id = account?.id else { return [] }
        return database.identities.filter { $0.userId == id }
    }

    var isLoggedIn: Bool { account != nil }

    var workouts: [WorkoutRecord] {
        database.workouts
            .filter { $0.sport == .hiking || $0.sport == .running }
            .sorted { $0.start > $1.start }
    }

    var posts: [SocialPost] {
        database.posts.sorted { $0.createdAt > $1.createdAt }
    }

    var savedRoutes: [SavedRoute] { database.routes }

    func replacePresetRunning(points: [GeoPoint]) {
        mutate { database in
            guard let index = database.routes.firstIndex(where: { $0.kind == .presetRunning }) else { return }
            database.routes[index].points = points
        }
    }

    func addGPXRoutes(_ imported: [(name: String, points: [GeoPoint])]) -> [String] {
        var identifiers: [String] = []
        mutate { database in
            for item in imported where item.points.count >= 2 {
                let identifier = UUID().uuidString
                var title = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { title = "导入路线" }
                let base = title
                var suffix = 2
                while database.routes.contains(where: { $0.name == title }) {
                    title = "\(base) \(suffix)"
                    suffix += 1
                }
                database.routes.append(SavedRoute(id: identifier, name: title, points: item.points, kind: .gpx))
                identifiers.append(identifier)
            }
        }
        return identifiers
    }

    var metricOrder: [LiveBlock] {
        let saved = database.metricOrder.filter { LiveBlock.standard.contains($0) }
        let missing = LiveBlock.standard.filter { !saved.contains($0) }
        return saved + missing
    }

    var estimate: TrainingEstimateSummary {
        TrainingEstimate.summarize(workouts: workouts)
    }

    func register(name: String, password: String, email: String) throws {
        let accountName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !accountName.isEmpty, !password.isEmpty, !mail.isEmpty else {
            throw AuthFailure(message: "请填写账号、密码和邮箱")
        }
        guard mail.contains("@") else {
            throw AuthFailure(message: "请填写邮箱")
        }
        if database.accounts.contains(where: {
            $0.retiredAt == nil && $0.name.compare(accountName, options: .caseInsensitive) == .orderedSame
        }) {
            throw AuthFailure(message: "这个账号已经注册")
        }
        if database.accounts.contains(where: { $0.retiredAt == nil && $0.email.lowercased() == mail }) {
            throw AuthFailure(message: "这个邮箱已经绑定")
        }
        let created = Account(id: UUID(), name: accountName, email: mail, passwordHash: Self.hash(password), createdAt: Date())
        mutate { database in
            database.accounts.append(created)
            Self.issueSession(on: &database, accountID: created.id)
        }
    }

    func login(name: String, password: String) throws {
        let accountName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountName.isEmpty, !password.isEmpty else {
            throw AuthFailure(message: "请填写账号和密码")
        }
        let digest = Self.hash(password)
        guard let match = database.accounts.first(where: {
            $0.retiredAt == nil
                && !$0.passwordHash.isEmpty
                && $0.name.compare(accountName, options: .caseInsensitive) == .orderedSame
                && $0.passwordHash == digest
        }) else {
            throw AuthFailure(message: "账号或密码不正确")
        }
        mutate { database in
            Self.issueSession(on: &database, accountID: match.id)
        }
        banner = ""
    }

    /// Phone identity. `demoCode` must be `IdentityDemoCode.token` until SMS exists.
    @discardableResult
    func signInPhone(phone: String, demoCode: String, displayName: String? = nil) throws -> IdentityAuthResult {
        try performIdentity { directory in
            try directory.loginOrRegister(
                type: .phone,
                providerSubject: phone,
                demoCode: demoCode,
                displayName: displayName
            )
        }
    }

    /// WeChat stub. `openId` is the future openid; nothing calls the WeChat SDK.
    @discardableResult
    func signInWeChat(openId: String, displayName: String? = nil) throws -> IdentityAuthResult {
        try performIdentity { directory in
            try directory.loginOrRegister(type: .wechat, providerSubject: openId, displayName: displayName)
        }
    }

    /// Google stub. `subject` is the future ID-token `sub`.
    @discardableResult
    func signInGoogle(subject: String, email: String? = nil, displayName: String? = nil) throws -> IdentityAuthResult {
        try performIdentity { directory in
            try directory.loginOrRegister(
                type: .google,
                providerSubject: subject,
                displayName: displayName,
                email: email
            )
        }
    }

    @discardableResult
    func bindPhone(phone: String, demoCode: String) throws -> IdentityAuthResult {
        try ensureSessionToken()
        return try performIdentity { directory in
            try directory.bind(type: .phone, providerSubject: phone, demoCode: demoCode)
        }
    }

    @discardableResult
    func bindWeChat(openId: String) throws -> IdentityAuthResult {
        try ensureSessionToken()
        return try performIdentity { directory in
            try directory.bind(type: .wechat, providerSubject: openId)
        }
    }

    @discardableResult
    func bindGoogle(subject: String, email: String? = nil) throws -> IdentityAuthResult {
        try ensureSessionToken()
        return try performIdentity { directory in
            try directory.bind(type: .google, providerSubject: subject, email: email)
        }
    }

    func unbindIdentity(_ type: IdentityType, providerSubject: String) throws {
        try ensureSessionToken()
        _ = try performIdentity { directory in
            try directory.unbind(type: type, providerSubject: providerSubject)
        }
    }

    func logout() {
        mutate { database in
            if let token = database.sessionToken {
                database.authSessions.removeAll { $0.token == token }
            }
            database.sessionToken = nil
            database.sessionAccountID = nil
        }
    }

    func prepareReset(email: String) throws {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard database.accounts.contains(where: { $0.retiredAt == nil && $0.email.lowercased() == mail }) else {
            throw AuthFailure(message: "这个邮箱还没有绑定账号")
        }
        pendingResetEmail = mail
        verifiedResetEmail = nil
    }

    func verifyReset(email: String, code: String) throws {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard pendingResetEmail == mail else {
            throw AuthFailure(message: "请先获取验证码")
        }
        guard code.trimmingCharacters(in: .whitespacesAndNewlines) == LocalDemoCode.token else {
            throw AuthFailure(message: "验证码不正确")
        }
        verifiedResetEmail = mail
    }

    func resetPassword(email: String, password: String, confirm: String) throws {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard verifiedResetEmail == mail else {
            throw AuthFailure(message: "请先完成验证")
        }
        guard !password.isEmpty, !confirm.isEmpty else {
            throw AuthFailure(message: "请填写新密码和确认密码")
        }
        guard password == confirm else {
            throw AuthFailure(message: "两次输入的密码不一致")
        }
        guard let index = database.accounts.firstIndex(where: { $0.retiredAt == nil && $0.email.lowercased() == mail }) else {
            throw AuthFailure(message: "这个邮箱还没有绑定账号")
        }
        mutate { database in
            database.accounts[index].passwordHash = Self.hash(password)
        }
        pendingResetEmail = nil
        verifiedResetEmail = nil
        banner = "密码已更新，请登录"
    }

    func setMetricOrder(_ order: [LiveBlock]) {
        mutate { $0.metricOrder = order }
    }

    func session(for sport: SportKind, route: [GeoPoint], teammates: [TeammateProfile]) -> LiveSession {
        if let activeSession, activeSession.phase != .finished {
            return activeSession
        }
        let created = LiveSession(sport: sport, plannedRoute: route, teammates: teammates)
        activeSession = created
        return created
    }

    func addWorkout(_ record: WorkoutRecord) {
        mutate { database in
            if let healthID = record.healthKitUUID,
               database.workouts.contains(where: { $0.healthKitUUID == healthID }) {
                return
            }
            database.workouts.removeAll { $0.id == record.id }
            database.workouts.append(record)
            database.workouts.sort { $0.start > $1.start }
        }
    }

    func importFromApple() async {
        let source = AppleActivitySource()
        do {
            try await source.prepare()
            let imported = try await source.importRunsAndHikes()
            mutate { database in
                for record in imported {
                    guard let healthID = record.healthKitUUID else { continue }
                    if database.workouts.contains(where: { $0.healthKitUUID == healthID }) { continue }
                    database.workouts.append(record)
                }
                database.workouts.sort { $0.start > $1.start }
            }
        } catch {
            banner = "暂时读不到 Apple 健康里的锻炼"
        }
    }

    func addPost(from record: WorkoutRecord, text: String, imageData: Data?) {
        let filename = storeImage(imageData)
        let post = SocialPost(
            id: UUID(),
            author: account?.name ?? "我",
            isMine: true,
            createdAt: Date(),
            sport: record.sport,
            distanceMeters: record.distanceMeters,
            duration: record.duration,
            paceSecPerKm: record.averagePaceSecPerKm,
            energyKilocalories: record.energyKilocalories,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            imageFilename: filename,
            route: record.route
        )
        mutate { $0.posts.insert(post, at: 0) }
    }

    func image(named filename: String) -> UIImage? {
        guard let url = try? AppFiles.file(filename),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func noteFinished() {
        activeSession = nil
        finishedToken += 1
    }

    func stats(for window: StatsWindow, now: Date = Date()) -> TrainingStats {
        RecordStats.make(workouts: workouts, window: window, now: now)
    }

    private func storeImage(_ data: Data?) -> String? {
        guard let data, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.82) else {
            return nil
        }
        let name = UUID().uuidString + ".jpg"
        guard let url = try? AppFiles.file(name) else { return nil }
        do {
            try jpeg.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private func activeAccount(id: UUID) -> Account? {
        SessionContinuity.liveAccount(in: database, id: id)
    }

    private func ensureSessionToken() throws {
        if database.sessionToken != nil { return }
        guard let id = account?.id else { throw AuthFailure(message: "请先登录") }
        mutate { database in
            Self.issueSession(on: &database, accountID: id)
        }
    }

    private func performIdentity(
        _ work: (inout IdentityDirectory) throws -> IdentityAuthResult
    ) throws -> IdentityAuthResult {
        var directory = IdentityDirectory(
            accounts: database.accounts,
            identities: database.identities,
            sessions: database.authSessions,
            records: database.authRecords,
            currentAccountID: database.sessionAccountID,
            currentToken: database.sessionToken
        )
        let result: IdentityAuthResult
        do {
            result = try work(&directory)
        } catch let error as IdentityAuthError {
            throw AuthFailure(message: error.message)
        }
        mutate { database in
            database.accounts = directory.accounts
            database.identities = directory.identities
            database.authSessions = directory.sessions
            database.authRecords = directory.records
            database.sessionAccountID = directory.currentAccountID
            database.sessionToken = directory.currentToken
        }
        banner = ""
        return result
    }

    /// Local demo session. `mutate` also writes the token and account id to the Keychain.
    private static func issueSession(on database: inout Database, accountID: UUID) {
        if let existing = database.sessionToken {
            database.authSessions.removeAll { $0.token == existing }
        }
        let token = UUID().uuidString
        database.sessionToken = token
        database.sessionAccountID = accountID
        database.authSessions.append(AuthSession(token: token, userId: accountID, createdAt: Date()))
    }

    private func mutate(_ body: (inout Database) -> Void) {
        var copy = database
        body(&copy)
        let signingOut = SessionContinuity.credential(in: database) != nil
            && SessionContinuity.credential(in: copy) == nil
        if signingOut {
            SessionKeychain.store(nil)
        }
        database = copy
        AppFiles.save(copy, name: filename)
        if let credential = SessionContinuity.credential(in: copy) {
            SessionKeychain.store(credential)
        }
    }

    /// Local demo hash only. This is not a production password store.
    private static func hash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class WorkoutDraft: ObservableObject {
    @Published var sport: SportKind = .running
    @Published var routeID = "free"
    @Published var memberIDs: [String] = []
    @Published var countdown = false
    @Published var origin = MapOrigin.fallback

    func plannedRoute(saved: [SavedRoute], workouts: [WorkoutRecord]) -> PlannedRoute {
        if let route = saved.first(where: { $0.id == routeID }) {
            return PlannedRoute(id: route.id, name: route.name, points: route.points)
        }
        if let workout = workouts.first(where: { $0.id.uuidString == routeID }) {
            return PlannedRoute(id: routeID, name: workout.sport.title, points: workout.route)
        }
        return .free
    }

    var members: [TeammateProfile] {
        SampleLibrary.teammates.filter { memberIDs.contains($0.id) }
    }
}

@MainActor
final class MeHealth: ObservableObject {
    @Published var heartRate = 72.0
    @Published var sleepHours = 7.4
    @Published var steps = 6420
    @Published var heartIsSample = true
    @Published var sleepIsSample = true
    @Published var stepsAreSample = true
    @Published var note = "下面先显示示例。授权健康数据后会换成设备里的数。"

    func refresh() async {
        guard AppleHealth.available else {
            note = "这台设备没有健康数据，下面是示例。"
            return
        }
        do {
            try await AppleHealth.authorize()
        } catch {
            note = "没有获得健康数据授权，下面是示例。"
            return
        }
        let day = await AppleHealth.today()
        if let heart = day.heartRate, heart > 0 {
            heartRate = heart
            heartIsSample = false
        }
        if let sleep = day.sleepHours, sleep > 0 {
            sleepHours = sleep
            sleepIsSample = false
        }
        if let steps = day.steps {
            self.steps = steps
            stepsAreSample = false
        }
        if heartIsSample && sleepIsSample && stepsAreSample {
            note = "健康里暂时没有这些数，下面是示例。"
        } else if heartIsSample || sleepIsSample || stepsAreSample {
            note = "缺的项目用示例补上，并单独标明。"
        } else {
            note = ""
        }
    }
}

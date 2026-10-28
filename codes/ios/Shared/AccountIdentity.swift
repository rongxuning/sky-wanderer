import Foundation

/// Local stand-in for an SMS code. It is not sent and it does not expire.
/// Password reset still uses `LocalDemoCode` (`OMNI-LOCAL`). This one is only for phone identity.
enum IdentityDemoCode {
    static let token = "SKY-LOCAL"
}

enum IdentityType: String, Codable, Hashable, CaseIterable {
    case phone
    case wechat
    case google
}

struct AuthIdentity: Codable, Hashable, Identifiable {
    var id: UUID
    var type: IdentityType
    /// E.164 phone, WeChat openid, or Google `sub`.
    var providerSubject: String
    var email: String?
    var phone: String?
    var userId: UUID
    var createdAt: Date
}

struct AuthSession: Codable, Hashable, Identifiable {
    var token: String
    var userId: UUID
    var createdAt: Date

    var id: String { token }
}

/// Account-scoped payload moved onto the surviving user during a merge.
/// Workouts are still device-wide; this is the hook for data that belongs to one user.
struct AuthOwnedRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var userId: UUID
    var kind: String
    var payload: String
}

struct IdentityAuthResult: Equatable {
    var account: Account
    var session: AuthSession
    var created: Bool
    var merged: Bool
}

enum IdentityAuthError: Error, Equatable {
    case invalidDemoCode
    case invalidPhone
    case invalidSubject
    case notAuthenticated
    case lastIdentity
    case identityNotFound
    case userMissing

    var message: String {
        switch self {
        case .invalidDemoCode: return "验证码不正确"
        case .invalidPhone: return "请填写有效手机号"
        case .invalidSubject: return "登录信息没有完成"
        case .notAuthenticated: return "请先登录"
        case .lastIdentity: return "至少保留一种登录方式"
        case .identityNotFound: return "这个登录方式不在当前账号上"
        case .userMissing: return "账号不存在"
        }
    }
}

/// Same rules as `codes/server/src/auth-service.ts`.
/// The executable tests live in `codes/server/test`. Keep the two copies aligned.
///
/// TODO: phone — verify an SMS code with a provider instead of `IdentityDemoCode`.
/// TODO: WeChat — exchange the OAuth code and trust the openid WeChat returns.
/// TODO: Google — validate the ID token and use its `sub`.
/// The phone app mirrors `currentToken` and the account id into the Keychain
/// (`SessionKeychain`). This directory stays free of Security framework calls.
struct IdentityDirectory {
    var accounts: [Account] = []
    var identities: [AuthIdentity] = []
    var sessions: [AuthSession] = []
    var records: [AuthOwnedRecord] = []
    var currentAccountID: UUID?
    var currentToken: String?

    mutating func loginOrRegister(
        type: IdentityType,
        providerSubject: String,
        demoCode: String? = nil,
        displayName: String? = nil,
        email: String? = nil
    ) throws -> IdentityAuthResult {
        try verifyStub(type: type, demoCode: demoCode)
        let subject = try canonicalSubject(type: type, raw: providerSubject)
        if let index = identityIndex(type: type, subject: subject) {
            let owner = try activeAccount(id: identities[index].userId)
            if identities[index].userId != owner.id {
                identities[index].userId = owner.id
            }
            let session = openSession(userId: owner.id)
            return IdentityAuthResult(account: owner, session: session, created: false, merged: false)
        }

        let now = Date()
        let normalizedEmail = normalizeEmail(email)
        let account = Account(
            id: UUID(),
            name: defaultDisplayName(type: type, subject: subject, email: normalizedEmail, displayName: displayName),
            email: normalizedEmail,
            passwordHash: "",
            createdAt: now
        )
        let identity = AuthIdentity(
            id: UUID(),
            type: type,
            providerSubject: subject,
            email: normalizedEmail.isEmpty ? nil : normalizedEmail,
            phone: type == .phone ? subject : nil,
            userId: account.id,
            createdAt: now
        )
        accounts.append(account)
        identities.append(identity)
        let session = openSession(userId: account.id)
        return IdentityAuthResult(account: account, session: session, created: true, merged: false)
    }

    mutating func bind(
        type: IdentityType,
        providerSubject: String,
        demoCode: String? = nil,
        email: String? = nil
    ) throws -> IdentityAuthResult {
        guard let token = currentToken else { throw IdentityAuthError.notAuthenticated }
        guard let sessionIndex = sessions.firstIndex(where: { $0.token == token }) else {
            throw IdentityAuthError.notAuthenticated
        }
        let current = try activeAccount(id: sessions[sessionIndex].userId)
        try verifyStub(type: type, demoCode: demoCode)
        let subject = try canonicalSubject(type: type, raw: providerSubject)

        if let index = identityIndex(type: type, subject: subject) {
            let owner = try activeAccount(id: identities[index].userId)
            if identities[index].userId != owner.id {
                identities[index].userId = owner.id
            }
            if owner.id == current.id {
                sessions[sessionIndex].userId = current.id
                currentAccountID = current.id
                return IdentityAuthResult(account: current, session: sessions[sessionIndex], created: false, merged: false)
            }
            let master = try merge(leftID: current.id, rightID: owner.id)
            currentAccountID = master.id
            guard let liveIndex = sessions.firstIndex(where: { $0.token == token }) else {
                throw IdentityAuthError.notAuthenticated
            }
            return IdentityAuthResult(account: master, session: sessions[liveIndex], created: false, merged: true)
        }

        let normalizedEmail = normalizeEmail(email)
        identities.append(
            AuthIdentity(
                id: UUID(),
                type: type,
                providerSubject: subject,
                email: normalizedEmail.isEmpty ? nil : normalizedEmail,
                phone: type == .phone ? subject : nil,
                userId: current.id,
                createdAt: Date()
            )
        )
        if !normalizedEmail.isEmpty, let accountIndex = accounts.firstIndex(where: { $0.id == current.id }),
           accounts[accountIndex].email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accounts[accountIndex].email = normalizedEmail
        }
        sessions[sessionIndex].userId = current.id
        currentAccountID = current.id
        let account = accounts.first { $0.id == current.id } ?? current
        return IdentityAuthResult(account: account, session: sessions[sessionIndex], created: false, merged: false)
    }

    func listIdentities() throws -> [AuthIdentity] {
        guard let token = currentToken, let session = sessions.first(where: { $0.token == token }) else {
            throw IdentityAuthError.notAuthenticated
        }
        let user = try activeAccount(id: session.userId)
        return identities.filter { $0.userId == user.id }
    }

    mutating func unbind(type: IdentityType, providerSubject: String) throws -> IdentityAuthResult {
        guard let token = currentToken, let session = sessions.first(where: { $0.token == token }) else {
            throw IdentityAuthError.notAuthenticated
        }
        let user = try activeAccount(id: session.userId)
        let subject = try canonicalSubject(type: type, raw: providerSubject)
        let owned = identities.filter { $0.userId == user.id }
        guard let target = owned.first(where: { $0.type == type && $0.providerSubject == subject }) else {
            throw IdentityAuthError.identityNotFound
        }
        if owned.count <= 1 { throw IdentityAuthError.lastIdentity }
        identities.removeAll { $0.id == target.id }
        return IdentityAuthResult(account: user, session: session, created: false, merged: false)
    }

    func activeAccount(id: UUID) throws -> Account {
        var seen = Set<UUID>()
        var currentID = id
        while true {
            guard let account = accounts.first(where: { $0.id == currentID }) else {
                throw IdentityAuthError.userMissing
            }
            if account.retiredAt == nil { return account }
            guard let next = account.mergedIntoUserID, seen.insert(account.id).inserted else {
                throw IdentityAuthError.userMissing
            }
            currentID = next
        }
    }

    private mutating func merge(leftID: UUID, rightID: UUID) throws -> Account {
        let left = try activeAccount(id: leftID)
        let right = try activeAccount(id: rightID)
        if left.id == right.id { return left }

        let rightIsEarlier = right.createdAt < left.createdAt
            || (right.createdAt == left.createdAt && right.id.uuidString < left.id.uuidString)
        var master = rightIsEarlier ? right : left
        var loser = rightIsEarlier ? left : right

        for index in identities.indices where identities[index].userId == loser.id {
            identities[index].userId = master.id
        }
        for index in records.indices where records[index].userId == loser.id {
            records[index].userId = master.id
        }
        for index in sessions.indices where sessions[index].userId == loser.id {
            sessions[index].userId = master.id
        }
        if currentAccountID == loser.id { currentAccountID = master.id }

        if master.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !loser.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            master.name = loser.name
        }
        if master.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !loser.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            master.email = loser.email
        }
        if master.passwordHash.isEmpty, !loser.passwordHash.isEmpty {
            master.passwordHash = loser.passwordHash
        }
        master.mergedFromUserIDs.append(loser.id)
        master.mergedFromUserIDs.append(contentsOf: loser.mergedFromUserIDs)
        loser.retiredAt = Date()
        loser.mergedIntoUserID = master.id

        guard let masterIndex = accounts.firstIndex(where: { $0.id == master.id }),
              let loserIndex = accounts.firstIndex(where: { $0.id == loser.id }) else {
            throw IdentityAuthError.userMissing
        }
        accounts[masterIndex] = master
        accounts[loserIndex] = loser
        return master
    }

    private mutating func openSession(userId: UUID) -> AuthSession {
        let session = AuthSession(token: UUID().uuidString, userId: userId, createdAt: Date())
        sessions.append(session)
        currentToken = session.token
        currentAccountID = userId
        return session
    }

    private func identityIndex(type: IdentityType, subject: String) -> Int? {
        identities.firstIndex { $0.type == type && $0.providerSubject == subject }
    }
}

private func verifyStub(type: IdentityType, demoCode: String?) throws {
    // TODO: replace with SMS, WeChat OAuth, or Google token verification.
    guard type == .phone else { return }
    if demoCode?.trimmingCharacters(in: .whitespacesAndNewlines) != IdentityDemoCode.token {
        throw IdentityAuthError.invalidDemoCode
    }
}

private func normalizeEmail(_ email: String?) -> String {
    email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
}

private func defaultDisplayName(type: IdentityType, subject: String, email: String, displayName: String?) -> String {
    if let given = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
        return given
    }
    switch type {
    case .wechat:
        return "微信用户"
    case .google:
        let local = email.split(separator: "@").first.map { String($0) } ?? ""
        return local.isEmpty ? "Google 用户" : local
    case .phone:
        return "手机 \(subject.suffix(4))"
    }
}

/// Canonical provider subject. Phone numbers become E.164.
/// `13800138000` and `+86 138-0013-8000` are the same subject: `+8613800138000`.
private func canonicalSubject(type: IdentityType, raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if type != .phone {
        if trimmed.isEmpty { throw IdentityAuthError.invalidSubject }
        return trimmed
    }

    let compact = String(trimmed.filter { character in
        !character.isWhitespace && !"().-".contains(character)
    })
    if compact.hasPrefix("+") {
        let digits = decimalDigits(String(compact.dropFirst()))
        if digits.count < 8 || digits.count > 15 { throw IdentityAuthError.invalidPhone }
        return "+\(digits)"
    }

    let digits = decimalDigits(compact)
    if digits.count == 11, digits.hasPrefix("1") { return "+86\(digits)" }
    if digits.hasPrefix("86"), digits.count == 13 { return "+\(digits)" }
    if digits.count >= 8, digits.count <= 15 { return "+\(digits)" }
    throw IdentityAuthError.invalidPhone
}

private func decimalDigits(_ value: String) -> String {
    String(value.filter { ("0"..."9").contains($0) })
}

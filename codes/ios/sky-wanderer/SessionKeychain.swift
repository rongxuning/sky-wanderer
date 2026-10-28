import Foundation
import Security

/// Session token plus the account fields required to restore `PhoneAppState.isLoggedIn`.
/// Written beside `phone.json`. The file remains the account directory.
struct SessionCredential: Codable, Equatable {
    var token: String
    var accountID: UUID
    var name: String
    var email: String
    /// Seconds since 1970, same clock as `Account.createdAt` on disk.
    var createdAt: TimeInterval

    init(token: String, accountID: UUID, name: String, email: String, createdAt: Date) {
        self.token = token
        self.accountID = accountID
        self.name = name
        self.email = email
        self.createdAt = createdAt.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case token, accountID, name, email, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        createdAt = try container.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// Device Keychain copy of the signed-in session.
///
/// `kSecAttrAccessibleAfterFirstUnlock` keeps the item across reboot and includes it
/// in encrypted backups, so a backup restore can still rebuild the session.
/// Removing the app without restoring a backup deletes Keychain items on iOS.
enum SessionKeychain {
    private static let service = "com.rongxuning.sky-wanderer.session"
    private static let account = "session"

    static func read() -> SessionCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        guard let credential = try? JSONDecoder().decode(SessionCredential.self, from: data) else { return nil }
        let token = credential.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return credential
    }

    /// Pass nil to overwrite the item with an empty token. Logout does this before
    /// `phone.json` is saved, so a later launch does not treat the previous token as current.
    static func store(_ credential: SessionCredential?) {
        let stored = credential ?? SessionCredential(
            token: "",
            accountID: loggedOutAccountID,
            name: "",
            email: "",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let query = baseQuery()
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static let loggedOutAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Decide the signed-in session from `phone.json` and the Keychain before the root gate.
enum SessionContinuity {
    /// A non-empty on-disk session wins, so a newer login is not replaced by a stale Keychain item.
    /// When the file has no session, the Keychain credential is applied and, if the account row
    /// is missing, rebuilt from the stored id and display name.
    static func reconcile(_ database: inout Database, keychain: SessionCredential?) {
        if let current = credential(in: database) {
            adopt(current, into: &database)
            return
        }

        if let keychain,
           let account = materializeAccount(&database, credential: keychain) {
            adopt(
                SessionCredential(
                    token: keychain.token,
                    accountID: account.id,
                    name: account.name,
                    email: account.email,
                    createdAt: account.createdAt
                ),
                into: &database
            )
            return
        }

        if let id = database.sessionAccountID, liveAccount(in: database, id: id) != nil {
            return
        }
        database.sessionToken = nil
        database.sessionAccountID = nil
    }

    static func credential(in database: Database) -> SessionCredential? {
        guard let token = trimmedToken(database.sessionToken),
              let id = database.sessionAccountID,
              let account = liveAccount(in: database, id: id) else { return nil }
        return SessionCredential(
            token: token,
            accountID: account.id,
            name: account.name,
            email: account.email,
            createdAt: account.createdAt
        )
    }

    static func liveAccount(in database: Database, id: UUID) -> Account? {
        var seen = Set<UUID>()
        var current = database.accounts.first { $0.id == id }
        while let found = current, found.retiredAt != nil, let next = found.mergedIntoUserID, seen.insert(found.id).inserted {
            current = database.accounts.first { $0.id == next }
        }
        guard let current, current.retiredAt == nil else { return nil }
        return current
    }

    private static func materializeAccount(_ database: inout Database, credential: SessionCredential) -> Account? {
        guard trimmedToken(credential.token) != nil else { return nil }
        if let live = liveAccount(in: database, id: credential.accountID) {
            return live
        }
        if database.accounts.contains(where: { $0.id == credential.accountID }) {
            return nil
        }
        let name = credential.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = Account(
            id: credential.accountID,
            name: name.isEmpty ? "用户" : name,
            email: credential.email,
            passwordHash: "",
            createdAt: Date(timeIntervalSince1970: credential.createdAt)
        )
        database.accounts.append(created)
        return created
    }

    private static func adopt(_ credential: SessionCredential, into database: inout Database) {
        guard let token = trimmedToken(credential.token) else { return }
        if let previous = trimmedToken(database.sessionToken), previous != token {
            database.authSessions.removeAll { $0.token == previous }
        }
        database.sessionToken = token
        database.sessionAccountID = credential.accountID
        if let index = database.authSessions.firstIndex(where: { $0.token == token }) {
            database.authSessions[index].userId = credential.accountID
        } else {
            database.authSessions.append(AuthSession(token: token, userId: credential.accountID, createdAt: Date()))
        }
    }

    private static func trimmedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

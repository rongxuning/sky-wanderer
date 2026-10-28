import Foundation

struct PhoneCodeTicket: Decodable, Equatable {
    var phone: String
    var expiresInSeconds: Int
    var demoCode: String?

    init(phone: String, expiresInSeconds: Int, demoCode: String?) {
        self.phone = phone
        self.expiresInSeconds = expiresInSeconds
        self.demoCode = demoCode
    }
}

struct SkyAPIError: Error {
    var code: String
    var status: Int

    static func localMessage(for code: String) -> String {
        switch code {
        case "invalid_demo_code", "invalid_sms_code":
            return "验证码不正确"
        case "sms_expired":
            return "验证码已过期，请重新获取"
        case "sms_not_configured":
            return "短信服务还没有配置"
        case "sms_rate_limited":
            return "请稍后再获取验证码"
        case "sms_failed":
            return "短信没有发出"
        case "wechat_not_configured":
            return "微信登录还没有配置"
        case "wechat_exchange_failed":
            return "微信授权没有完成"
        case "google_not_configured":
            return "Google 登录还没有配置"
        case "invalid_id_token":
            return "Google 身份没有通过校验"
        case "not_authenticated":
            return "请先登录"
        case "last_identity":
            return "至少保留一种登录方式"
        case "identity_not_found":
            return "这个登录方式不在当前账号上"
        case "user_missing":
            return "账号不存在"
        case "invalid_phone":
            return "请填写有效手机号"
        case "invalid_subject":
            return "登录信息没有完成"
        case "db_unavailable":
            return "账号服务暂时不可用"
        case "unreachable", "not_configured":
            return "暂时连不上账号服务"
        default:
            return "登录没有完成"
        }
    }
}

struct RemoteUser: Decodable {
    var id: String
    var createdAt: String
    var displayName: String
    var email: String
    var retiredAt: String?
    var mergedIntoUserId: String?
    var mergedFromUserIds: [String]
}

struct RemoteSession: Decodable {
    var token: String
    var userId: String
    var createdAt: String
}

struct RemoteIdentity: Decodable {
    var id: String
    var type: String
    var providerSubject: String
    var email: String?
    var phone: String?
    var userId: String
    var createdAt: String
}

struct RemoteAuthPayload: Decodable {
    var user: RemoteUser
    var session: RemoteSession
    var created: Bool?
    var merged: Bool?
    var identities: [RemoteIdentity]
}

struct RemoteIdentityList: Decodable {
    var identities: [RemoteIdentity]
}

enum SkyTime {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum SkyAuthClient {
    static func sendPhoneCode(phone: String) async throws -> PhoneCodeTicket {
        try await request(path: "v1/auth/phone/send-code", method: "POST", body: ["phone": phone], token: nil)
    }

    static func login(_ body: [String: String]) async throws -> RemoteAuthPayload {
        try await request(path: "v1/auth/login", method: "POST", body: body, token: nil)
    }

    static func bind(_ body: [String: String], token: String) async throws -> RemoteAuthPayload {
        try await request(path: "v1/auth/bind", method: "POST", body: body, token: token)
    }

    static func listIdentities(token: String) async throws -> [RemoteIdentity] {
        let list: RemoteIdentityList = try await request(path: "v1/auth/identities", method: "GET", body: nil, token: token)
        return list.identities
    }

    static func unbind(type: String, providerSubject: String, token: String) async throws -> [RemoteIdentity] {
        let list: RemoteIdentityList = try await request(
            path: "v1/auth/identities",
            method: "DELETE",
            body: ["type": type, "providerSubject": providerSubject],
            token: token
        )
        return list.identities
    }

    static func logout(token: String) async {
        _ = try? await send(path: "v1/auth/logout", method: "POST", body: nil, token: token)
    }

    private static func request<T: Decodable>(
        path: String,
        method: String,
        body: [String: String]?,
        token: String?
    ) async throws -> T {
        let data = try await send(path: path, method: method, body: body, token: token)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SkyAPIError(code: "invalid_response", status: 200)
        }
    }

    private static func send(path: String, method: String, body: [String: String]?, token: String?) async throws -> Data {
        guard let url = SkyAuthConfig.endpoint(path) else {
            throw SkyAPIError(code: "not_configured", status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SkyAPIError(code: "unreachable", status: 0)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return Data("{}".utf8) }
        guard (200 ... 299).contains(status) else {
            if let parsed = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw SkyAPIError(code: parsed.error.code, status: status)
            }
            throw SkyAPIError(code: "http_\(status)", status: status)
        }
        return data
    }
}

private struct APIErrorBody: Decodable {
    struct Item: Decodable {
        var code: String
        var message: String
    }

    var error: Item
}

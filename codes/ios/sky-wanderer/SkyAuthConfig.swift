import Foundation

/// Account-service address compiled into the app.
/// `Config/Sky.xcconfig` is the default. A target build setting with the same name overrides it.
/// The on-device demo (no SMS, placeholder WeChat and Google subjects) is used only when the
/// base URL is empty or `SKY_AUTH_DEMO` is `1`.
enum SkyAuthConfig {
    static var usesLocalDirectory: Bool {
        apiBaseURL == nil || authDemo
    }

    static var apiBaseURL: URL? {
        let raw = string("SKY_API_BASE_URL")
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    static var hostLabel: String {
        apiBaseURL?.host ?? "账号服务"
    }

    static var authDemo: Bool {
        let raw = string("SKY_AUTH_DEMO").lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static var wechatAppId: String? {
        let value = string("SKY_WECHAT_APP_ID")
        return value.isEmpty ? nil : value
    }

    static var googleClientId: String? {
        let value = string("SKY_GOOGLE_CLIENT_ID")
        return value.isEmpty ? nil : value
    }

    static var wechatRedirectURI: String {
        redirect("SKY_WECHAT_REDIRECT_URI", path: "v1/auth/wechat/callback")
    }

    static var googleRedirectURI: String {
        redirect("SKY_GOOGLE_REDIRECT_URI", path: "v1/auth/google/callback")
    }

    static func endpoint(_ path: String) -> URL? {
        guard let base = apiBaseURL else { return nil }
        var root = base.absoluteString
        if root.hasSuffix("/") { root.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: root + suffix)
    }

    private static func redirect(_ key: String, path: String) -> String {
        let custom = string(key)
        if !custom.isEmpty { return custom }
        return endpoint(path)?.absoluteString ?? ""
    }

    private static func string(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") { return "" }
        return trimmed
    }
}

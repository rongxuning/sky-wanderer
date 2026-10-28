import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct AuthCallback {
    var code: String?
    var state: String?
    var error: String?

    static func parse(_ url: URL) -> AuthCallback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let found = items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let found, !found.isEmpty else { return nil }
            return found
        }
        return AuthCallback(code: value("code"), state: value("state"), error: value("error"))
    }
}

enum Pkce {
    static func pair() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0 ... 255)
            }
        }
        let verifier = Data(bytes).base64URLEncoded
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncoded
        return (verifier, challenge)
    }
}

enum SkyBrowserAuth {
    private static let presenter = Presenter()
    private static var session: ASWebAuthenticationSession?

    static func start(url: URL, callbackScheme: String) async throws -> AuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            let gate = Gate()
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                gate.once {
                    if let callback {
                        continuation.resume(returning: AuthCallback.parse(callback))
                    } else {
                        continuation.resume(throwing: failure(error))
                    }
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                gate.once {
                    continuation.resume(throwing: AuthFailure(message: "授权没有完成"))
                }
            }
        }
    }

    static func wechatURL(appId: String, redirect: String, state: String) -> URL? {
        var components = URLComponents(string: "https://open.weixin.qq.com/connect/qrconnect")
        components?.queryItems = [
            URLQueryItem(name: "appid", value: appId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "snsapi_login"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let base = components?.url?.absoluteString else { return nil }
        return URL(string: base + "#wechat_redirect")
    }

    static func googleURL(clientId: String, redirect: String, state: String, nonce: String, challenge: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    private static func failure(_ error: Error?) -> AuthFailure {
        let ns = error as NSError?
        if ns?.domain == ASWebAuthenticationSessionError.errorDomain,
           ns?.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
            return AuthFailure(message: "已取消登录")
        }
        return AuthFailure(message: "授权没有完成")
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func once(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

private final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? UIWindow()
    }
}

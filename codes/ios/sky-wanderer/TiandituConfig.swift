import Foundation

/// Tianditu key and map-approval number. Both come from the app's Info.plist,
/// filled by the `TIANDITU_TK` / `TIANDITU_APPROVAL_NUMBER` build settings.
/// A real key stays in a gitignored xcconfig or a local override. Never log it.
enum TiandituConfig {
    /// Shown when the approval number has not been set. Not a real 审图号.
    static let pendingApproval = "审图号待配置"

    static var token: String {
        sanitized(Bundle.main.object(forInfoDictionaryKey: "TIANDITU_TK") as? String)
    }

    static var approvalNumber: String {
        sanitized(Bundle.main.object(forInfoDictionaryKey: "TIANDITU_APPROVAL_NUMBER") as? String)
    }

    static var credit: String {
        let number = approvalNumber.isEmpty ? pendingApproval : approvalNumber
        return "天地图 · \(number)"
    }

    private static func sanitized(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.contains("$(") { return "" }
        return trimmed
    }
}

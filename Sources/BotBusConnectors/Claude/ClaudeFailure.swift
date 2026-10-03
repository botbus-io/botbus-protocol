import Foundation
import BotBusProtocol

/// Claude Code 失败时的原话 → 协议 3.7 的诊断。只认见过的原话，认不出给 nil。
/// 登录那两组与手机端 ClientCore 的 `AgentSignIn` 同一份（手机留着它给没有诊断的旧电脑兜底），改一边要改另一边。
///
/// **只喂错误原文**（StopFailure 的 `error_details`、报错的 `result` 行），不喂 agent 自己说的话：
/// 回复里谈到「not logged in」「limit reached … resets」很平常，拿它分类会给出假原因。
enum ClaudeFailure {
    static let notSignedInMarkers = ["not logged in", "please run /login", "invalid api key"]
    /// 先于上一组比：失效的提示里也可能带 `Please run /login`。
    static let expiredMarkers = ["oauth token has expired", "oauth access token has been revoked",
                                 "authentication_error", "failed to authenticate"]
    static let usageLimitMarkers = ["usage limit reached", "hit your limit", "rate_limit_error"]

    /// `StopFailure` hook：先看结构化的类别（`error`）——限流、账单 → 额度，鉴权失败再按详情分失效还是没登录；
    /// 没有类别才看错误原文（`error_details`）。别的类别（`server_error`、`invalid_request`……）与认不出的类别不下结论。
    static func diagnosis(category: String?, details: String?) -> FailureDiagnosis? {
        switch category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "":
            return diagnosis(details)
        case "rate_limit", "billing_error":
            return .usageLimit(resetsAt: details.flatMap(resetTime))
        case "authentication_failed":
            return signIn(details) ?? .notSignedIn
        default:
            return nil
        }
    }

    static func diagnosis(_ text: String?) -> FailureDiagnosis? {
        guard let text, !text.isEmpty else { return nil }
        if let signIn = signIn(text) { return signIn }
        let lowered = text.lowercased()
        if usageLimitMarkers.contains(where: lowered.contains)
            || (lowered.contains("limit reached") && lowered.contains("resets")) {
            return .usageLimit(resetsAt: resetTime(text))
        }
        return nil
    }

    /// 只按登录那两组原话分。
    private static func signIn(_ text: String?) -> FailureDiagnosis? {
        guard let lowered = text?.lowercased(), !lowered.isEmpty else { return nil }
        if expiredMarkers.contains(where: lowered.contains) { return .signInExpired }
        if notSignedInMarkers.contains(where: lowered.contains) { return .notSignedIn }
        return nil
    }

    /// `Claude AI usage limit reached|1791043200`：竖线后面是恢复时间的 Unix 秒。
    static func resetTime(_ text: String) -> String? {
        guard let bar = text.lastIndex(of: "|") else { return nil }
        let digits = text[text.index(after: bar)...].prefix(while: \.isNumber)
        guard digits.count >= 9, let seconds = TimeInterval(digits) else { return nil }
        return ProtocolJSON.timestamp(Date(timeIntervalSince1970: seconds))
    }
}

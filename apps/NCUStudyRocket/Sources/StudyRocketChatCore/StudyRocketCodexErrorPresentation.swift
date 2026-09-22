import Foundation

/// Converts Codex transport failures into text that is safe to show in either
/// StudyRocket client. The app-server can echo credential fragments in an
/// upstream authentication error, so raw errors must not cross this boundary.
public enum StudyRocketCodexErrorPresentation {
    public static let authenticationFailureMessage = "Codex 身份验证已失效。请在 Mac 上重新登录 Codex，然后重新打开 StudyRocket Host。"

    private static let credentialOverrideKeys: Set<String> = [
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_ORG_ID",
        "OPENAI_ORGANIZATION",
        "OPENAI_PROJECT",
        "CODEX_API_KEY",
        "CODEX_BASE_URL"
    ]

    /// These are bindings for the Codex process that happened to launch the
    /// app.  A StudyRocket Host app-server owns a separate fixed academic
    /// task, so inheriting them can route its dynamic tools into that caller.
    private static let taskBoundCodexRuntimeKeys: Set<String> = [
        "CODEX_APP_TOOLS_PIPE_PATH",
        "CODEX_CI",
        "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
        "CODEX_MCP_NODE_PATH",
        "CODEX_PERMISSION_PROFILE",
        "CODEX_SAGE_BACKFILL_TRACKER_TAB_REUSE",
        "CODEX_SESSION_ID",
        "CODEX_SHELL",
        "CODEX_THREAD_ID",
        "CODEX_VERSION"
    ]

    private static let directCredentialPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:sk|rk|sess|token)-[A-Za-z0-9_-]{4,}\b"#
    )
    private static let bearerCredentialPattern = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~-]+"#
    )
    private static let namedCredentialPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:api[_-]?key|access[_-]?token)\s*[:=]\s*[^\s,;]+"#
    )

    public static func message(for rawMessage: String?, fallback: String = "学业对话未能完成，请重试。") -> String {
        guard let rawMessage else { return fallback }
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return fallback }

        if isAuthenticationFailure(rawMessage) {
            return authenticationFailureMessage
        }

        return redactCredentials(in: message)
    }

    public static func isAuthenticationFailure(_ rawMessage: String?) -> Bool {
        let normalized = rawMessage?.lowercased() ?? ""
        return normalized.contains("invalid_api_key")
            || normalized.contains("invalid api key")
            || normalized.contains("incorrect api key")
            || normalized.contains("api key")
            || normalized.contains("auth error")
            || normalized.contains("authentication")
            || normalized.contains("unauthorized")
            || normalized.contains("401")
    }

    /// Direct API credentials and endpoint overrides must not shadow the
    /// user's normal Codex login. Keep login material such as
    /// `CODEX_ACCESS_TOKEN`, but do not inherit a caller's task-bound runtime
    /// channels into the Host's separate app-server.
    public static func childProcessEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment.filter {
            let key = $0.key.uppercased()
            return !credentialOverrideKeys.contains(key)
                && !taskBoundCodexRuntimeKeys.contains(key)
        }
    }

    private static func redactCredentials(in message: String) -> String {
        let fullRange = NSRange(message.startIndex..., in: message)
        let withoutDirectCredential = directCredentialPattern.stringByReplacingMatches(
            in: message,
            range: fullRange,
            withTemplate: "[凭据已隐藏]"
        )
        let bearerRange = NSRange(withoutDirectCredential.startIndex..., in: withoutDirectCredential)
        let withoutBearerCredential = bearerCredentialPattern.stringByReplacingMatches(
            in: withoutDirectCredential,
            range: bearerRange,
            withTemplate: "Bearer [凭据已隐藏]"
        )
        let namedRange = NSRange(withoutBearerCredential.startIndex..., in: withoutBearerCredential)
        return namedCredentialPattern.stringByReplacingMatches(
            in: withoutBearerCredential,
            range: namedRange,
            withTemplate: "api_key=[凭据已隐藏]"
        )
    }
}

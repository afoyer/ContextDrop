import Foundation

/// Hides anything that looks like a secret before text about a Claude Code run leaves this Mac for a room.
/// It errs on the side of hiding: a masked harmless value costs nothing, a leaked key does.
enum SecretMasker {
    static let mask = "••••••"

    /// Whole-token shapes: provider keys, access tokens, JWTs, private key blocks.
    private static let tokenPatterns: [NSRegularExpression] = [
        #"\bsk-[A-Za-z0-9_\-]{8,}"#,                                  // OpenAI, Anthropic (sk-ant-…), Stripe-like
        #"\b(?:rk|pk)_(?:live|test)_[A-Za-z0-9]{8,}"#,                // Stripe
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,                             // GitHub
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,                          // Slack
        #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,                            // AWS access key id
        #"\bAIza[A-Za-z0-9_\-]{30,}"#,                                // Google API key
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}"#, // JWT
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        #"\b[A-Fa-f0-9]{40,}\b"#,                                     // long hex (tokens, hashes of secrets)
    ].map { try! NSRegularExpression(pattern: $0) }

    /// "Bearer xyz" / "Authorization: xyz": keep the word, hide the value.
    private static let bearer = try! NSRegularExpression(
        pattern: #"(?i)\b(bearer|basic|authorization:?)\s+([A-Za-z0-9._~+/=\-]{8,})"#)

    /// `NAME=value`, `NAME: value`, `"name": "value"` where the name says it is a secret.
    private static let assignment = try! NSRegularExpression(
        pattern: #"(?i)\b([A-Za-z0-9_.\-]*(?:api[_\-]?key|secret|token|passwd|password|pwd|credential|private[_\-]?key|access[_\-]?key)[A-Za-z0-9_.\-]*)("?\s*[=:]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;"']+)"#)

    /// Any `NAME=value` line, for text known to come from a `.env` file.
    private static let envLine = try! NSRegularExpression(
        pattern: #"(?m)^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*)(\S.*)$"#)

    /// URLs with credentials: scheme://user:password@host
    private static let urlCredentials = try! NSRegularExpression(pattern: #"(://[^\s/:@]+:)([^\s/@]+)(@)"#)

    /// `envFile` masks every assignment, for lines that mention or come from a `.env` file.
    static func mask(_ text: String, envFile: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = replace(assignment, in: result, with: "$1$2\(mask)")
        if envFile || looksLikeEnv(text) { result = replace(envLine, in: result, with: "$1\(mask)") }
        result = replace(bearer, in: result, with: "$1 \(mask)")
        result = replace(urlCredentials, in: result, with: "$1\(mask)$3")
        for pattern in tokenPatterns { result = replace(pattern, in: result, with: mask) }
        return result
    }

    /// The line talks about a .env file (e.g. `cat .env`, `Read .env.local`), so what follows may be its values.
    static func looksLikeEnv(_ text: String) -> Bool {
        text.range(of: #"(^|[\s/"'])\.env(\.[A-Za-z0-9_\-]+)?($|[\s"':])"#, options: .regularExpression) != nil
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    #if DEBUG
    /// `-ContextDrop.selfCheck YES` at launch runs this and logs the result.
    static func selfCheck() -> [String] {
        let fakeKey = "sk-" + String(repeating: "a1B2", count: 8)
        let cases: [(input: String, secret: String)] = [
            ("OPENAI_API_KEY=\(fakeKey)", fakeKey),
            ("export GITHUB_TOKEN=ghp_" + String(repeating: "x", count: 36), "ghp_xxxx"),
            ("curl -H \"Authorization: Bearer abcdef1234567890\" https://example.com", "abcdef1234567890"),
            ("db_password: \"hunter2-very-secret\"", "hunter2"),
            ("postgres://admin:s3cretpass@db.local/app", "s3cretpass"),
            ("Compiling… \(fakeKey) done", fakeKey),
            ("AKIAIOSFODNN7EXAMPLE in config", "AKIAIOSFODNN7EXAMPLE"),
        ]
        var failures: [String] = []
        for (input, secret) in cases where mask(input).contains(secret) { failures.append(input) }
        if mask("FOO=bar", envFile: true).contains("bar") { failures.append("env line") }
        if mask("Edit Views/DecisionCard.swift +18") != "Edit Views/DecisionCard.swift +18" { failures.append("over-masking a plain line") }
        return failures
    }
    #endif
}

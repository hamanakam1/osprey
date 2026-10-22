import Foundation

/// Removes secrets and terminal noise before anything is written to disk.
///
/// Osprey stores evidence locally, but "local" is not "safe": a terminal screen
/// can hold a token. Redaction runs on every captured chunk, and the number of
/// replacements is reported so the operator can see that something was removed.
public struct Redactor: Sendable {
    public struct Rule: Sendable {
        public let name: String
        public let pattern: NSRegularExpression
        /// An optional replacement template. `$1` keeps a captured group.
        public let template: String?
    }

    /// Every rule replaces the match with a stable marker. The marker names the
    /// rule, never the secret, and never its length.
    public let rules: [Rule]
    public private(set) var replacements: Int = 0

    public init() {
        rules = [
            Self.rule("private-key", "-----BEGIN[ A-Z]*PRIVATE KEY-----[\\s\\S]*?-----END[ A-Z]*PRIVATE KEY-----"),
            Self.rule("github-token", "gh[pousr]_[A-Za-z0-9]{16,255}"),
            Self.rule("openai-key", "sk-[A-Za-z0-9_-]{20,}"),
            Self.rule("anthropic-key", "sk-ant-[A-Za-z0-9_-]{20,}"),
            Self.rule("aws-access-key", "AKIA[0-9A-Z]{16}"),
            Self.rule("google-api-key", "AIza[0-9A-Za-z_-]{35}"),
            Self.rule("slack-token", "xox[baprs]-[A-Za-z0-9-]{10,}"),
            Self.rule("jwt", "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"),
            Self.rule("bearer-token", "(?i)bearer\\s+[A-Za-z0-9._~+/=-]{16,}"),
            Self.rule("authorization-header", "(?i)authorization:\\s*[^\\r\\n]{8,}"),
            Self.rule("assigned-secret", "(?i)\\b(api[_-]?key|secret|passwd|password|token)\\b\\s*[:=]\\s*[\"']?[^\\s\"']{6,}"),
            Self.rule("basic-auth-url", "(?i)\\b([a-z][a-z0-9+.-]*://)[^\\s/@:]+:[^\\s/@]+@", template: "$1[basic-auth-url REDACTED]@"),
        ].compactMap { $0 }
    }

    /// Compiles a rule, or returns nothing when the pattern is not usable.
    /// A broken pattern must never take the process down.
    private static func rule(_ name: String, _ pattern: String, template: String? = nil) -> Rule? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        return Rule(name: name, pattern: expression, template: template)
    }

    public mutating func reset() { replacements = 0 }

    /// Strips ANSI escape sequences, then replaces secret-shaped text.
    ///
    /// Every rule is matched against the original text, not against the text
    /// produced by an earlier rule, so a marker can never be redacted twice.
    public mutating func redact(_ input: String) -> String {
        let plain = Self.stripANSI(input)
        let fullRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        var hits: [(range: NSRange, replacement: String)] = []

        for rule in rules {
            for match in rule.pattern.matches(in: plain, options: [], range: fullRange) {
                var replacement = "[\(rule.name) REDACTED]"
                if let template = rule.template {
                    replacement = Self.expand(template: template, match: match, in: plain as NSString)
                }
                hits.append((match.range, replacement))
            }
        }

        // Earlier rules win where two rules overlap.
        hits.sort { $0.range.location < $1.range.location }
        var result = ""
        var cursor = plain.startIndex
        var consumed = 0
        for hit in hits {
            guard let range = Range(hit.range, in: plain) else { continue }
            guard range.lowerBound >= cursor else { continue }
            result += plain[cursor..<range.lowerBound]
            result += hit.replacement
            cursor = range.upperBound
            consumed += 1
        }
        result += plain[cursor...]
        replacements += consumed
        return result
    }

    /// Removes ANSI CSI/OSC sequences so captured text is readable and compact.
    public static func stripANSI(_ input: String) -> String {
        let pattern = "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)|\\x1B\\[[0-9;?]*[ -/]*[@-~]|\\x1B[@-Z\\x5C-_]"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return expression.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    /// Expands `$1` to `$9` in a replacement template using a match's groups.
    private static func expand(template: String, match: NSTextCheckingResult, in text: NSString) -> String {
        var output = ""
        var characters = Array(template)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "$", index + 1 < characters.count {
                let next = characters[index + 1]
                if let group = next.wholeNumberValue, group >= 1, group <= 9 {
                    let range = match.range(at: group)
                    if range.location != NSNotFound {
                        output += text.substring(with: range)
                    }
                    index += 2
                    continue
                }
                if next == "$" {
                    output.append("$")
                    index += 2
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// Extracts shell-looking commands from captured output.
    /// This is a heuristic for drafting a summary, not a verified command log.
    public static func commandCandidates(in text: String) -> [String] {
        var found: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // A prompt line is the strongest hint that a command was run.
            if trimmed.hasPrefix("$ ") {
                trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard trimmed.count >= 3, trimmed.count <= 240 else { continue }
            let heads = ["git ", "npm ", "pnpm ", "yarn ", "python3 ", "python ", "make ", "cargo ", "swift ", "go ", "docker ", "kubectl ", "psql ", "sqlite3 ", "pytest ", "npm test", "cd ", "ls ", "rg ", "grep "]
            guard heads.contains(where: { trimmed.hasPrefix($0) }) else { continue }
            if found.last != trimmed { found.append(trimmed) }
            if found.count >= 40 { break }
        }
        return found
    }

    /// Extracts lines that look like a failure worth recording.
    public static func failureCandidates(in text: String) -> [String] {
        var found: [String] = []
        let markers = ["error:", "Error:", "fatal:", "FAILED", "Traceback (most recent call last)", "panic:", "command not found", "Permission denied", "exit code 1"]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 8, trimmed.count <= 240 else { continue }
            guard markers.contains(where: { trimmed.contains($0) }) else { continue }
            if found.last != trimmed { found.append(trimmed) }
            if found.count >= 20 { break }
        }
        return found
    }
}

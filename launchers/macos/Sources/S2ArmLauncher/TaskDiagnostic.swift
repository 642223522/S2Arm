// UI adapted from LumaDock (MIT); see ../../README.md.
import Foundation

struct TaskDiagnostic: Codable, Identifiable, Equatable {
    var code: String
    var severity: String
    var summary: String
    var suggestion: String
    var detail: String
    var stage: String?
    var logPath: String?
    var component: String?
    var exitCode: Int?
    var id: String { code + "|" + (logPath ?? "") + "|" + (stage ?? "") + "|" + summary }
    var isWarning: Bool { severity == "warning" }
    static func redact(_ text: String, paths: [(String,String)]) -> String {
        var result=redactIdentityAssignments(text).replacingOccurrences(of:#"(?i)(authorization\s*:\s*(?:bearer|basic|token)\s+)\S+"#,with:"$1[REDACTED]",options:.regularExpression)
        result=result.replacingOccurrences(of:#"(?i)(https?://)[^/\s:@]+:[^/\s@]+@"#,with:"$1[REDACTED]@",options:.regularExpression)
        // 带引号的值只换引号内、保留引号（JSON / plist 脱敏后还能解析）；闭引号后拖着的残值（password="a"b）一并吞掉；同 tools/redact.py（test/pr64 33fb6895）
        let assign=#"(?i)([\w-]*(?:key|kek|seed|secret|token|password|udid|uuid|serial)[\w-]*["']?\s*[=:]\s*)"#
        result=result.replacingOccurrences(of:assign+#""(?:\\.|[^"\\])*"[^\s,;}\]]*"#,with:"$1\"[REDACTED]\"",options:.regularExpression)
        result=result.replacingOccurrences(of:assign+#"'(?:\\.|[^'\\])*'[^\s,;}\]]*"#,with:"$1'[REDACTED]'",options:.regularExpression)
        result=result.replacingOccurrences(of:assign+#"(?!["']\[REDACTED\])(["']?)[^\s,;]+"#,with:"$1$2[REDACTED]",options:.regularExpression)
        result=result.replacingOccurrences(of:#"(?im)^([ \t]*[0-9a-f]{32}[ \t]*=[ \t]*)[0-9a-f]{32}(?=[ \t\r]*(?:#.*)?$)"#,with:"$1[REDACTED]",options:.regularExpression)
        result=result.replacingOccurrences(of:#"\b[0-9a-fA-F]{64,}\b"#,with:"[REDACTED]",options:.regularExpression)
        // 与 tools/redact.py 的身份规则及 tests/fixtures/redact_cases.tsv 同序。
        let identityRules: [(String, String)] = [
            (#"(?i)((?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])(?:contact|email|mail|from|to|reply[_-]?to|user)["']?[ \t]*[:=][ \t]*["']?)[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])"#, "$1[EMAIL]"),
            (#"(?i)(?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])"#, "[EMAIL]"),
            (#"(?i)(\bDEVELOPMENT_TEAM[ \t]*=[ \t]*["']?|\bSigning[ \t]+with[ \t]+team[ \t]+)(?<![A-Z0-9])[A-Z0-9]{10}(?![A-Z0-9])"#, "$1[TEAM_ID]"),
            (#"(?i)(?<![A-Z0-9])(s2arm\.)[A-Z0-9]{10}(\.[A-F0-9]{16})(?![A-Z0-9])"#, "$1[TEAM_ID]$2"),
            (#"(?i)(?<![A-Z0-9])[A-F0-9]{8}-[A-F0-9]{16}(?![A-Z0-9])"#, "[DEVICE_ID]")
        ]
        for (pattern, replacement) in identityRules {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // 旧式 UDID 仅认同一物理行的设备上下文，保留无上下文的 git SHA。
        // 逆序替换 UTF-16 区间，保留 CR、LF 与 CRLF，不影响后续区间。
        let lines = try! NSRegularExpression(pattern: #"[^\r\n]+"#)
        let original = result as NSString
        for match in lines.matches(in: result, range: NSRange(location: 0, length: original.length)).reversed() {
            let line = original.substring(with: match.range)
            if line.range(of: #"(?i)\b(?:udid|device|serial)\b"#, options: .regularExpression) != nil {
                let redacted = line.replacingOccurrences(of: #"(?i)(?<![A-Z0-9])[A-F0-9]{40}(?![A-Z0-9])"#,
                                                        with: "[DEVICE_ID]", options: .regularExpression)
                result = (result as NSString).replacingCharacters(in: match.range, with: redacted)
            }
        }
        result = result.replacingOccurrences(of: #"[^\s"'<>:=,;{}\[\]，。]+的(iPhone|iPad)"#,
                                            with: "[DEVICE_NAME]的$1", options: .regularExpression)
        for (path,label) in paths where !path.isEmpty {result=result.replacingOccurrences(of:path,with:label)}
        return String(result.suffix(3000))
    }
    // Match the Python scanner: escaped quotes, adjacent fragments and truncated lines.
    private static func redactIdentityAssignments(_ text: String) -> String {
        let pattern = #"(?i)(?<![A-Z0-9_.-])["']?(?:udid|uuid|serial(?:number)?|device[_-]?id)["']?[ \t]*[:=][ \t]*"#
        guard let keys = try? NSRegularExpression(pattern: pattern) else { return "[REDACTED]" }
        let source = text as NSString
        var result = "", cursor = 0
        for match in keys.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if NSMaxRange(match.range) <= cursor { continue }
            let start = NSMaxRange(match.range)
            let first = start < source.length ? source.character(at: start) : 0
            let quoted = first == 34 || first == 39
            var quote: unichar = quoted ? first : 0
            var end = start + (quoted ? 1 : 0)
            while end < source.length {
                let c = source.character(at: end)
                if c == 10 || c == 13 { break }
                if quote != 0 {
                    if c == 92 {
                        end += 1
                        if end < source.length && source.character(at: end) != 10 && source.character(at: end) != 13 { end += 1 }
                    } else {
                        if c == quote { quote = 0 }
                        end += 1
                    }
                } else if c == 34 || c == 39 {
                    quote = c; end += 1
                } else if (UnicodeScalar(c).map { CharacterSet.whitespaces.contains($0) } ?? false) || [44, 59, 125].contains(c) || (quoted && c == 93) {
                    break
                } else { end += 1 }
            }
            if end > start {
                result += source.substring(with: NSRange(location: cursor, length: start - cursor))
                let mark = quoted ? (first == 34 ? "\"" : "'") : ""
                result += mark + "[REDACTED]" + (quoted && quote == 0 ? mark : "")
                cursor = end
            }
        }
        return result + source.substring(from: cursor)
    }
    var reportText: String {
        var lines = [L(summary), L("错误代码：") + code]
        if let stage, !stage.isEmpty { lines.append(L("失败阶段：") + L(stage)) }
        if let component { lines.append(L("组件：") + component) }
        if let exitCode { lines.append(L("退出码：") + String(exitCode)) }
        lines.append(L("建议处理：") + L(suggestion))
        if !detail.isEmpty { lines.append(detail) }
        return lines.joined(separator:"\n")
    }
}

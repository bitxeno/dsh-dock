import Foundation

/// shell-like 切分：支持单/双引号与反斜杠转义。
/// 例：`--verbose --data-dir "~/a b"` -> ["--verbose", "--data-dir", "~/a b"]
func shellSplit(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var inSingle = false
    var inDouble = false
    var escaped = false
    var hasToken = false

    for ch in s {
        if escaped {
            cur.append(ch)
            escaped = false
            hasToken = true
            continue
        }
        if ch == "\\" && !inSingle {
            escaped = true
            hasToken = true
            continue
        }
        if ch == "'" && !inDouble {
            inSingle.toggle()
            hasToken = true
            continue
        }
        if ch == "\"" && !inSingle {
            inDouble.toggle()
            hasToken = true
            continue
        }
        if ch.isWhitespace && !inSingle && !inDouble {
            if hasToken {
                out.append(cur)
                cur = ""
                hasToken = false
            }
            continue
        }
        cur.append(ch)
        hasToken = true
    }
    if hasToken { out.append(cur) }
    return out
}

/// 去掉 App 拥有的参数，避免双端口/双 web：
/// 移除独立的 `web`、`--no-open`，以及 `--port/-p/--bind*/--host` 及其值，
/// 还有 `--port=123` 这类等号形态。返回 (清洗后, 被 strip 掉的)。
func stripOwnedArgs(_ args: [String]) -> (cleaned: [String], stripped: [String]) {
    var cleaned: [String] = []
    var stripped: [String] = []
    var i = 0
    let valueFlags: Set<String> = ["--port", "-p", "--bind", "--bind-address", "--host"]
    while i < args.count {
        let a = args[i]
        if a == "web" || a == "--no-open" {
            stripped.append(a)
            i += 1
            continue
        }
        if a.hasPrefix("--port=") || a.hasPrefix("-p=") || a.hasPrefix("--bind=") {
            stripped.append(a)
            i += 1
            continue
        }
        if valueFlags.contains(a) {
            stripped.append(a)
            i += 1
            if i < args.count {
                stripped.append(args[i])
                i += 1
            }
            continue
        }
        cleaned.append(a)
        i += 1
    }
    return (cleaned, stripped)
}

/// 单个 shell 转义，用于诊断命令复制。
func shellEscape(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func shellJoin(_ args: [String]) -> String {
    args.map(shellEscape).joined(separator: " ")
}

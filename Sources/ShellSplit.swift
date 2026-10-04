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

/// 摘出 launcher 级 `--profile <name>`（含 `--profile=<name>` 等号形态）。
/// `dsh web` 等价于 `dsh --profile web`，用户在 extra 里显式给了 profile 时必须
/// 替换 App 默认注入的 `web`，且要挪到 app-args 之前——实测：`dsh web … --profile x`
/// 报 `unknown option '--profile'`，`dsh --no-open … --profile x` 报
/// `--profile <name> is required`（launcher 自家 flag 只认 `<name>` 之前的位置）。
/// 多个 `--profile` 取最后一个；缺值的残缺形态丢弃，避免 commander 报 argument missing。
/// 返回 (profile 段（含 `--profile` 本体，无则空数组）, 摘除后的剩余参数)。
func extractProfileArgs(_ args: [String]) -> (profile: [String], rest: [String]) {
    var profile: [String] = []
    var rest: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--profile" {
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                profile = ["--profile", args[i + 1]]
                i += 2
            } else {
                i += 1
            }
            continue
        }
        if a.hasPrefix("--profile=") {
            let name = String(a.dropFirst("--profile=".count))
            if !name.isEmpty && !name.hasPrefix("-") {
                profile = ["--profile", name]
            }
            i += 1
            continue
        }
        rest.append(a)
        i += 1
    }
    return (profile, rest)
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

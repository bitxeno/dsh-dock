import Foundation

/// 解析结果：可执行文件 + 固定前缀参数（npx 场景）。
struct ResolvedLaunch {
    /// 显示给用户看的 provider 文案。
    let displayName: String
    let executableURL: URL
    /// npx 场景为 ["--yes", "@deepseek-ai/dsh"]，dsh 场景为空。
    let prefixArgs: [String]
    let isNpx: Bool
}

/// 三级供给链（Q19）：自定义 > dsh > npx。
enum BinaryResolver {
    static let dshFixed = [
        "/opt/homebrew/bin/dsh",
        "/usr/local/bin/dsh",
    ]
    static let npxFixed = [
        "/opt/homebrew/bin/npx",
        "/usr/local/bin/npx",
    ]
    static let npmPackage = "@deepseek-ai/dsh"

    static func homeFixed(_ name: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(name)").path
    }

    /// 同步跑 login-shell 解析。GUI 从 Finder 启动时 PATH 残缺，必须走这条。
    static func loginShellWhich(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "which \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// login-shell 的 PATH，用于透传给子进程。
    static func loginShellPATH() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.isEmpty ? nil : s
    }

    static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// 解析配置的 binary。返回 (launch, 已搜索路径)。
    /// 约定：非默认 binary（用户显式改过）解析失败时不 fallback，直接返回 nil，让 UI 进缺失页。
    static func resolve(configuredBinary: String) -> (launch: ResolvedLaunch?, searched: [String]) {
        var searched: [String] = []
        let trimmed = configuredBinary.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? DshConfig.defaultBinary : trimmed

        // 1) 用户自定义（非默认）：最高优，不 fallback。
        if effective != DshConfig.defaultBinary {
            if effective.contains("/") {
                searched.append(effective)
                if isExecutable(effective) {
                    return (ResolvedLaunch(displayName: "自定义：\(effective)",
                                           executableURL: URL(fileURLWithPath: effective),
                                           prefixArgs: [], isNpx: false), searched)
                }
                return (nil, searched)
            }
            if let found = loginShellWhich(effective) {
                searched.append("login-shell which \(effective) -> \(found)")
                return (ResolvedLaunch(displayName: "自定义：\(found)",
                                       executableURL: URL(fileURLWithPath: found),
                                       prefixArgs: [], isNpx: false), searched)
            }
            searched.append("login-shell which \(effective)（未找到）")
            return (nil, searched)
        }

        // 2) 默认 dsh 链。
        if let found = loginShellWhich("dsh") {
            searched.append("login-shell which dsh -> \(found)")
            return (ResolvedLaunch(displayName: "dsh：\(found)",
                                   executableURL: URL(fileURLWithPath: found),
                                   prefixArgs: [], isNpx: false), searched)
        }
        searched.append("login-shell which dsh（未找到）")
        for c in dshFixed + [homeFixed("dsh")] {
            searched.append(c)
            if isExecutable(c) {
                return (ResolvedLaunch(displayName: "dsh：\(c)",
                                       executableURL: URL(fileURLWithPath: c),
                                       prefixArgs: [], isNpx: false), searched)
            }
        }

        // 3) npx fallback（Q18/Q20，必须 --yes）。
        if let npx = loginShellWhich("npx") {
            searched.append("login-shell which npx -> \(npx)")
            return (ResolvedLaunch(displayName: "npx：\(npx) \(npmPackage)",
                                   executableURL: URL(fileURLWithPath: npx),
                                   prefixArgs: ["--yes", npmPackage], isNpx: true), searched)
        }
        searched.append("login-shell which npx（未找到）")
        for c in npxFixed + [homeFixed("npx")] {
            searched.append(c)
            if isExecutable(c) {
                return (ResolvedLaunch(displayName: "npx：\(c) \(npmPackage)",
                                       executableURL: URL(fileURLWithPath: c),
                                       prefixArgs: ["--yes", npmPackage], isNpx: true), searched)
            }
        }
        return (nil, searched)
    }
}

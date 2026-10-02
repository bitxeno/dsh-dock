import Foundation

/// App 级偏好（区别于 dsh 启动三元组，不进设置表单、不随 onApply 保存）。
enum AppPreferences {
    private static let kInterceptRestart = "app.interceptPluginRestart"

    /// 插件"立即重启"是否由 App 接管（默认开）。关闭后放行真实请求，
    /// 由 dsh-market 自带的 detached 助手重启（App 侧会看到进程意外退出）。
    static var interceptPluginRestart: Bool {
        get { UserDefaults.standard.object(forKey: kInterceptRestart) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: kInterceptRestart) }
    }
}

/// 设置模型：Binary Path + Extra Args + Port（三段式，Q3/Q21）。
struct DshConfig: Equatable {
    var binaryPath: String
    var extraArgs: String
    var port: Int

    static let defaultBinary = "dsh"
    static let defaultExtra = ""
    static let defaultPort = 38811

    private static let kBinary = "dsh.binaryPath"
    private static let kExtra = "dsh.extraArgs"
    private static let kPort = "dsh.port"

    static func load() -> DshConfig {
        let d = UserDefaults.standard
        d.register(defaults: [
            kBinary: defaultBinary,
            kExtra: defaultExtra,
            kPort: defaultPort,
        ])
        let binary = (d.string(forKey: kBinary) ?? defaultBinary).trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = d.string(forKey: kExtra) ?? defaultExtra
        var port = d.integer(forKey: kPort)
        if port == 0 { port = defaultPort }
        return DshConfig(
            binaryPath: binary.isEmpty ? defaultBinary : binary,
            extraArgs: extra,
            port: port
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(binaryPath, forKey: Self.kBinary)
        d.set(extraArgs, forKey: Self.kExtra)
        d.set(port, forKey: Self.kPort)
    }

    /// 返回错误文案数组，为空即合法。
    func validate() -> [String] {
        var errs: [String] = []
        if binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append("Binary Path 不能为空")
        }
        if port < 1 || port > 65535 {
            errs.append("端口必须在 1–65535 之间")
        }
        return errs
    }
}

import Foundation

/// App 级偏好（区别于 dsh 启动三元组，不进设置表单、不随 onApply 保存）。
enum AppPreferences {
    private static let kInterceptRestart = "app.interceptPluginRestart"
    private static let kNotifyBackend = "app.notifyBackend"

    /// 插件"立即重启"是否由 App 接管（默认开）。关闭后放行真实请求，
    /// 由 dsh-market 自带的 detached 助手重启（App 侧会看到进程意外退出）。
    static var interceptPluginRestart: Bool {
        get { UserDefaults.standard.object(forKey: kInterceptRestart) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: kInterceptRestart) }
    }

    /// 通知后端：notch = 刘海悬窗（默认，免系统授权），system = 原生通知中心。
    static var notifyBackend: NotifyBackend {
        get {
            let raw = UserDefaults.standard.string(forKey: kNotifyBackend) ?? NotifyBackend.notch.rawValue
            return NotifyBackend(rawValue: raw) ?? .notch
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: kNotifyBackend) }
    }
}

/// 通知后端（存 UserDefaults `app.notifyBackend`，默认 notch）。
enum NotifyBackend: String, CaseIterable {
    case notch
    case system

    var title: String {
        switch self {
        case .notch: return "刘海悬窗"
        case .system: return "系统通知"
        }
    }

    var subtitle: String {
        switch self {
        case .notch: return "屏幕顶部悬窗呈现，无需系统授权（默认）"
        case .system: return "走通知中心，可留底、可点按钮裁决"
        }
    }

    /// 是否经过 UNUserNotificationCenter（涉及系统授权弹窗）。
    var usesSystemCenter: Bool { self == .system }
    /// 是否点亮刘海悬窗。
    var usesNotch: Bool { self == .notch }
}

/// 设置模型：Binary Path + Extra Args + Port + DSH_HOME（高级，默认收起；Q3/Q21）。
struct DshConfig: Equatable {
    var binaryPath: String
    var extraArgs: String
    var port: Int
    /// "高级选项"里的 DSH_HOME：空 = 启动不注入该环境变量。
    var dshHome: String

    static let defaultBinary = "dsh"
    static let defaultExtra = ""
    static let defaultPort = 38811
    static let defaultDshHome = ""

    private static let kBinary = "dsh.binaryPath"
    private static let kExtra = "dsh.extraArgs"
    private static let kPort = "dsh.port"
    private static let kDshHome = "dsh.dshHome"

    static func load() -> DshConfig {
        let d = UserDefaults.standard
        d.register(defaults: [
            kBinary: defaultBinary,
            kExtra: defaultExtra,
            kPort: defaultPort,
            kDshHome: defaultDshHome,
        ])
        let binary = (d.string(forKey: kBinary) ?? defaultBinary).trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = d.string(forKey: kExtra) ?? defaultExtra
        let home = (d.string(forKey: kDshHome) ?? defaultDshHome).trimmingCharacters(in: .whitespacesAndNewlines)
        var port = d.integer(forKey: kPort)
        if port == 0 { port = defaultPort }
        return DshConfig(
            binaryPath: binary.isEmpty ? defaultBinary : binary,
            extraArgs: extra,
            port: port,
            dshHome: home
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(binaryPath, forKey: Self.kBinary)
        d.set(extraArgs, forKey: Self.kExtra)
        d.set(port, forKey: Self.kPort)
        d.set(dshHome, forKey: Self.kDshHome)
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
        if dshHome.contains("\n") || dshHome.contains("\r") {
            errs.append("DSH_HOME 不能包含换行")
        }
        return errs
    }
}

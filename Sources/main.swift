import Cocoa

// 单例守卫：必须在起 dsh 服务之前拦下第二个实例（避免双服务抢 38811 端口）。
// 命中已有实例时：发 reopen 通知让对方弹窗（红灯隐藏的窗口也能现身）、
// 尽力激活之，然后自己退出——本进程尚未创建窗口和服务，直接 exit 无需清理。
let app = NSApplication.shared
let dshBundleID = Bundle.main.bundleIdentifier ?? "com.xenori.dshdock"
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: dshBundleID)
    .first(where: { $0 != NSRunningApplication.current }) {
    NSLog("[DshDock] 已有实例运行中 (pid=%d)，激活后退出", existing.processIdentifier)
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.reopenNotification, object: nil, deliverImmediately: true)
    existing.activate()
    exit(0)
}

// 显式入口：@main 在无 MainMenu nib 时不会自动挂载 delegate，
// 这里手动创建并 run，避免 applicationDidFinishLaunching 永远不触发。
let delegate = AppDelegate()
app.delegate = delegate
app.run()

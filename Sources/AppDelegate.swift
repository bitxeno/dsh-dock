import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 第二实例通过分布式通知请求复活主窗口（单例守卫，见 main.swift）。
    static let reopenNotification = Notification.Name("com.xenori.dshdock.reopen")

    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(reopenFromSecondInstance),
            name: Self.reopenNotification, object: nil)
        setupMenu()
        windowController = MainWindowController()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reopenFromSecondInstance() {
        NSLog("[DshDock] 收到第二实例 reopen 通知，弹出主窗口")
        showMainWindow()
    }

    /// 必须 false：红灯只是 orderOut 隐藏，若为 true，藏起最后一个窗口会连带退出 App（实测）。
    /// 退出只走 Cmd+Q / 菜单 terminate。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock 点按：窗口被红灯隐藏后从这里重新打开。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[DshDock] applicationWillTerminate (graceful quit)")
        windowController?.terminateServiceForQuit()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func setupMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "关于 DshDock", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 DshDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // 文件菜单：只放真正可用的项（无文档模型，不加新建/打开/保存）。
        // 关闭窗口走 performClose → windowShouldClose，和红灯一样是隐藏而非退出。
        let fileItem = NSMenuItem()
        fileItem.title = "文件"
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 编辑菜单：Cmd+C/V/X/A/Z 走菜单快捷键分发，没有它 WebView 里粘贴无效。
        // action 挂 first responder（target nil），WKWebView 自己会响应 paste: 等。
        let editItem = NSMenuItem()
        editItem.title = "编辑"
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "恢复", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        viewItem.title = "显示"
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        let reload = NSMenuItem(title: "重新载入页面", action: #selector(MainWindowController.reloadWebView), keyEquivalent: "r")
        viewMenu.addItem(reload)

        NSApplication.shared.mainMenu = main
    }
}

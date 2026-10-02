import Cocoa

// 显式入口：@main 在无 MainMenu nib 时不会自动挂载 delegate，
// 这里手动创建并 run，避免 applicationDidFinishLaunching 永远不触发。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

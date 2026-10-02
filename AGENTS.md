# AGENTS.md — 给在此仓库工作的 AI Agent

## 唯一事实源

- `docs/DESIGN.md` 是 grill 三轮收敛的共享理解 + 实测修正，动手前先读它。
- 本文件只讲“怎么在这仓库里干活”，设计决策以 DESIGN 为准。

## 构建 / 验证（唯一正确姿势）

```bash
xcodegen generate   # 新增/删除 Sources 文件后必须跑，pbxproj 是生成物
xcodebuild -project DshDock.xcodeproj -scheme DshDock -configuration Debug build
```

- Swift 版本：`SWIFT_VERSION = 5.0`（刻意降档，避开 Swift 6 严格并发，改回去需全仓标注）。
- 冒烟：启动 App → `~/Library/Logs/com.xenori.dshdock/dsh.log` 应出现
  `启动 dsh：…` + `发现服务 URL（token）`；`curl` token URL 得 303，裸 `/` 得 401；
  退出 App 后端口关闭、无 `dsh web` 残留进程。
- 改完 UI/交互逻辑后，提示用户肉眼确认（工具有法替你看悬浮动画）。

## 红线（血的教训，都踩过）

1. **别手改 `DshDock.xcodeproj/` 和根目录 `Info.plist`**——都是 xcodegen 生成物
   （且未进 git），下次 `generate` 会覆盖——在 Xcode 里改工程设置同理。
   改工程只改 `project.yml`（ATS 等 plist 键走 `info.properties`），改代码只改
   `Sources/`；资源类（如 App 图标）放 `Sources/Assets.xcassets`，generate
   扫 `Sources/` 会自动收进 Resources phase 并注入 icon 键。
2. **入口是 `Sources/main.swift`，不是 `@main`**——无 MainMenu nib 时
   `@main` 的 delegate 永远挂不上（App 能启动但 `applicationDidFinishLaunching`
   不触发、无窗口）。别“顺手改回 @main”。
3. **WebView 必须加载 token URL，不能拼裸 URL**——`dsh web` 每次打印一次性
   `http://127.0.0.1:<port>/?token=…`（303 + `Set-Cookie: dsh-auth-*`，
   跟随重定向才 200）。裸 `/` 永远 401。token 解析在 `DshService.scanForServiceURL`，
   就绪探活用 2xx/3xx（别改回 `== 200`）。插件重启后的 `location.reload()` 会带
   旧 token——`decidePolicyFor` 里 token ≠ 当前 serviceURL 时取消并重载当前
   token URL（否则 401 白页）。
4. **WebView 必须 persistent DataStore**（`MainWindowController` 已配 `.default()`）——
   换 ephemeral 会掉 cookie 登录态，表现为 401。
5. **GUI 的 PATH 是残的**——终端能跑 `dsh` 不代表双击 App 能找到。
   解析必须走 `BinaryResolver.loginShellWhich`（`/bin/zsh -l -c`），别简化成
   `ProcessInfo.environment["PATH"]` 或写死路径。
6. **`npx` fallback 必须带 `--yes`**——GUI 无 stdin，缺它会假死在安装确认上。
7. `dsh web` 真实 flags：`--host / --no-open / --port / --trusted-host`
   （无 `-p` 简写；strip 逻辑多删一点无妨，少删会双端口）。改命令拼接前先
   `dsh web --help` 核对，别凭记忆编 flags。
8. dsh 退出码：SIGTERM 可干净退出（已验证），`stop(grace:)` 先 `terminate()`，
   5s 不死才 SIGKILL——别改成直接 SIGKILL。
9. `NSStackView` 的 `alignment` 默认是居中：纵向 stack  items 会横向居中，
   想要左对齐必须显式 `alignment = .leading`；横向 stack 上用 `.trailing`
   是非法值，会算出垃圾 frame——右对齐按钮用低 hugging 的 spacer 顶过去。
   改完布局先用无头小脚本（`swiftc` 编译单个 VC + `layoutSubtreeIfNeeded` 打印
   frame）验证，别靠肉眼猜。

10. NSTextView 当 `NSScrollView.documentView` 必须配 `isVerticallyResizable=true` +
    `autoresizingMask=[.width]` + `textContainer.widthTracksTextView=true`，否则
    documentView 停在零宽 frame，日志一行都画不出来（旧错误页实测）。

## 架构速览（改代码前看）

| 文件 | 职责 | 别把逻辑放错地方 |
|---|---|---|
| `main.swift` | 显式入口 + 单例守卫（重复启动 → 发 reopen 通知激活已有实例后 `exit(0)`，必须先于服务启动），挂载 delegate 后 `run()` | 除守卫外别加业务 |
| `AppDelegate.swift` | 菜单（文件：关闭 Cmd+W；编辑 Cmd+C/V/X/A/Z——无编辑菜单 WebView 里粘贴无效；显示 Cmd+R）、退出时 `terminateServiceForQuit()` | 窗口逻辑不在此 |
| `BinaryResolver.swift` | 三级供给链 + login-shell 解析，返回 `ResolvedLaunch` | 别在 Service 里手写 `which` |
| `DshService.swift` | Process 生命周期、token 解析、就绪轮询、restart、端口占用查询/强杀（lsof 绝对路径） | UI 不进 Service，回调走主线程闭包；`start()` 任何 throw 前先写日志（错误页详情读环 buffer，否则空白） |
| `LogStore.swift` | 线程安全：文件（5MB 轮转）+ 200 行环 buffer | 读日志只用 `tail(n)` |
| `DshConfig.swift` | UserDefaults + 默认值（`dsh`/空/`38811`）+ 校验 | 默认值改动要同步 DESIGN + README |
| `ShellSplit.swift` | shell 切分 / strip App 拥有参数 / `shellEscape` | 诊断命令必须经 `shellJoin` 转义 |
| `MainWindowController.swift` | 窗口、WebView（含导航策略：本地放行/外部扔浏览器/过期 token 纠正、插件重启接管钩子）、标题栏 accessory（右侧重启/接管开关/设置，28pt 默认高度，常显）、loading 页；错误/状态页委托给 StatusViewController | 进程操作调 Service，别直接 `Process()`（lsof 助手除外，且必须绝对路径）；**别换回 NSToolbar**（会撑高标题栏，见 DESIGN §8） |
| `StatusViewController.swift` | 错误/状态页（Chrome 断网页式全页布局：图形+大标题+灰色说明，左下按钮组、右缘"详情"展开日志/打开日志文件），回调 `onRetry/onForceKillAndRestart/onOpenLogFile` | 不碰 Process；占用进程查询/强杀走 `DshService` |
| `SettingsViewController.swift` | 设置表单（dsh 桌面端风格，无取消）+ 行内校验，只有 `onApply` | 保存后必须触发重启（Controller 负责） |

## 改动流程

1. 小改：直接改 `Sources/` → `xcodebuild build` → 有报错贴全量 `error:` 行。
2. 加文件：写 `Sources/` → `xcodegen generate` → `build`。
3. 改默认值/命令模型/供给链：先更新 `docs/DESIGN.md` 对应章节，再改代码，
   最后同步 `README.md`（三处默认值表要一致）。
4. 涉及 `dsh web` 行为假设（输出格式、状态码、flags）：先在终端实测
   （`dsh web --no-open --port <空闲端口>` + `curl`），再写代码，别猜。

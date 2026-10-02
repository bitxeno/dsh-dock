# DshDock — 开放设计文档

> AppKit + WKWebView 壳，托管运行 `dsh web --no-open`，主窗口即 WebView。
> 本文档是 grill 三轮收敛后的共享理解，可直接指导实施。V1 按非沙盒 Developer ID 分发做。

## 1. 目标与非目标

- 目标：双击即用，自动拉起本地 `dsh web` 服务并加载；顶部悬浮工具栏（重启/设置）；设置页可改启动命令与端口；重启保证旧进程正常退出；工具栏平时隐藏，鼠标到顶部才显。
- 非目标：Mac App Store 沙盒上架、MenuBar 常驻后台、多窗口多实例、完整浏览器 chrome（地址栏/多标签）、自动更新。

## 2. 技术栈与工程

- `Swift + AppKit + WKWebView`，全代码无 Storyboard，`@main AppDelegate`。
- BundleID：`com.xenori.dshdock`，App 名 `DshDock`，最低 `macOS 15.0`。
- 工程：`xcodegen` 生成 `DshDock.xcodeproj`（`project.yml` 为源），源码在 `Sources/`，无 `Resources/` 必需资源（图标后加）。
- 分发：Developer ID + 公证，不开 Sandbox（`com.apple.security.app-sandbox = false`）。若日后上架 MAS，托管 `Process` 方案需重做，此处记为 tech-debt。

## 3. 启动命令模型（Q3/Q8/Q13/Q21 闭环）

最终命令恒为：

```
<binary> web --no-open --port <port> <extra...>
```

- `binary`：设置页 `Binary Path`，默认 `dsh`（见 §4 解析）。
- `web --no-open --port <port>`：由 App 写死注入，不允许用户编辑。`extra` 中若含 `--port/-p/--bind/--bind-address`，启动前 strip 并在日志 +（可选）toast 提示“已忽略命令中的端口，以端口字段为准”。
- `extra`：设置页 `Extra Args` 字符串，默认空。做 shell-like 切分（支持单/双引号、`\` 转义），不用幼稚 `split(" ")`。占位符提示 `例如：--verbose --data-dir "~/a b"`。
- `port`：设置页数字字段，默认 `38811`，范围 `1–65535`。
- 默认三元组效果：`dsh web --no-open --port 38811`。
- npx 形态（见 §4）：`npx --yes @deepseek-ai/dsh web --no-open --port <port> <extra>`，端口/extra 规则完全一致。必须带 `--yes`，否则 GUI 无 stdin 会假死在安装确认上。

## 4. 二进制供给链（三级自动，Q1/Q7/Q19/Q20）

优先级从高到低：

1. 用户在设置页填了自定义 Binary 且可执行 → 直接用它，不 fallback。
2. login-shell 解析 `which dsh`：`/bin/zsh -l -c 'which dsh'`（GUI 从 Finder 启动时 PATH 残缺，必须走 login-shell），找不到再按序试 `/opt/homebrew/bin/dsh`、`/usr/local/bin/dsh`、`~/.local/bin/dsh`。
3. `npx --yes @deepseek-ai/dsh`（同样走 login-shell 解析 `npx`，找不到也按上面固定路径补）。

- 每次启动打日志：最终解析路径 + 用的哪一级，设置页显示当前 provider（`dsh: /opt/homebrew/bin/dsh` / `npx`）。
- 全失败 → 原生缺失页（见 §7），不进 WebView。缺失页文案含已搜索路径 + `npm install -g @deepseek-ai/dsh@latest` + `[打开设置]` `[复制诊断命令]`。
- 工作目录：默认用户 Home，V1 不暴露配置（预留 `workingDirectory` 字段）。环境变量：继承父进程 + 透传解析到的 `PATH`。

## 5. 进程管家（Q4/Q15）

- `Foundation.Process` + 双 pipe（stdout/stderr）非阻塞读，合并写入：
  - 文件 `~/Library/Logs/com.xenori.dshdock/dsh.log` 追加，单文件 5MB 轮转（`.1` 备份）。
  - 内存环 buffer 200 行，供 loading/error 页展示尾部。
- 状态机 `idle/starting/running/stopping`，串行化 start/stop/restart，重启中禁用再次点击（按钮转菊花）。
- 停止语义：`process.terminate()`（SIGTERM）→ 等 5s → 还活着则 `SIGKILL`（`kill(pid, 9)`）。`restart = stop + start`，保证旧进程退出后再起新进程。
- App 退出（`applicationWillTerminate` / 关窗口）：同步优雅等 2s，不死再 SIGKILL，保证无孤儿/僵尸（配合 `waitUntilExit` 非阻塞 + `terminationHandler` 收尸）。
- 崩溃（exit != 0）V1 不自动重启，只进 Error 页，避免“配置写错 → CPU 转圈 + log 爆炸”。指数退避自重启列为 V2 可选项。
- 防 pipe 阻塞：持续 `readabilityHandler` 消费；`terminationHandler` 里排空残余。

## 6. 就绪检测与首屏（Q9）

- 启动前先 TCP 预检 `127.0.0.1:<port>`：若已占用 → 直接 Error 页（“端口被占” + `[改端口]` `[重试]`）。
- 拉起后等 stdout 出现 `dsh web: http://127.0.0.1:<port>/?token=…`（token 每次启动都变），
  解析出 token URL 并每 200ms 探活：2xx/3xx 算就绪（实测 token URL 返回 303），401 不算。
  10s 超时；期间原生 loading 视图：“正在启动 dsh… + log 尾部 + [取消]”。
- WebView 加载的必须是 token URL，裸 `/` 只会 401（`dsh web authentication required`）。
  token URL 实测返回 303 并 `Set-Cookie: dsh-auth-*`（HttpOnly），跟随相对重定向 `./`
  后携带 cookie 即 200 —— 因此 WebView 必须用 persistent DataStore（§9-A），换 ephemeral
  每次都会掉登录态。curl 无 cookie 跟随会停在 401，属正常现象。
  若 10s 内没解析到 token 但 TCP 端口已监听，降级加载裸 URL（dsh 自带 401 提示可见）并打日志。
- 诊断命令（shell-escape 后）可在 Error/缺失页一键复制，去终端复现。

## 7. 错误页矩阵（Q10/Q18）

| 场景 | 页面 | 内容 | 操作 |
|---|---|---|---|
| 端口被占 | Error | 占用提示 + 尝试的 URL | 重试 / 打开设置 / 显示日志 |
| dsh 秒退 exit!=0 | Error | exitCode + 最后 100 行 log | 重试 / 打开设置 / 复制诊断命令 |
| 启动超时 10s | Error | 超时 + log 尾 | 同上 |
| dsh/npx 全缺失 | Missing | 已搜路径 + provider | 打开设置 / 复制诊断命令 + `npm install -g @deepseek-ai/dsh@latest` 提示 |

- WebView 的 `ERR_CONNECTION_REFUSED` 不直接暴露，统一收敛到原生页。

## 8. 标题栏按钮与设置交互

- `NSTitlebarAccessoryViewController(.trailing)`（`MainWindowController.setupTitlebar`）：
  交通灯居左（系统），重启/设置嵌在标题栏右侧。刻意不用 `NSToolbar`——toolbar 会
  独占一行把标题栏撑高（28pt → 50pt+）；accessory 让标题栏保持系统默认 28pt。
  教训：accessory 视图不参与窗口级自动布局，必须用显式 frame
  （`NSStackView` 在这里会被压成 0 宽导致按钮不可见），总高不得超过 28pt；
  窗口需 `fullSizeContentView` + 透明标题栏，WebView 顶部按 `contentLayoutRect`
  算出的标题栏高度避让（算不出回退 28）。
- 按钮：SF Symbols `arrow.clockwise`（重启）+ `gearshape`（设置），30x24 无边框，
  tooltip + accessibilityLabel 中文。重启中按钮换菊花（`setRestartingUI`），
  两按钮同时禁用；`starting/stopping` 状态下忽略再次点击。常显，不做自动隐藏
  （chrome 本来就一直在）。
- 设置：点齿轮以按钮为锚点弹 `NSPopover`（transient），字段 `Binary Path` + `Extra Args` +
  `Port(1-65535)` + 当前 provider 只读行 + `[应用并重启]` `[取消]`。
  改完不自动生效，必须点应用；应用时做校验（二进制可执行性、端口范围），非法则行内报错不关闭。

## 9. WebView 策略（Q12/Q17）

- `WKWebView` + 默认 persistent `WKWebsiteDataStore`（保留登录态/localStorage），JS 全开，V1 不改 UA、不开检查器。
- ATS：`NSAllowsLocalNetworking = YES`（`http://127.0.0.1` 本地明文）。
- 导航：`127.0.0.1/localhost` 留在 WebView；外部 `https` 扔默认浏览器；新窗口/下载扔出去；支持 `Cmd+R` 刷新。V1 无地址栏。
- 配置变更（端口/provider 切换）后清空与否：V1 不清空，由用户手动刷新；换端口即新 origin，天然隔离。

## 10. 窗口与生命周期

- 单实例单 dsh。启动即自动起 dsh；红灯（关闭按钮）= 隐藏窗口（`orderOut`），
  dsh 服务继续跑；点 Dock 图标经 `applicationShouldHandleReopen` 重新打开；
  `Cmd+Q` = 退 App + 杀子进程（唯一退出路径）。
- `applicationShouldTerminateAfterLastWindowClosed` 必须 `false`：
  为 `true` 时 `orderOut` 最后一个窗口会连带退出 App（实测：hide 后 27ms 进了 terminate）。
- 窗口 frame autosave（`NSWindow.FrameAutosaveName`），最小 `900×600`，Dock 有图标，支持全屏/分屏。

## 11. 设置持久化

- `UserDefaults`（suite 默认）：`dsh.binaryPath: String = "dsh"`，`dsh.extraArgs: String = ""`，`dsh.port: Int = 38811`。键名稳定，V2 加 `workingDirectory/env` 不迁移。
- 校验：port 越界、二进制不可执行（`isExecutableFile`）在 Apply 时拦截。

## 12. 源码结构（实施约）

```
project.yml                 # xcodegen 源
Sources/
  main.swift                # 显式入口（@main 在无 MainMenu nib 时挂不上 delegate，用 main.swift 手动 run）
  AppDelegate.swift         # @main 已移除，由 main.swift 挂载；生命周期，Quit 时同步杀子进程
  DshConfig.swift           # UserDefaults 模型 + 默认值 + 校验
  ShellSplit.swift          # shell-like 切分 + strip 端口参数 + shell-escape
  BinaryResolver.swift      # login-shell which + 固定路径 + npx 解析，返回 provider
  LogStore.swift            # 文件轮转 + 环 buffer
  DshService.swift          # Process 管家 + TCP 预检 + 就绪轮询 + restart
  MainWindowController.swift# NSWindow + WKWebView + 标题栏 NSToolbar（右侧重启/设置）+ loading/error/missing 视图
  SettingsViewController.swift # popover 表单 + 校验 + Apply&Restart
Info.plist                  # NSAllowsLocalNetworking 等
DshDock.entitlements        # 非沙盒
```

## 13. 构建与运行

```bash
xcodegen generate
xcodebuild -project DshDock.xcodeproj -scheme DshDock -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/.../DshDock.app  # 或 Finder 双击验证 PATH 解析
```

- 验证清单：终端能跑但 Finder 双击也能解析 dsh；端口占用页；kill -9 旧进程后重启；缺失 dsh 时 npx fallback；缺失页复制命令去终端可复现；鼠标离开顶部 2s 工具栏消失；设置 Apply 触发重启。

## 14. 风险与 V2

- MAS 沙盒：当前方案上架需重做（XPC Service / `smarter` 权限），V1 明确不做。
- `dsh web` 输出格式变化：不依赖 stdout 关键字，只依赖 HTTP 探针，已规避。
- npx 冷启动慢 + 需要网络装包：Error 页需展示 `npx` 日志尾，避免误判卡死。
- V2：崩溃指数退避重启、MenuBar 常驻、workingDirectory/env 高级设置、多实例、自动更新（Sparkle）。

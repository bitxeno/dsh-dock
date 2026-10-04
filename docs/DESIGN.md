# DshDock — 开放设计文档

> AppKit + WKWebView 壳，托管运行 `dsh web --no-open`，主窗口即 WebView。
> 本文档是 grill 三轮收敛后的共享理解，可直接指导实施。V1 按非沙盒 Developer ID 分发做。

## 1. 目标与非目标

- 目标：双击即用，自动拉起本地 `dsh web` 服务并加载；顶部悬浮工具栏（重启/设置）；设置页可改启动命令与端口；重启保证旧进程正常退出；工具栏平时隐藏，鼠标到顶部才显。
- 非目标：Mac App Store 沙盒上架、MenuBar 常驻后台、多窗口多实例、完整浏览器 chrome（地址栏/多标签）、自动更新。

## 2. 技术栈与工程

- `Swift + AppKit + WKWebView`，全代码无 Storyboard，`@main AppDelegate`。
- BundleID：`com.xenori.dshdock`，App 名 `DshDock`，最低 `macOS 15.0`。
- 工程：`xcodegen` 生成 `DshDock.xcodeproj`（`project.yml` 为源），源码在 `Sources/`。
  App 图标在 `Sources/Assets.xcassets` 的 `AppIcon.appiconset`（10 尺寸齐全），
  xcodegen 扫 `Sources/` 自动收进 Resources phase 并注入
  `CFBundleIconName/CFBundleIconFile = AppIcon`——在 Xcode 里改工程设置会被
  下次 generate 冲掉，资源放 catalog、设置改动回落 `project.yml`。
- 分发：Developer ID + 公证，不开 Sandbox（`com.apple.security.app-sandbox = false`）。若日后上架 MAS，托管 `Process` 方案需重做，此处记为 tech-debt。

## 3. 启动命令模型（Q3/Q8/Q13/Q21 闭环）

最终命令恒为：

```
<binary> [web | --profile <name>] --no-open --port <port> <extra...>
```

- `binary`：设置页 `Binary Path`，默认 `dsh`（见 §4 解析）。
- `[web | --profile <name>] --no-open --port <port>`：由 App 写死注入，不允许用户编辑。默认注 `web`（等价于 `--profile web`）；`extra` 中若显式给了 `--profile <name>`（`--profile x` / `--profile=x` 两种形态，多个取最后一个），摘出后替换 `web` 并挪到 app-args 之前——`--no-open/--port` 是 web 应用的选项，launcher 自家 flag 只认 `<name>` 之前的位置（实测：`dsh web … --profile x` 报 `unknown option '--profile'`，`dsh --no-open … --profile x` 报 `--profile <name> is required`）。缺值的残缺 `--profile` 丢弃；启动日志记一行"检测到自定义 --profile …：替换默认 web 子命令"。`extra` 中若含 `--port/-p/--bind/--bind-address`，启动前 strip 并在日志 +（可选）toast 提示"已忽略命令中的端口，以端口字段为准"。
- `extra`：设置页 `Extra Args` 字符串，默认空。做 shell-like 切分（支持单/双引号、`\` 转义），不用幼稚 `split(" ")`。占位符提示 `例如：--verbose --data-dir "~/a b"`。
- `port`：设置页数字字段，默认 `38811`，范围 `1–65535`。
- 环境变量：设置页"高级选项"里的 `DSH_HOME`（默认空 = 启动不传，子进程环境保持
  干净）；非空时作为 `DSH_HOME` 注入子进程环境（与 PATH 合并后的 env 一起）。
  启动日志会记一行 `环境变量：DSH_HOME=…`（错误页"详情"可见），诊断命令前也带
  `DSH_HOME=…` 前缀，保证复制到终端可复现。
- 默认三元组效果：`dsh web --no-open --port 38811`。
- npx 形态（见 §4）：`npx --yes @deepseek-ai/dsh web --no-open --port <port> <extra>`，端口/extra 规则完全一致。必须带 `--yes`，否则 GUI 无 stdin 会假死在安装确认上。

## 4. 二进制供给链（三级自动，Q1/Q7/Q19/Q20）

优先级从高到低：

1. 用户在设置页填了自定义 Binary 且可执行 → 直接用它，不 fallback。
2. login-shell 解析 `which dsh`：`/bin/zsh -l -c 'which dsh'`（GUI 从 Finder 启动时 PATH 残缺，必须走 login-shell），找不到再按序试 `/opt/homebrew/bin/dsh`、`/usr/local/bin/dsh`、`~/.local/bin/dsh`。
3. `npx --yes @deepseek-ai/dsh`（同样走 login-shell 解析 `npx`，找不到也按上面固定路径补）。

- 每次启动打日志：最终解析路径 + 用的哪一级，设置页显示当前 provider（`dsh: /opt/homebrew/bin/dsh` / `npx`）。
- 全失败 → 原生缺失页（见 §7），不进 WebView。缺失页文案含已搜索路径 + `npm install -g @deepseek-ai/dsh@latest` + `[打开设置]` `[复制诊断命令]`。
- 工作目录：默认用户 Home，V1 不暴露配置（预留 `workingDirectory` 字段）。环境变量：继承父进程，
  PATH 多来源合并去重（当前 env + login-shell PATH + 解析出的 dsh 所在目录 +
  `/opt/homebrew/bin` `/usr/local/bin` + 系统目录）——实测踩坑：brew shellenv 只配在
  `.zshrc`（交互式）的机器上，Finder 双击下 `zsh -l -c` 的 login PATH 没有
  `/opt/homebrew/bin`，dsh 能靠固定路径解析到但它脚本的 `#!/usr/bin/env node`
  起不来（`env: node: No such file or directory`），终端启动因继承完整 PATH 而掩盖。

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
  10s 超时；期间原生 loading 页像素级对齐 dsh web 自带 loading（从其前端 bundle
  实测 CSS：logo 16pt semibold + 字间距 .08em，spinner 20px/2px 环/72° 弧/0.8s 一圈，
  提示语 12pt，纵列间距 16pt；颜色用语义色适配深色），logo 换 `DSH-DOCK`，
  下方提示语轮播（2.4s 一换，无取消按钮）。
- WebView 加载的必须是 token URL，裸 `/` 只会 401（`dsh web authentication required`）。
  token URL 实测返回 303 并 `Set-Cookie: dsh-auth-*`（HttpOnly），跟随相对重定向 `./`
  后携带 cookie 即 200 —— 因此 WebView 必须用 persistent DataStore（§9-A），换 ephemeral
  每次都会掉登录态。curl 无 cookie 跟随会停在 401，属正常现象。
  若 10s 内没解析到 token 但 TCP 端口已监听，降级加载裸 URL（dsh 自带 401 提示可见）并打日志。
- 诊断命令（shell-escape 后）可在 Error/缺失页一键复制，去终端复现。

## 7. 错误页矩阵（Q10/Q18）

| 场景 | 页面 | 内容 | 操作 |
|---|---|---|---|
| 端口被占 | Error | 占用提示 + 占用进程（lsof 异步补充）+ log 尾 | **强制结束并重启**（SIGKILL 占用进程 → 500ms 等释放 → 常规重启）；**无重试按钮** |
| dsh 秒退 exit!=0 | Error | exitCode + 最后 100 行 log | 重试 |
| 启动超时 10s | Error | 超时 + log 尾 | 重试 |
| dsh/npx 全缺失 | Missing | 已搜路径 + provider + `npm install -g @deepseek-ai/dsh@latest` 提示 | 重试 |

- 错误页 = `StatusViewController`，布局参考 Chrome 断网页：全页浅底 + 左对齐内容列
  （灰色警示图形 + 24pt 大标题 + 灰色说明），左下主按钮组（自绘纯色圆角，
  与设置页主按钮同款），右缘"详情"链接——展开日志块（最近 200 行 +
  "打开日志文件" = `NSWorkspace.open(LogStore.fileURL)`）。"打开设置/复制诊断命令"
  已移除——设置走标题栏齿轮，诊断命令常驻服务日志（`$ …` 行）。
- "强制结束并重启" = `DshService.forceKillPortOccupants`：`/usr/sbin/lsof -Fpc`
  绝对路径（GUI PATH 残缺）查 LISTEN 进程 → 逐个 SIGKILL（可能多个，SO_REUSEPORT）。
- 错误页"详情"读 `LogStore` 环 buffer（每次 `start()` 先清空重写）——所以 `start()`
  所有可能 throw 的路径之前必须先落日志：启动头 + `$ 命令` 行在 TCP 预检之前写，
  二进制解析失败写"已搜索"清单，预检失败写失败行。否则详情永远空白（实测踩过）。
- WebView 的 `ERR_CONNECTION_REFUSED` 不直接暴露，统一收敛到原生页。

## 8. 标题栏按钮与设置交互

- `NSTitlebarAccessoryViewController(.trailing)`（`MainWindowController.setupTitlebar`）：
  交通灯居左（系统），重启/设置嵌在标题栏右侧。刻意不用 `NSToolbar`——toolbar 会
  独占一行把标题栏撑高（28pt → 50pt+）；accessory 让标题栏保持系统默认 28pt。
  教训：accessory 视图不参与窗口级自动布局，必须用显式 frame
  （`NSStackView` 在这里会被压成 0 宽导致按钮不可见），总高不得超过 28pt；
  窗口需 `fullSizeContentView` + 透明标题栏，WebView 顶部按 `contentLayoutRect`
  算出的标题栏高度避让（算不出回退 28）。
- 按钮：SF Symbols `arrow.clockwise`（重启）+ `hand.raised`/`hand.raised.slash`
  （插件重启接管开关，图标随状态切换）+ `gearshape`（设置），30x24 无边框，
  tooltip + accessibilityLabel 中文。重启中按钮换菊花（`setRestartingUI`），
  重启/设置在 `starting/stopping` 状态下忽略再次点击。常显，不做自动隐藏
  （chrome 本来就一直在）。
- 接管开关弹层（`InterceptToggleViewController`，对齐菜单栏弹层参考稿）：
  标题 + `NSSwitch` 靠右 + 灰色说明，点外关闭。偏好存
  `AppPreferences.interceptPluginRestart`（UserDefaults `app.interceptPluginRestart`，
  默认开，见 §11）。切换即时生效：user scripts 全量重建（对之后的页面加载生效）
  + `evaluateJavaScript` 同步当前页的 `__dshDockInterceptEnabled` 标记（钩子在
  fetch 时读标记，已包装的页面关掉后也放行真实请求）；按钮图标随状态切换。
  说明文字多行折行需要 `cell.wraps + preferredMaxLayoutWidth`，只给宽约束
  autolayout 始终按单行测高（实测）。
- 设置：点齿轮以按钮为锚点弹 `NSPopover`（transient，点外关闭，无取消按钮），
  竖屏布局对齐 dsh 桌面端设置窗口（内容宽 300pt 的窄长卡片）：terminal 图标头
  （dsh/服务设置/描述）+ 三行（每行图标 + 标题/副标题在上，输入框独占一行在下，
  图标字形 18pt（frame 仍 24 宽，保住缩进 34pt 对齐）且顶部与标题顶对齐
  （`labelRow.alignment = .top`）；
  输入框左缘与标题文字对齐（缩进 34pt = 图标 24 + 间距 10），右缘到内容右边；
  Binary 纯输入框无"打开文件"按钮，Port 的 stepper 内嵌输入框右缘；
  副标题按实际功能不照抄参考稿：Binary Path = 输入提示 + 第二行
  "当前生效：<provider>"（供给链解析结果，npx/自定义形态区分于此，
  与输入框内容在"改了未应用"时允许不一致；副标题 maxNumberOfLines=3
  容 npx 折行），Port = "dsh web 服务监听端口，应用后生效"）
  + 分割线 + 右下 `[应用并重启]`（118x38 自绘：
  蓝底 layer 圆角 8pt + 白字居中——系统 `.rounded` bezel 在此高度是胶囊形，
  与参考稿不符；用低 hugging spacer 顶到右缘）。输入框用 `roundedBezel`、
  高 32pt（默认方边框与参考稿不符）；内容根视图必须设不透明底
  （`textBackgroundColor`）——popover 默认半透明，会被背后深色网页染灰（实测）。
  改完不自动生效，必须点应用；应用时做校验（二进制可执行性、端口范围），非法则行内报错不关闭。
  "恢复默认"灰字按钮只在暂存表单 ≠ 工厂默认时出现在按钮行左侧（Restore Defaults
  语义，与右下主按钮底对齐），常态左下角为空——常驻按钮挤占版面，改为条件显隐。
  点击回填全部默认值（binary=dsh/extra 空/port 38811/DSH_HOME 清空）、收起高级区、
  清行内报错——只动暂存值，不落盘不重启，与弹层 staged 语义一致，走"应用并重启"
  才生效。显隐同步三个入口：用户键入走 `controlTextDidChange`（field editor 逐键
  回调，delegate 类型是 NSTextFieldDelegate）；stepper/populate 是程序化赋值
  不触发 delegate，手动调 `syncResetVisibility()`。字段初值收进 `populate(_:)`，
  init 与重置共用（必须在 stepper min/max 配置之后调用，否则 integerValue 被
  默认范围钳住）。
- 设置页"高级选项"折叠区（port 行之下）：默认收起，已配置 `DSH_HOME` 时打开设置
  自动展开（配置了却藏着等于不可见）。折叠头 = 无边框按钮（chevron.right/down
  + "高级选项"），展开/收起只切内容行 `isHidden`（NSStackView 默认 detach 隐藏
  视图）；popover 高度跟随要显式回写 `preferredContentSize`——弹层只在内容
  "装不下"时被约束顶大，收缩方向没有约束推它，不回写就停在展开高度。且回写值
  不能读 `view.fittingSize`：preferredContentSize 一旦写过，AppKit 在根视图上
  装 `height == pref`（@501）真实约束，fitting 被污染、只涨不缩——用 stack 自身
  fitting + 根视图留白反推（实测）。loadView 首次调用时视图未挂 popover，跳过
  回写留给 show 时自取。内容复用 `makeFieldRow`：`DSH_HOME` 一行，可选环境
  变量，应用后随启动注入 dsh 子进程（见 §3），留空不传。

## 9. WebView 策略（Q12/Q17）

- `WKWebView` + 默认 persistent `WKWebsiteDataStore`（保留登录态/localStorage），JS 全开，V1 不改 UA、不开检查器。
- ATS：`NSAllowsLocalNetworking = YES`（`http://127.0.0.1` 本地明文）。
- 导航：`127.0.0.1/localhost` 留在 WebView；外部 `https` 扔默认浏览器；新窗口/下载扔出去；支持 `Cmd+R` 刷新。V1 无地址栏。
- 配置变更（端口/provider 切换）后清空与否：V1 不清空，由用户手动刷新；换端口即新 origin，天然隔离。
- 插件重启接管（dsh-market "立即重启"）：客户端用 `fetch POST …/dsh-market/restart`
  （202 `{ok:true}` 后轮询 bootId 变化再 `location.reload()`）。注入 `WKUserScript`
  fetch 钩子命中即 postMessage 给原生并回合成 202，**真请求不出网**——dsh 自己的
  detached 重启助手不会运行（否则会出现 App 管不到的接管进程，后续设置重启必撞
  端口占用）；原生走常规 `service.restart`（SIGTERM 优雅退出 → 新 token）。
  reload 携带的旧 token 在 `decidePolicyFor` 里纠正为当前 token URL（token 每次启动
  都变，放行必 401 白页）。行为测试覆盖：真实调用形态/v1 别名/放行/带查询参数/防重复注入。
  已知边界：dsh-market 的 recovery-apply 流程也会重启宿主，未拦截（会走 detached
  助手 → App 显示意外退出页，用"重试"或"强制结束并重启"可恢复）。

## 10. 窗口与生命周期

- 单实例单 dsh。启动即自动起 dsh；红灯（关闭按钮）= 隐藏窗口（`orderOut`），
  dsh 服务继续跑；点 Dock 图标经 `applicationShouldHandleReopen` 重新打开；
  `Cmd+Q` = 退 App + 杀子进程（唯一退出路径）。
- 单例运行在 `main.swift` 最顶部（先于任何服务启动）拦：按 bundleID 查
  `NSRunningApplication`，命中已有实例 → 发分布式通知 `com.xenori.dshdock.reopen`
  （已运行实例监听后 `showMainWindow` 复活红灯隐藏的窗口）+ 尽力 `activate()`
  → 本进程 `exit(0)`，不会拉起第二个 dsh/抢端口。实测：直接双击二进制
  重复启动时第二实例 exit 0、第一实例存活。
- `applicationShouldTerminateAfterLastWindowClosed` 必须 `false`：
  为 `true` 时 `orderOut` 最后一个窗口会连带退出 App（实测：hide 后 27ms 进了 terminate）。
- 窗口 frame autosave（`NSWindow.FrameAutosaveName`），最小 `900×600`，Dock 有图标，支持全屏/分屏。

## 11. 设置持久化

- `UserDefaults`（suite 默认）：`dsh.binaryPath: String = "dsh"`，`dsh.extraArgs: String = ""`，
  `dsh.port: Int = 38811`，`dsh.dshHome: String = ""`（"高级选项"里的 `DSH_HOME`，
  空 = 启动不注入该变量）。键名稳定，不迁移；`workingDirectory` 仍是 V2 预留。
- App 级偏好（`AppPreferences`，与 dsh 启动三元组分键、不进设置表单）：
  `app.interceptPluginRestart: Bool = true`（插件"立即重启"由 App 接管，见 §9/§8）。
- 校验：port 越界、二进制不可执行（`isExecutableFile`）在 Apply 时拦截。

## 12. 源码结构（实施约）

```
project.yml                 # xcodegen 源
Sources/
  main.swift                # 显式入口 + 单例守卫（重复启动→通知已有实例弹窗后退出），@main 在无 MainMenu nib 时挂不上 delegate，用 main.swift 手动 run
  AppDelegate.swift         # @main 已移除，由 main.swift 挂载；生命周期，Quit 时同步杀子进程；监听第二实例 reopen 通知
  Assets.xcassets           # AppIcon.appiconset（DeepSeek 鲸鱼定制图，10 尺寸）
  DshConfig.swift           # UserDefaults 模型 + 默认值 + 校验
  ShellSplit.swift          # shell-like 切分 + strip 端口参数 + shell-escape
  BinaryResolver.swift      # login-shell which + 固定路径 + npx 解析，返回 provider
  LogStore.swift            # 文件轮转 + 环 buffer
  DshService.swift          # Process 管家 + TCP 预检 + 就绪轮询 + restart
  MainWindowController.swift# NSWindow + WKWebView + 标题栏 accessory + loading 视图（错误/状态页在 StatusViewController）
  StatusViewController.swift # 错误/状态页（Chrome 断网页式全页布局）：详情展开日志 + 打开日志文件；重试 / 端口占用时强制结束并重启
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
- 发布：推 `v*` 标签触发 `.github/workflows/release.yml`（也可手动 dispatch）——
  universal（arm64+x86_64）ad-hoc 签名构建，版本在构建期经
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 注入 Info.plist（签名前定稿，
  随签名封存；严禁签名后用 PlistBuddy 改包内 Info.plist——破坏签名后 macOS
  判定为篡改，其子进程被沙盒限制加载外部卷 dylib，实测）
  → hdiutil 打 DMG → SHA256 → 生成 cask（头注释按 `brew style` 要求：typed 在前、
  strict、desc 不含平台名）→ GitHub Release 附 DMG/checksums/cask。可选 secrets
  `HOMEBREW_TAP_REPO`+`HOMEBREW_TAP_TOKEN` 自动把 cask 推到 tap 仓库，用户
  `brew install --cask <owner>/tap/dshdock`；未配则 cask 附在 Release 资产里手动拷。
  cask 带 `postflight_steps` 钩子装完自动 `xattr -dr com.apple.quarantine`——brew
  安装路径无 Gatekeeper 拦截；直连 DMG 的用户仍需手动去隔离（caveats 说明）。
  新 install-steps DSL 实测：路径用 `{{appdir}}` 模板标记（steps 块内没有 `appdir`
  方法、`base:` 只锚定命令不锚定 args、cop 只认纯字符串参数），块内只允许 `run`
  等步骤调用。tap 在本机是 git 克隆，改完远端必须手动 pull 克隆再测，否则测到旧版。
  打包命令与 CI 相同，已本地全链路干跑验证（构建/挂载/lipo/style）；`dist/`、
  `build/` 已 gitignore。ad-hoc 构建未公证，用户首次启动需右键打开或 xattr 去隔离。

## 14. 风险与 V2

- MAS 沙盒：当前方案上架需重做（XPC Service / `smarter` 权限），V1 明确不做。
- `dsh web` 输出格式变化：不依赖 stdout 关键字，只依赖 HTTP 探针，已规避。
- npx 冷启动慢 + 需要网络装包：Error 页需展示 `npx` 日志尾，避免误判卡死。
- V2：崩溃指数退避重启、MenuBar 常驻、workingDirectory 高级设置、多实例、自动更新（Sparkle）。
  （env 已提前落地：§3 的 `DSH_HOME`，2026-10。）

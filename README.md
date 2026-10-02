# DshDock

macOS 桌面壳：`AppKit + WKWebView`，主窗口即 WebView，自动托管一条本地
`dsh web --no-open` 服务并加载它。标题栏右侧（和关闭/最小化等系统按钮同一栏）
放重启与设置按钮。

## 功能

- 打开 App 自动拉起 `dsh web --no-open --port <port>`，解析 stdout 中的
  token URL 并加载（裸 `/` 只会 401，必须带 token，见下文原理）。
- 标题栏右侧：重启（`arrow.clockwise`）+ 设置（`gearshape`），titlebar accessory
  嵌进系统标题栏（刻意不用 `NSToolbar`，它会独占一行撑高标题栏），和交通灯同一栏，
  高度保持系统默认 28pt，常显；重启中按钮变菊花并禁用。
- 设置页（popover）：`Binary Path` + `Extra Args` + `Port`，校验后应用并重启。
- 重启语义：SIGTERM → 等 5s → SIGKILL，保证旧进程退出后再起新进程。
- 供给链 fallback：自定义二进制 → login-shell `which dsh` →
  `npx --yes @deepseek-ai/dsh`；全缺失时进原生缺失页。
- 错误页：端口占用 / 秒退 / 超时统一收敛为原生页（exitCode + 日志尾 +
  重试/设置/复制诊断命令），不直接暴露 `ERR_CONNECTION_REFUSED`。
- 外部链接扔给默认浏览器；`Cmd+R` 刷新；登录态持久化。

## 环境要求

- macOS 15+，Xcode 26（Swift 工具链随 Xcode）
- `xcodegen`（`brew install xcodegen`）
- `dsh`（`brew` 安装）或 `node + npx`（fallback 用，已验证
  全局包 `@deepseek-ai/dsh` 可用）

## 快速开始

```bash
xcodegen generate
xcodebuild -project DshDock.xcodeproj -scheme DshDock -configuration Debug build
APP=$(xcodebuild -project DshDock.xcodeproj -scheme DshDock -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' \
  '/^ *BUILT_PRODUCTS_DIR = /{p=$2} /^ *FULL_PRODUCT_NAME = /{n=$2} END{print p"/"n}')
open "$APP"
```

从 Finder 双击启动也一样能解析 `brew` 装的 `dsh`
（GUI App 的 PATH 是残缺的，工程里走了 login-shell 解析，`docs/DESIGN.md §4`）。

## 安装（发布版）

推 `v*` 标签（或在 Actions 页手动触发）会自动构建通用二进制（arm64 + x86_64）、
打 DMG、算 SHA256、生成 Homebrew cask 并发布到 GitHub Releases，见
`.github/workflows/release.yml`。

- **直接下载**：到 [Releases](https://github.com/bitxeno/dsh-dock/releases) 下载
  `DshDock-<版本>.dmg`。构建为 ad-hoc 签名（未公证），首次启动若被 Gatekeeper
  拦截：右键 App 选"打开"，或执行
  `xattr -dr com.apple.quarantine /Applications/DshDock.app`。
- **Homebrew（自定义 tap）**：需要先建一个 `homebrew-tap` 仓库（如
  `bitxeno/homebrew-tap`），然后在 dsh-dock 仓库配置两个 Actions secrets：
  `HOMEBREW_TAP_REPO`（如 `bitxeno/homebrew-tap`）和
  `HOMEBREW_TAP_TOKEN`（对该 tap 仓库有 contents:write 的 PAT）。
  配好后每次发布会自动更新 tap 里的 cask，用户即可：

  ```bash
  brew install --cask bitxeno/tap/dshdock
  ```

  未配 secrets 时，cask 会附在 Release 资产里（`dshdock.rb`），手动拷进
  tap 仓库的 `Casks/` 目录即可，效果相同。

## 用 sweetpad 启动（推荐）

[sweetpad](https://github.com/sweetpad-dev/sweetpad) 是 human 版的 `xcodebuild`，
一条命令完成构建 + 启动 + 跟日志（已在本仓库实测通过）：

```bash
brew install sweetpad
sweetpad run                 # 构建、启动、前台跟日志（按 Ctrl-C / `q` 退出跟随）
sweetpad app run --detach    # 后台启动，CLI 直接返回（输出重定向到 sweetpad 日志）
sweetpad app logs --last 5m  # 只看最近日志，不跟随
sweetpad app stop            # 终止 App
```

注意：

- 首次 `run` 会自动记住 scheme（DshDock）与 destination（macOS），
  用 `sweetpad status` 查看当前上下文。
- **`sweetpad app stop` 是强制终止**：不会走 App 的优雅退出路径，
  托管的 `dsh web` 子进程会变成孤儿继续占着端口（已实测）。
  要干净退出（SIGTERM 先杀子进程），用 AppleScript 发 quit 或直接关窗口：
  ```bash
  osascript -e 'tell application "DshDock" to quit'
  ```
  万一已有孤儿：`pkill -f "dsh web"`（先 TERM，不死再 KILL）。
- 无论哪种方式启动，dsh 日志都在 `~/Library/Logs/com.xenori.dshdock/dsh.log`。

## 设置项（默认值）

| 字段 | 默认值 | 说明 |
|---|---|---|
| Binary Path | `dsh` | 可填绝对路径；非默认值解析失败时不 fallback，直接报错 |
| Extra Args | 空 | 附加参数，shell-like 切分；其中自带的 `web/--no-open/--port/--host` 会被 strip（App 拥有） |
| Port | `38811` | 最终命令恒为 `<binary> web --no-open --port <port> <extra>` |

持久化在 `UserDefaults`（`dsh.binaryPath / dsh.extraArgs / dsh.port`）。

## 原理（排障前必读）

1. `dsh web` 每次启动打印一次性 URL：`dsh web: http://127.0.0.1:<port>/?token=…`。
2. 该 URL 返回 **303** 并 `Set-Cookie: dsh-auth-*`，跟随重定向后 **200**；
   裸 `/` 永远 **401**。所以 App 必须加载 token URL，且 WebView 必须用
   persistent DataStore（换 ephemeral 会掉登录态）。
3. 就绪判定 = 等 token URL 出现 + 探活 2xx/3xx（10s 超时），另有 TCP 兜底。
4. 日志：`~/Library/Logs/com.xenori.dshdock/dsh.log`（5MB 轮转）+ 内存 200 行环 buffer。

## 目录结构

```
project.yml                  # xcodegen 唯一源（改工程只改它 + Sources，再 generate）
Info.plist                   # 生成物，别手改（ATS 等键在 project.yml 的 info.properties 里）
DshDock.entitlements         # 非沙盒（Developer ID 直发，不上 MAS）
docs/DESIGN.md               # 开放设计文档（ grill 共识 + 实测修正）
Sources/
  main.swift                 # 显式入口（@main 在无 nib 时挂不上 delegate）
  AppDelegate.swift          # 生命周期；退出时同步杀子进程
  BinaryResolver.swift       # 三级供给链 + login-shell PATH 解析
  DshService.swift           # Process 管家 + token 解析 + 就绪轮询 + restart
  LogStore.swift             # 文件轮转 + 环 buffer
  DshConfig.swift            # UserDefaults 模型 + 校验
  ShellSplit.swift           # shell 切分 / strip / shell-escape
  MainWindowController.swift # 主窗口 + WebView + 标题栏工具栏 + loading/error/missing 页
  SettingsViewController.swift # 设置表单
```

## 排障

| 现象 | 看哪里 |
|---|---|
| 首屏“找不到 dsh” | 缺失页列出的已搜索路径；或 `npm install -g @deepseek-ai/dsh@latest` |
| 端口被占 | 换端口，或停掉占用进程 |
| 秒退 / 超时 | 点“复制诊断命令”去终端复现，看 `dsh.log` 尾 |
| 401 鉴权页 | token 没解析到（dsh 改了输出格式？），看日志里有无 `发现服务 URL` |

## 非目标（V1 不做）

Mac App Store 沙盒上架、MenuBar 常驻、崩溃自动重启、多窗口、自动更新。详见 `docs/DESIGN.md §14`。

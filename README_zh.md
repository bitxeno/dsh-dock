# DshDock

[English](./README.md) | [中文](./README_zh.md)

DshDock 是 macOS 上的 dsh 桌面应用。打开就能用，dsh 跑在独立窗口里，不需要浏览器。

## 安装

- **Homebrew：**`brew install --cask bitxeno/tap/dshdock`
- **直接下载：**到 [Releases](https://github.com/bitxeno/dsh-dock/releases) 下载 `DshDock-<版本>.dmg`，拖进应用程序文件夹。

首次启动若被系统拦截（App 未公证）：右键 App 选"打开"。或执行 `xattr -dr com.apple.quarantine /Applications/DshDock.app`。

需要 macOS 15+。

## 使用

打开 App 就行，一切自动启动。

- **重启按钮**（标题栏 ↻）：页面卡住或空白时点它。
- **设置按钮**（标题栏齿轮）：一般不用管。
- 跳往外部页面的链接会自动用默认浏览器打开。

## 设置

绝大多数人保持默认即可。

| 设置项 | 默认值 | 什么时候改 |
|---|---|---|
| dsh 位置 | `dsh` | App 提示找不到 dsh、且你的 dsh 装在别处时才改 |
| 额外参数 | 空 | 高级用法，留空 |
| 端口 | `38811` | 和本机其他应用冲突时才改 |

## 出问题了

- **提示找不到 dsh：**执行 `npm install -g @deepseek-ai/dsh@latest` 安装，然后重启 App。
- **端口被占用：**去设置里换个端口，或关掉占用它的应用。
- **空白页 / 一直失败：**点重启按钮，再看错误页上的详情。
- 日志文件（求助时附上）：`~/Library/Logs/com.xenori.dshdock/dsh.log`

---

## 开发者信息

- 构建需要 Xcode 26 + `xcodegen`：`xcodegen generate`，再 `xcodebuild -project DshDock.xcodeproj -scheme DshDock -configuration Debug build`。
- 底层实际执行的是 `<binary> web --no-open --port <port> <extra>`；设置存在 `UserDefaults`（`dsh.binaryPath` / `dsh.extraArgs` / `dsh.port`）。
- 详细设计：`docs/DESIGN.md`

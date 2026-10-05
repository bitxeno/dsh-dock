<div align="center">
  <img src="./docs/image/logo.png" height="256">

  <h1 align="center">DshDock</h1>
</div>

<div align="center">

<img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white"
            alt="macOS 15+">
<a href="https://github.com/bitxeno/dsh-dock/blob/main/LICENSE">
<img src="https://img.shields.io/github/license/bitxeno/dsh-dock"
            alt="License"></a>
<a href="https://github.com/bitxeno/dsh-dock/releases">
<img src="https://img.shields.io/github/downloads/bitxeno/dsh-dock/total.svg"
            alt="Downloads"></a>

</div>


<div align="center">

English | [中文](./README_zh.md)

</div>

## DshDock

DshDock is a desktop app for dsh on macOS, built with AppKit + WebView — small and lightweight, no browser needed.

<p align="center">
  <img src="./docs/image/screenshot_home.png" alt="DshDock home window" width="60%">
</p>

## Features

- Configurable profile and DSH_HOME
- Handles dsh-market plugin restarts
- Works with system notification plugins

## Install

### Install the official deepseek-harness

```
npm -g install @deepseek-ai/dsh
```

### Homebrew

```
brew install --cask bitxeno/tap/dshdock
```

### Direct download

Get `DshDock-<version>.dmg` from [Releases](https://github.com/bitxeno/dsh-dock/releases), drag to Applications.

> If macOS blocks the first launch (app is not notarized): right-click the app → Open. Or run `xattr -dr com.apple.quarantine /Applications/DshDock.app`.

Requires macOS 15+.

## Use

Just open the app — everything starts automatically.

- **Restart button** (↻ in the title bar): click it if the page freezes or goes blank.
- **Settings button** (gear in the title bar): you normally never need to touch this.
- **Notification button** (bell in the title bar): notch overlay (default, no system permission needed) or system notifications.
- Links to outside pages open in your default browser.

## Settings

Most people can leave everything as-is.

| Setting | Default | When to change it |
|---|---|---|
| dsh location | `dsh` | Only if the app says dsh can't be found and yours lives somewhere else |
| Extra options | empty | Advanced use only, leave empty |
| Port | `38811` | Only if it conflicts with another app on your Mac |
| DSH_HOME (under "Advanced") | empty | Only when dsh specifically needs a custom `DSH_HOME`; left empty the variable is not passed at all |


---

## Development

- Building requires Xcode 26 + `xcodegen`: `xcodegen generate`, then build with `xcodebuild -project DshDock.xcodeproj -scheme DshDock -configuration Debug build`.
- The app runs `<binary> [web | --profile <name>] --no-open --port <port> <extra>` under the hood — putting `--profile <name>` in Extra Args replaces the default `web`; settings are stored in `UserDefaults` (`dsh.binaryPath` / `dsh.extraArgs` / `dsh.port` / `dsh.dshHome`, plus app-level `app.interceptPluginRestart` / `app.notifyBackend` default `notch`).
- Design details (in Chinese): `docs/DESIGN.md`

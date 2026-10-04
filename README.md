# DshDock

[English](./README.md) | [中文](./README_zh.md)

DshDock is a desktop app for dsh on macOS. Open it and dsh just runs in its own window — no browser needed.

## Install

- **Homebrew:** `brew install --cask bitxeno/tap/dshdock`
- **Download:** get `DshDock-<version>.dmg` from [Releases](https://github.com/bitxeno/dsh-dock/releases), drag to Applications.

If macOS blocks the first launch (app is not notarized): right-click the app → Open. Or run `xattr -dr com.apple.quarantine /Applications/DshDock.app`.

Requires macOS 15+.

## Use

Just open the app — everything starts automatically.

- **Restart button** (↻ in the title bar): click it if the page freezes or goes blank.
- **Settings button** (gear in the title bar): you normally never need to touch this.
- Links to outside pages open in your default browser.

## Settings

Most people can leave everything as-is.

| Setting | Default | When to change it |
|---|---|---|
| dsh location | `dsh` | Only if the app says dsh can't be found and yours lives somewhere else |
| Extra options | empty | Advanced use only, leave empty |
| Port | `38811` | Only if it conflicts with another app on your Mac |
| DSH_HOME (under "Advanced") | empty | Only when dsh specifically needs a custom `DSH_HOME`; left empty the variable is not passed at all |

## If something goes wrong

- **dsh can't be found:** install it with `npm install -g @deepseek-ai/dsh@latest`, then restart the app.
- **Port is in use:** change the Port in Settings, or quit the app that's using it.
- **Blank page / keeps failing:** click Restart, then check the details on the error page.
- Log file (attach it when asking for help): `~/Library/Logs/com.xenori.dshdock/dsh.log`

---

## For developers

- Building requires Xcode 26 + `xcodegen`: `xcodegen generate`, then build with `xcodebuild -project DshDock.xcodeproj -scheme DshDock -configuration Debug build`.
- The app runs `<binary> web --no-open --port <port> <extra>` under the hood; settings are stored in `UserDefaults` (`dsh.binaryPath` / `dsh.extraArgs` / `dsh.port` / `dsh.dshHome`).
- Design details (in Chinese): `docs/DESIGN.md`

# CSwapBar

A native macOS menu bar app for [claude-swap](https://github.com/realiti4/claude-swap) — see every managed Claude Code account's 5-hour and weekly usage at a glance, and switch between them with one click.

It owns no account-switching logic of its own. Every action shells out to the real `cswap` CLI, so the two stay in sync.

## Install

```sh
brew install --cask ahmadarif-lab/tap/cswap-makeover
```

Requires the `cswap` CLI itself, which is not a Homebrew package:

```sh
uv tool install claude-swap     # or: pipx install claude-swap
```

Start it at login:

```sh
/Applications/CSwapBar.app/Contents/Resources/install_service.sh
```

## What it does

- Usage bars per account (5h session + 7d weekly), color-coded by how much is left
- Mini usage bars in the menu bar itself, so you don't have to open the popover
- Click any account card to switch to it
- **Warm up all accounts** — rotates through every account, sends a throwaway `claude -p` to each, then returns to the account you started on
- Add an account from the current login or from a setup-token; pause/resume and remove accounts

Every row maps to a real command:

| UI | Command |
| --- | --- |
| Account cards, usage bars | `cswap list --json` |
| Click a card | `cswap switch <n>` |
| Add current login / Refresh credentials | `cswap add` |
| Add from setup-token | `cswap add-token <token> [--email …]` |
| Pause / resume | `cswap disable` / `cswap enable` |
| Remove | `cswap remove <n>` |
| Warm up all accounts | `cswap switch <n>` + `claude -p` per account |

## Build from source

Requires macOS 14+ and a Swift 5.10+ toolchain.

```sh
swift run                      # dev build (shows a temporary Dock icon)
./Scripts/build_app.sh         # packages dist/CSwapBar.app
./Scripts/install_service.sh   # LaunchAgent: start at login, restart on crash
./Scripts/uninstall_service.sh
```

After rebuilding while the service is running:

```sh
launchctl kickstart -k gui/$(id -u)/dev.ahmadarif.cswap-makeover
```

## License

MIT

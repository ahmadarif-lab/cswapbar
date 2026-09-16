<p align="center">
  <img src="Resources/AppIcon.png" alt="CSwapBar app icon" width="128">
</p>

<h1 align="center">CSwapBar</h1>

<p align="center">
  A native macOS menu bar app for juggling several Claude Code accounts — see every account's 5-hour
  and weekly usage at a glance, and switch between them with one click.<br>
  Its account engine is a Swift port of <a href="https://github.com/realiti4/claude-swap">claude-swap</a>
  that reads and writes the same data, so the <code>cswap</code> CLI keeps working alongside it — but
  you don't need it installed.
</p>

<p align="center">
  <a href="#install">
    <img src="https://img.shields.io/badge/Install-Homebrew-FBB040?style=flat-square&logo=homebrew&logoColor=white" alt="Install with Homebrew">
  </a>
  <a href="https://github.com/ahmadarif-lab/cswapbar/releases/latest">
    <img src="https://img.shields.io/github/v/release/ahmadarif-lab/cswapbar?label=Download&style=flat-square&color=2f81f7&cacheSeconds=300" alt="Download the latest release">
  </a>
</p>

## Install

> [!TIP]
> **Homebrew is the easiest way — one command, nothing else to set up:**
>
> ```sh
> brew install --cask ahmadarif-lab/tap/cswapbar
> ```
>
> It adds the `ahmadarif-lab/tap` tap, clears the quarantine flag so the app opens straight away —
> no Gatekeeper warning to click through — and launches it once installed.

Nothing else is required. Accounts you already manage with claude-swap show up on first launch:
CSwapBar uses the same `~/.claude-swap-backup` folder and Keychain items.

CSwapBar starts itself at login from the first launch onwards (via `SMAppService`). Turn that off
from **Start at login** in the menu, or in System Settings → General → Login Items.

### Updating

CSwapBar checks for a new release when it launches and every six hours after that, and shows
**Install update** in the menu when one is out. Click it: a Homebrew install is upgraded in place
and the app relaunches on its own. A copy that wasn't installed via Homebrew opens the release page
instead.

Or from the terminal:

```sh
brew upgrade --cask cswapbar
```

### Manual install (DMG)

Download `CSwapBar.dmg` from [Releases](https://github.com/ahmadarif-lab/cswapbar/releases/latest)
and drag the app into `Applications`. The Homebrew install clears this for you; here you do it by
hand, since the app is ad-hoc signed rather than signed with a Developer ID and notarized:

```sh
xattr -dr com.apple.quarantine /Applications/CSwapBar.app
```

Or open it once through **System Settings → Privacy & Security**, where an **Open Anyway** button
appears after a blocked launch.

## Screenshot

<p align="center">
  <img src="Resources/screenshots/menu-bar.png" alt="CSwapBar popover showing two accounts with session/weekly usage bars, warm-up, and manage actions" width="360">
</p>

## What it does

- Usage bars per account (5h session + 7d weekly), color-coded by how much is left, with the reset
  countdown and local reset time next to each bar
- Mini usage bars in the menu bar itself, so you don't have to open the popover
- Click any account card to switch to it
- **Warm up all accounts** — rotates through every account, sends a throwaway `claude -p` to each,
  then returns to the account you started on
- Add an account from the current login or from a setup-token; pause/resume and remove accounts
- Keeps itself up to date: checks for new releases, and a Homebrew install updates in place

Each action does exactly what the matching `cswap` command does, on the same files:

| UI | Same as |
| --- | --- |
| Account cards, usage bars | `cswap list --json` |
| Click a card | `cswap switch <n>` |
| Add current login / Refresh credentials | `cswap add` |
| Add from setup-token | `cswap add-token <token> [--email …]` |
| Pause / resume | `cswap disable` / `cswap enable` |
| Remove | `cswap remove <n>` |
| Warm up all accounts | a switch + `claude -p` per account |
| Check for updates | GitHub's latest-release API, every 6 hours and on click |
| Install update | `brew update` + `brew upgrade --cask ahmadarif-lab/tap/cswapbar`, then a relaunch |

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code — the `claude` CLI is only needed for **Warm up all accounts**
- Xcode command line tools with Swift 5.10+, only if you build from source

## Build from source

```sh
swift run                        # dev build (shows a temporary Dock icon)
swift test                       # account engine tests
./Scripts/build_app.sh           # packages dist/CSwapBar.app
./Scripts/package_release.sh     # also builds the DMG and prints its sha256
```

To reload a rebuilt app:

```sh
killall CSwapBar; open /Applications/CSwapBar.app
```

## Relationship to claude-swap

`Sources/SwapEngine` ports claude-swap 0.26.0's `list`, `switch`, `add`, `add-token`,
`enable`/`disable` and `remove`, keeping its on-disk format byte for byte: `~/.claude-swap-backup`,
the `claude-swap` Keychain service, and Claude Code's own credential and lock files. When a new
claude-swap release changes any of those paths, port the change and bump
`AccountEngine.upstreamVersion`.

## License

MIT

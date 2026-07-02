# CodexQuota

A floating macOS window that shows your remaining Codex (OpenAI ChatGPT Codex CLI) quota — the 5-hour window and the weekly window — without making any network calls.

[中文文档 →](README-zh.md)

## How it works

Codex CLI writes its rate-limit response into the local session log on every model call. CodexQuota tails `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, parses the latest `rate_limits` field, and renders it. No login, no API token, no traffic to OpenAI.

This also means: **the numbers only change when you actually run Codex**. While idle, the displayed percentages stay frozen at the last snapshot — the reset countdown will keep ticking and zero out on its own.

## Install

### Homebrew (recommended)

```sh
brew tap myaiisalive/tap
brew trust myaiisalive/tap
brew install --cask codex-quota
```

To update:

```sh
brew upgrade --cask codex-quota
```

### Manual download

Grab a build from the [Releases page](https://github.com/myaiisalive/codex-quota/releases):

| File | For |
|---|---|
| `CodexQuota-x.y.z-universal.dmg` / `.zip` | Apple Silicon **and** Intel |
| `CodexQuota-x.y.z-arm64.dmg` / `.zip` | Apple Silicon only (smaller) |

Open the DMG and drag `CodexQuota.app` into `/Applications`, or unzip the ZIP and move the app yourself.

> Requires macOS 13 or newer.

### "App can't be opened" — Gatekeeper

The releases are ad-hoc signed (no Apple Developer ID, no notarization). On first launch macOS may say *"CodexQuota can't be opened because Apple cannot check it for malicious software"* or *"is damaged and can't be opened"*.

Pick whichever works:

1. **Right-click the app → Open**, then click *Open* in the dialog. You only do this once.
2. **System Settings → Privacy & Security**, scroll to the bottom, click *Open Anyway* next to the CodexQuota notice.
3. If macOS still refuses (typically the *"is damaged"* message after downloading via browser, which adds a quarantine flag), strip the quarantine attribute in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/CodexQuota.app
   ```

   Then launch normally.

This is a side effect of not paying $99/yr for a Developer ID. If you'd rather build it yourself, see *Build from source* below — your local build won't be quarantined.

## Using it

After launch:

- A **menu bar icon** appears showing the tighter of the two remaining percentages.
- A **floating window** drops in (top-right by default). Drag it anywhere — the position is remembered across launches.
- The window stays on top of every space and every app.

### The floating window

| Control | Action |
|---|---|
| Red button (top-left) | Hide the window |
| Yellow button (top-left) | Minimize to Dock (a Dock icon appears; click it to restore) |
| ↻ button (top-right) | Refresh now |
| ⤡ button (top-right) | Collapse to a single line / expand back |

The window auto-fades to a configurable opacity when your mouse leaves; hover to bring it back to 100%.

### Menu bar icon

- **Left-click** — show the floating window (won't hide it; use the red button to hide).
- **Right-click** — menu with *Refresh now*, *Preferences…*, *Quit*.

### Preferences

`Right-click menu bar icon → Preferences…` (or `⌘,` when the settings window is in focus):

- **Idle opacity** — how transparent the window goes when your mouse is away (5%–100%).
- **Fade delay** — seconds before fading kicks in (1–30s).
- **Menu bar source** — whether the percentage in the menu bar represents the 5-hour or weekly window (default: 5-hour).
- **Auto-refresh interval** — how often to re-read the session file (5s–10min). On top of this, the app also reloads instantly whenever Codex writes a new line, so a long interval here is fine.

## Release workflow

### 1. Build and publish a GitHub Release

```sh
./release.sh          # auto-increments version (0.3.4 → 0.3.5)
# or specify explicitly:
./release.sh 1.0.0
```

The script produces 4 packages in `dist/`. Publish them with `gh`:

```sh
gh release create v0.3.5 \
  --title "v0.3.5" \
  --notes-file dist/RELEASE_NOTES.md \
  dist/CodexQuota-0.3.5-universal.dmg \
  dist/CodexQuota-0.3.5-universal.zip \
  dist/CodexQuota-0.3.5-arm64.dmg \
  dist/CodexQuota-0.3.5-arm64.zip
```

### 2. Update the Homebrew tap in the same release run

A release is not complete until the Homebrew tap is updated to the same version in the same publishing run. After the GitHub Release is live, grab the new SHA256 digests and update the Cask file in [myaiisalive/homebrew-tap](https://github.com/myaiisalive/homebrew-tap):

```sh
# fetch sha256 from the release
gh release view v0.3.5 --json assets --jq '.assets[] | "\(.name) \(.digest)"'

# edit Casks/codex-quota.rb: bump version + both sha256 values, then push
# verify Homebrew sees the same version
brew update
brew info --cask --json=v2 codex-quota | jq '.casks[0] | {version, installed, outdated}'
```

Users will get the update on their next `brew upgrade --cask codex-quota`. Do not announce a release until both the GitHub Release and the Homebrew tap are on the same version.

## Build from source

Requires macOS 13+ and Command Line Tools (`xcode-select --install` — Swift is included; full Xcode is not needed).

```sh
git clone git@github.com:myaiisalive/codex-quota.git
cd codex-quota

./bundle.sh           # debug-friendly build → ./CodexQuota.app
open CodexQuota.app

./release.sh 0.2.0    # release build → dist/ (universal + arm64, .dmg + .zip)
```

`release.sh` cross-compiles for both architectures, lipos a universal binary, ad-hoc signs each `.app`, and emits four installers in `dist/`.

## Limitations

- Quota numbers update only when you actually call Codex — there's no upstream API to poll.
- If you've never run Codex on this machine, there's nothing to read; the app shows a friendly "no data yet" state until your first run.
- The schema of `rate_limits` in the session log is not a public contract; if OpenAI changes it, this app will need a small update.

## License

MIT.

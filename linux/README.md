# Hotch for Linux (experimental)

Linux uses a separate Rust binary and GNOME Shell frontend. The macOS SwiftUI app is unchanged. The GNOME extension provides a card with Now, AI, Sessions, System, Focus and Clipboard pages, plus Settings in the footer. Other desktops use a simpler tray and the CLI.

## Feature support

| Feature | GNOME Shell 48–50 | Other Linux desktops |
|---|---|---|
| Claude / Codex usage, resets and plan names | Yes | Tray and CLI |
| Codex approval/input state | When reported by the local app-server | Same backend |
| Settings and provider controls | Settings page and CLI | CLI |
| Homes | Top bar, pill, orb, left/right/bottom edge | Tray |
| Light/dark/system appearance | Yes | Desktop-controlled tray menu |
| Used/remaining display; refresh cadence | Yes | Shared preferences |
| Focus timer / stopwatch | Current run, pause/resume and persistence | Not yet |
| Clipboard history | Optional, five text entries in memory | Not yet |
| CPU, memory, battery | Yes | Tray and CLI |
| Focus task history / daily totals; session host handoff | Not yet | Not yet |
| Grok, Kimi, DeepSeek; network/disk/process/GPU/sensors | Not yet | Not yet |
| macOS notch / Dock / Backpack integration | Unavailable | Unavailable |

Screen edges are compact readouts on the primary monitor. Pill and orb can be dragged across monitors and remember their position. These are Linux placements using GNOME widgets, rather than exact replicas of every macOS interaction. There is no standalone GTK app window on other desktops.

The original screenshots below show the initial port with demo data. They predate Settings, additional homes, Focus and Clipboard:

![Initial GNOME panel](screenshots/panel.png)

<img src="screenshots/pill.png" alt="Original floating pill and its card" width="390">

## Install

Use the experimental Linux assets attached to a release, when available. Existing macOS-only releases do not contain these packages. Replace `VERSION` below with the downloaded version, choose `amd64` or `arm64` for your machine, and verify the file against `SHA256SUMS-linux.txt` before installing:

```sh
sudo apt install ./hotch_VERSION-1_amd64.deb
# Log out and back in so Wayland loads the new extension, then:
gnome-extensions enable hotch@hotherside.com
```

The package installs the binary, GNOME extension and a tray launcher. It does not autostart the tray, which would duplicate the GNOME frontend. The extension starts at login while enabled. Ubuntu 24.04 or newer is the binary baseline; its default GNOME 46 does not support this extension, so use the tray or a desktop with GNOME 48–50.

The `hotch-gnome-VERSION.zip` download can alternatively be installed with `gnome-extensions install --force ./hotch-gnome-VERSION.zip`. It still requires the matching `hotch` binary in `/usr/bin` or `~/.local/bin`.

### From source

Use a current Rust toolchain from [rustup](https://rustup.rs). The distribution `cargo` on older Ubuntu releases may be too old for the D-Bus dependency. Node.js 24+ is used for development tests, not required at runtime.

```sh
git clone https://github.com/hotherside/Hotch.git
cd Hotch/linux
cargo build --release --locked
install -Dm755 target/release/hotch ~/.local/bin/hotch
install -Dm644 ../docs/marketing/brand/app-icon.png ~/.local/share/icons/hicolor/512x512/apps/hotch.png
install -Dm644 hotch.desktop ~/.local/share/applications/hotch.desktop
```

For the full GNOME frontend:

```sh
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r gnome-extension ~/.local/share/gnome-shell/extensions/hotch@hotherside.com
# Log out and back in on Wayland, then:
gnome-extensions enable hotch@hotherside.com
```

For the tray on KDE, Xfce, Cinnamon, waybar, or GNOME without the Hotch extension:

```sh
install -Dm644 hotch.desktop ~/.config/autostart/hotch.desktop
hotch &
```

Ubuntu's AppIndicator extension supports the tray. Stock GNOME generally needs “AppIndicator and KStatusNotifierItem Support”; KDE and the other listed tray hosts have their own support.

## Settings and local tools

Open the gear button in the GNOME card footer. Settings provides all six homes, system/light/dark appearance, used/remaining percentages, 30-second/1/2/5-minute refresh, provider toggles and the clipboard opt-in.

Preferences are shared with the tray and CLI in `$XDG_CONFIG_HOME/hotch/gnome.json` (default `~/.config/hotch/gnome.json`). Existing pill positions migrate in place. CLI edits reload in GNOME; tray changes apply at its next refresh or after its Refresh action:

```sh
hotch settings
hotch settings set displayMode remaining
hotch settings set refreshSeconds 120
hotch settings set providers '["claude","codex"]'
hotch settings set providers '[]'  # local tools only; no provider reads
```

Focus has explicit Timer and Stopwatch modes, preset or custom durations, a task name, pause/resume/reset, a clock on the active companion, and one completion notification. Current timer state persists across GNOME restarts; task history and daily totals are not yet ported.

Clipboard history is off by default and starts with future copies when enabled. It retains at most five text entries in memory, each capped at 20,000 characters. Select an entry to copy it again. Disabling, stopping the extension or logging out clears the history. Hotch skips supplied password-manager, concealed, transient and autogenerated MIME markers before reading text. Applications do not always supply such markers; unmarked sensitive text cannot be recognised automatically. Clipboard contents are never saved in settings or sent to a provider.

## Providers and session freshness

- **Claude** needs Claude Code installed and signed in (`claude` on `PATH`, `~/.local/bin` or `~/.claude/local`). Sign in with `claude auth login` in a terminal. Usage uses its `get_usage` request.
- **Codex** needs the Codex CLI installed and signed in (`codex login`). Usage uses `codex app-server`.

Disabled providers are not launched or scanned. These are account-metering and local metadata reads; no model prompt is submitted. No provider credential is stored by the Linux port.

Codex session status uses the local app-server's `thread/list`, including approval/input flags when available. A separate server may report a thread as `notLoaded`; the rollout fallback is less precise. Recently modified rollouts are found across dated directories, including older resumed threads. Local transcript parsing stays on the machine; only session titles, project and status summaries reach the frontend.

A failed usage update shows the provider error alongside the last successful reading, preserves that reading's timestamp, and expires cached usage after two hours. The JSON API always reports percentage **used**; display preferences affect the human-readable CLI, tray and GNOME UI.

## CLI and development

```sh
hotch usage
hotch sessions
hotch system
hotch all --json
hotch settings --json
```

Usage, sessions and settings commands also build on macOS for parser and protocol testing. System readings and the tray require Linux.

```sh
python3 tools/check_version.py
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --release --locked
node --check gnome-extension/extension.js
node --test tests/*.test.mjs
cargo install cargo-deb --locked
cargo deb --no-build
python3 tools/package_extension.py
```

Tests use synthetic data and fake vendor CLIs. Extension lifecycle tests use GNOME API doubles and do not verify actual rendering. The Debian package and extension ZIP include all frontend modules; release versions are checked against macOS sources and the release tag. See [RELEASING.md](../RELEASING.md) for release automation.

### Desktop validation

Before release or approval of a UI change, validate on GNOME 48–50 with Wayland:

1. Open all six pages and Settings; scroll the long Settings/AI pages on a small display.
2. Switch through every home and back to the top bar repeatedly; verify the card survives, edge anchoring, drag/save, monitor disconnect and fullscreen behavior.
3. Check light, dark and system appearance, keyboard focus, readable percentages and used/remaining mode. Critical warnings must still reflect high usage.
4. Change preferences with the UI and CLI, restart GNOME and verify persistence. Disable a provider and confirm its reads and rows stop.
5. Start/pause/resume/reset both Focus modes; restart GNOME mid-run and confirm one completion notification.
6. Enable clipboard history with synthetic text; test copy-back, limits, clear, disable and the supplied privacy-marker fixtures. Confirm no clipboard text is written to disk.
7. Check live provider sign-in/error recovery with an authorised test account; screenshots must use demo data. Install the built package on the matching architecture.

For nested-shell screenshots, the development preview opens the pages and saves `<prefix>-<page>.png`:

```sh
HOTCH_PREVIEW=/tmp/hotch dbus-run-session -- gnome-shell --devkit --wayland
```

The Rust parsers mirror `Sources/Hotch/Providers/ClaudeCodeBridge.swift`, `CodexAppServer.swift` and `SessionMonitor.swift`; update both implementations when vendor shapes change. The tray label currently uses a pinned `ksni` fork for Ubuntu's Ayatana label extension; remove the patch after a compatible upstream release is available.

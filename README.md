# Hotch

Hotch is a native macOS companion for a glance at AI plan usage, active Claude Code and Codex work, and Mac activity. Keep it on a screen edge, by the Dock, around the notch, floating on your desktop, or in the menu bar. It is built with Swift and SwiftUI, targets macOS 14 or later, and its one third-party package is [Sparkle](https://sparkle-project.org), which keeps the Mac app up to date.

[![Hotch on the screen edge: the tab opens AI usage and live agent sessions, a sweep turns the desktop from dark to light, then Mac health, an alert, and the original notch view](docs/marketing/video/hotch-reel.gif)](docs/marketing/video/hotch-reel.mp4)

Recorded from the real app with demo data. [Watch the full 26-second reel](docs/marketing/video/hotch-reel.mp4), with the pill, orb and Dock homes.

**Try it:** [Download for macOS](https://github.com/hotherside/Hotch/releases/latest) · [Build from source](#build-from-source) · [Report a bug](https://github.com/hotherside/Hotch/issues/new/choose) · [Contribute](CONTRIBUTING.md)

> **Project status:** Hotch is an independent project and is not affiliated with Apple, Anthropic, OpenAI, xAI, Moonshot AI, or DeepSeek. Provider data and availability depend on vendor accounts and interfaces, which can change.

## Features

- Usage windows for Claude and Codex, plus optional balance or usage sources for Grok, Kimi, and DeepSeek.
- Live Claude Code and Codex session summaries, with a shortcut to bring the related app to the front. This brings forward the app surface; it does not guarantee opening a particular thread.
- CPU, memory, network, disk, battery, process, and optional hardware sensor readings.
- A Focus timer or stopwatch with explicit controls and a persistent clock on your selected companion.
- Discoverable Backpack mode for keeping agents awake with the lid closed, with one-time helper approval and automatic limits.
- Optional in-memory clipboard history and brief alerts.
- A compact three-readout tab on the left, right or bottom, with all six sections inside the card; the original Notch view; floating pill and orb; or menu bar only.

![Six homes for Hotch: the screen edge, the notch, the menu bar, a floating pill, an orb, and beside the Dock](docs/marketing/stills/hotch-homes.jpg)

<img src="docs/marketing/brand/app-icon.png" width="96" alt="Hotch app icon: a companion curve and warm signal">

<details>
<summary>Tour all six sections</summary>

![Native view tour with demo data: Now, AI, Sessions, Mac, Focus, Clipboard and an alert](docs/marketing/screenshots/native-tour.gif)

Native view snapshots with demo data, one per section, ending on an alert.

</details>

<details>
<summary>Focus and the original Notch view</summary>

<img src="docs/marketing/screenshots/focus-setup.png" width="412" alt="Focus setup with Timer and Stopwatch modes and explicit duration choices">

![Focus running in Notch view, with a persistent clock above the tabs](docs/marketing/screenshots/notch-focus.png)

</details>

## Install

Download `Hotch-2.3.0.dmg` from the [latest release](https://github.com/hotherside/Hotch/releases/latest), open it and drag **Hotch** into **Applications**. Then open Hotch from your Applications folder. It runs on macOS 14 Sonoma or later, on Apple silicon and Intel Macs.

Hotch is signed with a Developer ID and notarised by Apple, so it opens like any other app. A short welcome helps you choose where it lives, then points to it.

From 2.4.0, Hotch updates itself. Once a day it checks for a new version and shows what changed, with Install, Remind Me Later and Skip This Version. To have updates download and install on their own instead, or to stop checking, use **Settings → App updates**; automatic installs wait until the card is closed and no Focus timer or Backpack session is running. Hotch 2.3.0 and earlier cannot update themselves: download the latest version once more and later ones arrive in the app.

To check your download, compare `shasum -a 256 ~/Downloads/Hotch-2.3.0.dmg` with the SHA-256 shown next to the file on the release page.

Prefer to build it yourself? See [Build from source](#build-from-source).

## Build from source

### Experimental Linux support

Linux has a separate Rust backend and GNOME Shell frontend. It now includes Settings, top-bar/pill/orb/screen-edge placements, light/dark appearance, Focus, and optional in-memory clipboard history on GNOME 48–50. Other Linux desktops use a simpler tray with shared preferences through `hotch settings`. It supports Claude and Codex; macOS-specific integration and additional providers remain unavailable. See the [Linux installation guide and feature matrix](linux/README.md) for the supported combinations and current limitations.

Linux packages and an extension ZIP are built in CI. Published Linux assets are experimental and are separate from the signed/notarized macOS download; check the release's actual attached assets before installing.

### macOS

You need a Mac with Swift 6 and the macOS 26 SDK or newer to compile the optional Liquid Glass code. The resulting app runs on macOS 14 or later. Xcode 26.3 is the CI toolchain; matching Command Line Tools can also work. The Makefile prefers a locally installed 26.x SDK to avoid missing SwiftUI macro plugins in some newer CLT installations.

```sh
git clone https://github.com/hotherside/Hotch.git
cd Hotch
make app
```

The app bundle is created at `build/Hotch.app`. `make run` builds it and launches it. `make check` runs the project's build and local validation checks. `make app-universal` builds Apple Silicon and Intel slices and requires a toolchain that can cross-compile both architectures.

## Connect providers

On first launch, a short welcome letter introduces Hotch. One setup screen then helps you choose placement, detects configured providers, and offers optional clipboard history, and Hotch points to where it now lives when you finish. You can replay the welcome from Settings. Open Settings from the Hotch menu bar item or card to configure providers. Claude reads plan usage through Claude Code, which must be installed and signed in. Codex reads usage and thread metadata through the Codex app-server; the Codex app/CLI and a signed-in account are needed. Grok, Kimi, and DeepSeek are optional and require the corresponding vendor API key; Grok also needs a team ID. Provider credentials are sent to their respective vendor to request usage or balance data. These requests do not run model inference.

Data sources and setup details can change with vendor software and account plans. Check the provider's status in Settings if a row cannot connect.

## Privacy and data handling

Hotch is local-first: its settings, usage history, and session summaries are stored on your Mac. To provide live readings, it makes account or billing requests to the configured provider, and launches the installed Claude Code or Codex client where required. Those vendors receive the requests they need to answer. Hotch does not submit prompts for model inference. On macOS it also asks `hotch.hotherside.com` once a day whether a newer Hotch exists; that request names only the Hotch and Sparkle versions, and you can turn it off in Settings → App updates. An update itself is downloaded from GitHub only when you choose Install or turn on automatic installs. See [Software updates](SHARING.md#software-updates-macos).

The experimental Linux port also asks GitHub's public releases API once a day whether a newer Linux release exists, sending only its version in the User-Agent. It never downloads or installs anything. Turn the check off in its Settings or with `hotch settings set updateChecks false`.

Hotch reads local Claude Code and Codex session metadata to show session titles, status, and context usage. Those local logs may contain conversation content; Hotch parses them locally and does not upload transcripts. Provider requests and the vendor clients remain subject to their own privacy policies.

Optional clipboard history stores up to five recent text items in memory only, truncates long text, and skips pasteboard writes marked concealed, transient, or autogenerated. Quitting or disabling the feature clears its in-memory list. Review [Privacy and data handling](SHARING.md) for more detail.

Provider API keys you add are stored as plaintext files restricted to your macOS user, not embedded in the app. Software running as that same user can read them. Apple signing and notarization credentials are maintainer-only build credentials and are not shipped. See the [publication security review](docs/security-review.md) for the scope and findings of the initial audit.

Backpack mode installs a privileged helper only after the user approves it in System Settings. It temporarily changes sleep behavior while active and has battery, thermal, time, and agent-completion guardrails. Optional temperature, fan, and power readings use undocumented Apple sensor interfaces and can vary across Mac models and macOS releases.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, checks, and small ways to help. Please read [SECURITY.md](SECURITY.md) before reporting a vulnerability. The project is distributed under the MIT License; see [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).

If Hotch is useful to you, consider starring the repository. Bug reports, documentation improvements, and focused pull requests are welcome.

## Releases

Downloads on the [Releases page](https://github.com/hotherside/Hotch/releases) are signed with the maintainer's Developer ID and notarised by Apple. See [RELEASING.md](RELEASING.md) for the release steps. Builds you make from source are not notarised, and Backpack mode only works in the signed download.

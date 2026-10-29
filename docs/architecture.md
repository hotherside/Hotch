# Architecture

Hotch is a Swift Package that builds a menu-bar macOS app and a small helper executable. It uses SwiftUI for presentation and Apple frameworks for app lifecycle, process/system readings, and helper registration. There are no third-party package dependencies.

## Main areas

- `Sources/Hotch/` contains the app, settings, floating/edge/menu-bar surfaces, and local system sampling.
- `Sources/Hotch/Providers/` contains usage and balance sources, local session readers, credential storage, and provider state.
- `Sources/BackpackShared/` defines the XPC contract shared by the app and helper.
- `Sources/HotchBackpackHelper/` contains the privileged helper used by Backpack mode.
- `Support/` contains the launch-daemon property list embedded in the app bundle.
- `Makefile` builds the app bundle, packages disk images, and provides maintainer release and validation targets.

## Data flow and boundaries

The app reads provider credentials or local client status from the current user's machine. Claude usage is requested from Claude Code's local interface; Codex usage and thread metadata are read through the installed Codex app-server and local session files. Grok, Kimi, and DeepSeek use vendor account APIs when configured. These paths provide account usage or billing data; they do not submit prompts for inference. Session files can contain conversation content, so parsers should extract only the fields the UI needs and must not transmit transcript text.

System readings are sampled locally. Advanced sensor readings use undocumented Apple interfaces, so changes to those readers need care and real hardware review. Backpack mode crosses a privilege boundary: the app must be properly signed for the helper, the user approves the helper through macOS, and app/helper communication uses XPC. Keep helper behavior narrow and fail safely so normal sleep is restored if the app disappears.

System sampling follows visible demand. Ordinary cards keep their live readings and histories, while process enumeration runs only for the Mac overview and CPU/memory details. Capabilities combine across clients so closing one view cannot disable another view's readings. Process CPU uses 100% for one logical core; whole-Mac CPU averages across all logical cores. Window sizing coalesces intrinsic-size callbacks and avoids repeating resize/shadow work when the measured size is unchanged.

Clipboard history is in-memory, text-only, and optional. Preserve its size limit, lifetime, disable behavior, and concealed/transient marker checks when changing it.

## Checks

`make check` is the repository's combined build and local validation entry point. `make helper-selftest` runs the helper's scripted state-machine check without issuing real power-management commands. CI can compile and run scripted checks, but physical Mac sensor behavior, signing prompts, and lid-close sleep behavior require manual validation on supported hardware.

## Experimental Linux port

`linux/` is an independent Rust executable, with a GNOME Shell frontend in `linux/gnome-extension/`. It shares no runtime code with the macOS SwiftUI views. The binary reads local vendor CLIs and session metadata, and exposes stable JSON for the frontend or scripts; its tray uses the same providers and settings.

`settings.rs` and the GNOME model validate preferences in `~/.config/hotch/gnome.json` (or `XDG_CONFIG_HOME`). The extension watches that file for CLI edits. Provider toggles gate both usage child processes and session scanning. Usage errors retain an explicitly stale reading for at most two hours. Codex thread status takes precedence over the local rollout fallback.

GNOME owns placement, appearance, Focus and clipboard state. Focus stores only the current run with wall-clock timing. Clipboard contents stay in memory, are disabled by default, skip supplied sensitive MIME markers, and are cleared on disable. Every signal, process and main-loop source is cleaned up when the extension stops. Tests cover pure state, CLI fixtures and the extension lifecycle with GNOME API doubles; desktop rendering and Wayland behavior still require Linux validation.

Linux checks build Debian packages and an extension ZIP. The separate release workflow builds amd64/arm64 assets from an existing release tag, checks all macOS/Linux versions, and uploads Linux checksums. See the Linux README for feature gaps and the desktop validation checklist.

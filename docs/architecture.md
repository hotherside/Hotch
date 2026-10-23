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

Clipboard history is in-memory, text-only, and optional. Preserve its size limit, lifetime, disable behavior, and concealed/transient marker checks when changing it.

## Checks

`make check` is the repository's combined build and local validation entry point. `make helper-selftest` runs the helper's scripted state-machine check without issuing real power-management commands. CI can compile and run scripted checks, but physical Mac sensor behavior, signing prompts, and lid-close sleep behavior require manual validation on supported hardware.

# 2.2.0 validation

Local validation completed on 23 October 2026.

- `make check`: build succeeded with no compiler warnings or errors; 349 app checks and 75 simulated helper checks passed.
- Rail checks cover six fixed targets, three edges, three display layouts (including negative coordinates), changing card heights and diagonal pointer paths.
- Handoff checks cover known ancestry, unidentified terminals, ambiguous hosts and rejected launches. These checks do not activate real session windows.
- Welcome checks cover fresh installs, explicit choices, upgrades and unfinished introductions.
- Focus checks exercise explicit Timer/Stopwatch setup, custom validation, live clock publication, pause, resume, completion and persistence behavior.
- Notch checks cover camera/menu-strip clearance, negative display coordinates, compact clock rollover and legacy preference restoration.
- Credential checks use temporary synthetic files to verify directory mode `0700`, file mode `0600`, traversal rejection and symlink rejection.
- `make app`: produced the local architecture `build/Hotch.app`, version 2.2.0. `codesign --verify --deep --strict` passed. This is not a notarized release.
- Native UI smoke check: opened Now and AI from the rail, dismissed a pinned card with Escape, opened Settings and traversed all three welcome steps. Existing clipboard opt-in stayed enabled during the upgrade. Verified invalid custom duration disables Start; started and paused a stopwatch; started, paused, resumed and finished a countdown; carried the live clock through rail, virtual Notch and floating orb placement; opened Backpack details without activating its helper. Restored screen-edge placement and removed only the two synthetic verification history entries.
- Visually inspected native snapshots for the overview, light/dark appearance, stale/disconnected/empty states, Focus, Clipboard, memory detail, Backpack, rail and menu-bar icon. Checked the restored Notch layout and branded Settings in the live app. Fixed Notch click pinning and a screen-reader clock value discovered during this pass.

The GIF in the README is a sequence of native view snapshots with demo data. It does not record hover timing. Pointer feel, multiple physical displays, Dock auto-hide, full VoiceOver navigation and Reduce Motion/Transparency need a hands-on pass. Intel/macOS 14 execution, real camera-cutout hardware, lid-close behavior and notarization were not validated here. The public repository's Actions tab records CI results separately from these local checks.

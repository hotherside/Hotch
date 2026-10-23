# Contributing

Thanks for taking a look. Small, focused changes are easiest to review. Please open an issue first for larger changes so the scope and behavior can be discussed before implementation.

## Get started

Hotch is a native Swift and SwiftUI macOS app with no third-party package dependencies. It targets macOS 14 and uses Swift tools version 6.

```sh
make app
make run
make check
```

`make app` creates `build/Hotch.app`; `make run` launches it. Use a Mac with a compatible Swift toolchain and macOS SDK. Hardware sensor readings and Backpack mode should be validated on real Mac hardware; CI can compile the code and run scripted checks but cannot validate all models, sensors, or lid behavior.

## Good first contributions

- Improve provider setup explanations or error states, based on current provider behavior.
- Fix a clear accessibility, layout, or keyboard-navigation issue.
- Add a focused parser or state-machine check for a bug that can be tested without personal account data.
- Improve documentation or clarify a privacy boundary.

Avoid adding telemetry, collecting transcripts, or introducing credential handling without discussing the privacy and security implications first.

## Pull requests

Keep the change focused, describe the user-visible behavior, and include the command(s) you ran. Do not include credentials, personal logs, screenshots with private information, or generated build products. For UI changes, attach a sanitized screenshot when useful. For provider changes, explain which official/local interface is used and what data the request sends.

Before opening a pull request, run `make check` where possible. If your environment cannot run it, state the limitation and include the relevant build or review evidence you do have. New behavior should include a meaningful check where practical; do not add tests that only duplicate implementation details.

## Project map

See [docs/architecture.md](docs/architecture.md) for the main source areas and boundaries. Release signing and packaging are maintainer tasks described in [RELEASING.md](RELEASING.md).

## UI fixtures

These commands use injected demo data without requesting provider usage:

```sh
.build/release/Hotch --snapshot-overview build/overview.png --snapshot-dark
.build/release/Hotch --snapshot-overview build/stale.png --snapshot-dark --snapshot-fixture stale
.build/release/Hotch --snapshot-story build/story --snapshot-dark --display-mode remaining
swift tools/render-demo.swift build/story docs/images/native-tour.gif
```

Available fixtures: `rich`, `empty`, `stale`, `disconnected`, `highpressure`, `needsinput`. Omit `--snapshot-dark` for light mode. Use `--snapshot-page now|ai|agents|mac|focus|clipboard` to select an overview page. Keep screenshots free of real sessions, clipboard text and account details.

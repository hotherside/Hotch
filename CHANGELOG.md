# Changelog

Notable user-facing changes are recorded here.

## Unreleased

- Linux: say when a newer Linux release is out, checking GitHub at most once a day and on demand (`hotch update-check`). A quiet line in the GNOME card footer and a tray menu item link to the release page, with **Skip this version**; Hotch never downloads or installs updates. Turn it off in Settings or with `hotch settings set updateChecks false`. Releases that change only macOS no longer attach Linux packages, so Linux users hear only about releases that change Linux.
- Linux: **Check now** in Settings says when it could not check (offline, rate-limited, or no package for this machine). `hotch settings set updateSkipped` accepts `v2.4.0` as well as `2.4.0`.

## 2.3.0

- The macOS app is unchanged from 2.2.0 apart from its version number; this release adds Linux.
- Add experimental Linux support, contributed by Simon (@sire6): a GNOME companion, a tray on other desktops, and a Rust CLI for Claude/Codex usage, sessions, CPU, memory and battery.
- Add Linux Settings with top bar, pill, orb and three screen-edge placements, system/light/dark appearance, used/remaining display, provider controls and refresh intervals.
- Add a persistent GNOME Focus timer/stopwatch and an optional five-entry clipboard history held only in memory, with supplied password-manager privacy markers skipped.
- Show failed Linux provider refreshes with the original reading age and a two-hour expiry; use Codex thread status and discover older resumed rollouts.
- Publish version-checked amd64/arm64 Debian packages, a standalone GNOME extension ZIP and Linux checksums with each release. Linux remains experimental and has not been validated on a desktop by the maintainer; see its support matrix and desktop validation checklist.

## 2.2.0

- Keep all six navigation targets in a taller, gentler screen-edge rail, with smaller live readouts, deliberate hover switching and stable card attachment.
- Introduce the Quiet companion home view: attention first, clearer AI capacity and freshness, and a concise Mac summary.
- Replace the notch icon with a companion curve and warm signal; improve text, keyboard focus and system accessibility support.
- Restore Notch placement alongside screen edges, floating companions and the menu bar, including displays without a camera cutout.
- Simplify Focus into Timer and Stopwatch modes, make duration choices explicit and keep the clock visible on the active companion.
- Add labelled Backpack entry points on Now, in footers and in the menu; opening them explains setup before starting a session.
- Harden local API-key storage permissions and add filesystem security checks.
- Greet new users with a short welcome letter and one setup screen for placement, provider detection and clipboard history, then point to where Hotch now lives. A copy opened from the disk image is told so in the letter instead of an alert. Clipboard history starts off on fresh installs and preserves existing choices on upgrades.
- Stop macOS asking for access to the Desktop or Documents folder over the welcome when Hotch is opened from a terminal in a project there, as `make run` does. The Claude Code usage read no longer looks in that folder.
- Confirm session host handoffs before dismissing the panel; explain unavailable or ambiguous destinations.
- Prepare the project for public contribution with build guidance, privacy and security notes, and CI checks.
- Refresh provider setup, session, system-monitoring, and clipboard documentation to match the current app.

## 2.1.4

- Current pre-open-source source baseline. See the repository history for earlier development changes.

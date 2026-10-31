# Changelog

Notable user-facing changes are recorded here.

## Unreleased

## 2.5.0

- macOS: four tabs instead of six, shown as symbols beside the page's name. **Hotch** is home: usage, CPU, memory and thermals, a one-click Focus start and the last two clipboard items. **AI** puts each provider's plan windows above the sessions running on it. **Mac** is unchanged. **Desk** holds Focus, the clipboard and Backpack mode.
- macOS: a Claude Code session shows the step it is on and how long that step has run, and a session waiting on you shows the command it wants approved. Codex sessions keep their project line.
- macOS: an alert on the screen-edge tab is now a label beside the tab instead of a bar growing out of it, and the sessions ring turns amber while a session waits on you.
- macOS: the screen-edge tab is one control. Hovering tints the whole tab and opens the card; a click keeps it open, also when it opened on hover, and a second click closes it without the hover reopening it. Its readouts no longer highlight or switch pages one by one, since the card's tabs do that.
- macOS: the edge tab shows a usage ring for each AI provider, so Claude and Codex both appear, and Settings → Where Hotch lives chooses its readouts: Claude, Codex, Sessions, Memory and CPU, one slot each, and whether a running Focus timer takes the last slot.
- macOS: switching tabs swaps the page in one frame while the card's height eases to fit. The page no longer blanks or cross-fades, the card no longer drops off its anchor when it grows, and clicking tabs quickly can no longer cut off the bottom of the card.
- macOS: an available update is a green button at the bottom left of every tab.
- macOS: Backpack mode lives on the Desk tab; the footer shows it only while it is on.
- macOS: amber and clay status words are darker in light mode, so small text clears 4.5:1 contrast.

## 2.4.0

- macOS: Hotch now keeps itself up to date with Sparkle. Once a day it checks for a new version and shows the release notes with Install, Remind Me Later and Skip This Version. Check for Updates… is in Settings → App updates and the Hotch menu.
- macOS: if you have Hotch 2.2.0 or 2.3.0, download this version from the release page once, as those versions cannot update themselves. Later versions arrive in the app.
- macOS: an update window never appears over the welcome or during a Focus run. A line in the card says an update is available and brings the window back.
- macOS: Download and install updates automatically is an opt-in in Settings. It waits until the card is closed and no Focus timer or Backpack session is running, or until you quit.
- macOS: a Focus timer running when an update installs carries on in the new version.
- macOS: the update check sends only the Hotch and Sparkle versions to hotch.hotherside.com and can be turned off. Sparkle's anonymous system profile is off. Sparkle is Hotch's first third-party package.
- Linux: the GNOME top-bar button is back. 2.3.0 left it out of the panel, so the default top-bar home showed nothing and the card opened at the screen's left edge. Fixed by Simon (@sire6).
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

# Privacy and data handling

Hotch runs on your Mac. Settings and usage history are stored locally. A live usage or balance reading requires a request to the relevant provider; requests are for account metering or billing and do not ask a model to generate a response. Provider terms and privacy policies apply to those requests. On macOS, the only other request is the daily update check described under [Software updates](#software-updates-macos).

## Local sources Hotch reads

- Claude Code exposes plan usage through its local client interface. Hotch starts the installed client in a no-prompt, no-session mode and does not read, copy, or store its sign-in credential.
- Codex usage and thread metadata come from the local Codex app-server, with local session files used for context details and fallback readings. Hotch does not upload transcripts.
- System readings use macOS APIs and, when enabled, undocumented hardware sensor interfaces. Process summaries cover processes readable to the current user.
- Kimi can read the access token maintained by the locally installed Kimi CLI, read-only, to request coding-plan usage from Kimi. Hotch does not copy or rotate that token.
- Settings and usage history are kept in Hotch's application support data. Optional API keys entered for Grok, Kimi, and DeepSeek are stored as plaintext files with mode `0600` inside a directory restricted to the current user (`0700`), and sent to the matching vendor when requesting account data. These permissions protect against other local users; software running as your user can still read the files. Hotch does not manage the vendor's account or rotate credentials owned by another app.

## Downloaded builds and maintainer credentials

Each person connects their own provider accounts after installing Hotch. The app bundle contains code, its icon, metadata, and the optional helper; it does not include the maintainer's provider accounts or Apple sign-in password.

Signing and notarization happen on the maintainer's Mac. The release tool references a named `notarytool` Keychain profile. The profile and its app-specific password are not copied into the app or disk image. A Developer ID certificate's public identity and Apple team identifier are visible signature metadata and do not allow a recipient to sign code as the maintainer. Someone building a fork must supply their own signing credentials and update the helper's team requirement.

Updates are signed a second time with the maintainer's Sparkle EdDSA key, whose private half stays in the maintainer's Keychain. The app carries only the public half (`SUPublicEDKey`), which can check a signature but not make one. A fork that ships its own updates needs its own key and feed address.

## Software updates (macOS)

From 2.4.0, the macOS app uses [Sparkle](https://sparkle-project.org) to keep itself up to date.

- **The check:** once a day, Hotch requests `https://hotch.hotherside.com/appcast.xml`, a public list of releases served by GitHub Pages. The request is a plain HTTPS `GET` with no query string; its `User-Agent` names only the Hotch and Sparkle versions (for example `Hotch/2.4.0 Sparkle/2.10.1`). Sparkle's anonymous system profile (model, macOS version, CPU and similar) is switched off and is never sent. As with any web request, GitHub, which serves the list, can see your IP address.
- **The download:** an update is fetched from the project's GitHub releases only after you choose Install, or automatically if you turned on automatic installs. Release notes are part of the list itself, so reading them needs no further request.
- **Verification:** before installing, Sparkle checks the update's EdDSA signature against the key built into Hotch and that the new app's Apple code signature is intact. An update that fails is refused. Releases are also signed with the maintainer's Developer ID and notarised by Apple, like the disk image.
- **Your choice:** by default Hotch asks first, showing the release notes with Install, Remind Me Later and Skip This Version. **Settings → App updates** has *Download and install updates automatically* (off by default; it installs only when the card is closed and no Focus timer or Backpack session is running, or else when you quit) and *Check for updates automatically*. Turning off the second stops the daily request entirely; **Check for Updates…** in Settings or the Hotch menu still checks on demand.
- **What stays:** an update replaces the app in place, so settings, focus history and provider keys are untouched. A Focus timer running during an update carries on in the new version. Installing during a Backpack session ends it, as quitting does, and normal sleep is restored.

## Clipboard history

Clipboard history is optional and can be disabled in Settings. While enabled, Hotch samples the general pasteboard for text, retains at most five recent entries in memory, truncates each string to 20,000 characters, and clears entries when disabled or when Hotch quits. It skips pasteboard writes marked concealed, transient, or autogenerated. The marker is supplied by the writing app; content without such a marker may be captured. Do not rely on this feature for sensitive material.

## Backpack mode

Backpack mode uses a small privileged helper to temporarily prevent lid-close sleep. macOS requires administrator approval for this helper in System Settings. The helper restores normal sleep if Hotch stops checking in; the app also ends a session on conditions such as agent completion, low battery, thermal pressure, a time limit, or lid opening. Because this changes system sleep behavior, enable it only when you understand the effect and can monitor the Mac.

## Diagnostics and reports

Hotch does not have a project telemetry or crash-upload service. If you choose to attach logs or screenshots to an issue, inspect them first: logs and screenshots can contain local paths, project names, provider status, or other personal details. Never include API keys, auth files, tokens, or raw conversation transcripts in a public report.

To remove Hotch's local settings and history, quit the app, delete `~/Library/Application Support/Hotch`, and remove the app. The app does not delete session data maintained by Claude Code, Codex, or other providers.

## Experimental Linux frontend

The Linux port uses the local Claude Code and Codex CLIs for metering and session metadata. It stores no provider credentials and submits no model prompts. Disabling a provider stops both its usage requests and session scans. Local transcript parsing does not upload conversation contents.

Preferences, the current Focus timer/task name and the floating position are stored in `~/.config/hotch/gnome.json` (or `XDG_CONFIG_HOME`), with writes restricted to the current user. Clipboard history is optional and off by default. It starts with future copies, keeps at most five text entries (20,000 characters each) in memory, and is cleared when disabled or the GNOME extension stops. The Linux frontend skips password-manager/concealed/transient/autogenerated MIME markers when applications supply them. It cannot identify unmarked sensitive text. Clipboard text is neither persisted nor sent to providers.

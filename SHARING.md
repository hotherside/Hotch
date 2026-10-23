# Hotch

Hover the top centre of any screen — or click the menu bar icon — to see how much
of your AI subscriptions you have used. Claude, Codex, Gemini, Grok, Kimi,
DeepSeek.

Meters show **Used** by default, so they fill as you spend and a full ring means a
window is nearly out. If you would rather read how much is left, flip it in
**Settings → Display**. Either way the rings and bars fill in the same direction
and turn red when a window is nearly spent.

Built by Hojae Jung (hello@hotherside.com)

---

## Installing

macOS 14 or later. Apple Silicon or Intel.

1. Open the DMG and drag **Hotch.app** onto the **Applications** shortcut.
2. Open it from Applications.

That is all of it. No security warning, no trip to System Settings, no Terminal.
The app is signed with an Apple Developer ID and **notarized** — Apple has scanned
this exact build and issued a ticket, stapled into both the disk image and the app
itself — so macOS opens it without asking anyone to vouch for it, and without
needing to reach Apple over the network to check.

Do the drag in step 1 rather than opening Hotch inside the disk image window.
macOS runs an app opened from a disk image as a temporary copy in a randomised
folder, which works but cannot keep Launch at Login. Hotch notices and says so
rather than letting it fail quietly.

The icon appears in the menu bar; there is no Dock icon and no window. Settings
opens by itself the first time, because nothing is connected yet and that is where
you connect it.

If you have seen instructions elsewhere telling you to run `xattr` to strip a
quarantine flag, that is for unsigned apps and is not needed here.

## Building from source instead

No Xcode needed, only the Command Line Tools, and there are zero third-party
dependencies.

```bash
xcode-select --install     # once, if you have never installed the CLT
cd Hotch
make run
```

## Connecting your accounts

Open **Settings** — either the gear in the bottom-right of the panel, or
right-click the menu bar icon. (The gear is there because a busy menu bar can hide
Hotch's icon entirely.) Nothing is connected by default and nothing is read
without you asking.

On first launch Hotch switches on whichever providers already work on your Mac —
if you use the Codex CLI, its row is live on your first hover with nothing to set
up. Anything it cannot read stays off rather than showing you an empty row.

| Provider | What you do | What you get |
|---|---|---|
| **Claude** | `Connect…` once, sign in via browser | 5-hour and 7-day plan windows |
| **Codex** | `brew install --cask codex`, then run `codex` once and sign in | live plan windows |
| **Gemini** | run the Gemini CLI once and sign in with Google | daily quota |
| **Kimi** | paste a Kimi **for Coding** key | plan windows |
| **Grok** | paste an xAI management key + team ID | prepaid **API credit**, not SuperGrok quota |
| **DeepSeek** | paste an API key | prepaid **balance** |

Claude asks for exactly one thing: a browser sign-in, once. It will never ask for
a Keychain password — if some other app does, that is not this one.

Codex needs **both** halves of its row above: the CLI installed *and* signed in.
Its row in Settings says which part is missing and gives you the command to copy.
The CLI is genuinely required — OpenAI's usage endpoint is closed to third-party
apps, so asking the CLI is the only route that answers, and Hotch only ever reads
the sign-in the CLI already keeps. A ChatGPT plan that does not include Codex
reports **no Codex usage limits** — that is the account, not a fault, and there is
nothing to fix.

Grok and DeepSeek report money remaining rather than subscription usage, because
that is the only thing those vendors expose.

## What it does and does not do

- **Spends no tokens.** Every call is account metering or billing — never
  inference. No prompt is ever sent, no model ever runs. Reading the meter does
  not move it.
- **Credentials stay on your Mac**, in `~/Library/Application Support/Hotch/`
  as `0600` files, and are sent only to the vendor they belong to.
- **It never reads another app's Keychain items** — not Claude Code's, not
  anything else's. That is why it cannot produce an "Allow / Always Allow"
  prompt. The only Keychain item it will ever look for is one an older version of
  Hotch created itself, which it moves into the folder above and then deletes;
  on a fresh install there is nothing there and it never touches the Keychain.
- **Vendor credentials are read-only.** It never writes to, or refreshes, a
  credential another tool owns — doing so would log that tool out.
- **Uninstalling is complete**: delete the app and
  `~/Library/Application Support/Hotch/`. Nothing else is touched.

## Uninstalling

```bash
rm -rf /Applications/Hotch.app ~/Library/Application\ Support/Hotch
```

Then remove it from `System Settings → General → Login Items` if you enabled
Launch at Login.

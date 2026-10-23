# Releasing a signed, notarized Hotch

Notarization is what makes the DMG open on a double click on someone else's Mac,
with no `xattr` step and no security warning.

## Why this is no longer optional

It was treated as polish. Then the first person to install from the DMG met the
Gatekeeper dialog and clicked **Move to Bin**, which is the highlighted default
and reads like the only button that finishes anything. They deleted the app
instead of installing it.

The DMG window now spells the step out before they get there (see
`Sources/Hotch/Views/InstallerArt.swift`), and that helps, but it is a warning
label on a bad door. Notarization removes the dialog. Everything below is one
sitting's work and then never again.

The certificate is already in place; what is missing is a stored notarytool
credential. Current state, any time:

```bash
make signing-status
```

`notarytool` and `stapler` ship with the Command Line Tools, so **full Xcode is
not required.**

---

## One-time setup

Step 1 is **already done** — `make signing-status` prints the identity. Skip to
step 2, which is the only thing standing between the current DMG and one that
opens without a warning.

### 1. Get the certificate (done)

A signing request has already been generated, the certificate issued, and both
halves imported — `make signing-status` prints the identity, so nothing here
needs doing again.

> ### ⚠️ The private key is currently inside this project folder
>
> ```
> Hotch-signing/Hotch-developerID.key      ← private key, 0600
> Hotch-signing/Hotch-developerID.certSigningRequest
> Hotch-signing/developerID_application.cer
> ```
>
> It was at `~/Desktop/Hotch-signing/`, deliberately outside the project, and
> moved in when the folder was renamed. That is worth fixing: this folder is the
> thing that gets zipped, shared, or pushed to a repo, and the key is what lets
> anyone sign software as **Hojae Jung (WCJ787853P)**. The `0600` mode protects it
> from other users on this Mac; it does nothing about being copied somewhere else.
>
> The key is already in the login keychain, so signing does not need the file at
> all — it is only a backup for signing from another Mac. Move it back out:
>
> ```bash
> mv Hotch-signing ~/Desktop/Hotch-signing
> ```
>
> If it ever does leak, revoke the certificate in the developer portal and issue
> a new one. **Never commit it.**

1. Go to <https://developer.apple.com/account/resources/certificates/add>
2. Choose **Developer ID → Developer ID Application**
3. Upload `Hotch-developerID.certSigningRequest`
4. Download the issued `developerID_application.cer` into the same folder

Then import both halves — the certificate and its key have to be in one keychain
before they form a usable identity:

```bash
cd Hotch-signing      # or ~/Desktop/Hotch-signing once moved back out
security import developerID_application.cer -k ~/Library/Keychains/login.keychain-db
security import Hotch-developerID.key    -k ~/Library/Keychains/login.keychain-db \
  -T /usr/bin/codesign
```

Confirm it took:

```bash
make signing-status      # should print the identity and team id
```

If the certificate appears but is reported invalid, the Apple Worldwide Developer
Relations intermediate is missing — download G3 from
<https://www.apple.com/certificateauthority/> and double-click it.

Once imported you can delete the `.key` file; the key is in the keychain. Keep a
backup somewhere safe if you want to sign from another Mac (`security export`),
otherwise you will just generate a new certificate next time.

### 2. Store notarization credentials — the outstanding step

Notarization needs to authenticate to Apple. Use an **app-specific password**,
not your Apple ID password:

1. Sign in at <https://account.apple.com>. Under **Sign-In and Security**, open
   **App-Specific Passwords** and generate one; label it `notarytool`. Copy it
   then — it is shown once.
2. Your Team ID is `WCJ787853P`, the value in brackets in `make signing-status`.

Then run this **yourself**. It takes a credential, so it is not something to hand
to anyone else, including an assistant:

```bash
xcrun notarytool store-credentials hotch --apple-id <your-apple-id-email> --team-id WCJ787853P
```

Leaving `--password` off makes it prompt, so the password never lands in shell
history. It is stored in the keychain under the profile name `hotch`; you
never need to type it again. Confirm with:

```bash
xcrun notarytool history --keychain-profile hotch
```

---

## Every release

```bash
make release NOTARY_PROFILE=Hotch
```

One target, because the order matters and getting it wrong is invisible. It
runs: build universal → notarize the **app** and staple its ticket → build the
disk image around the stapled app → notarize and staple the **image** →
`make verify-release`.

`make dmg` and `make notarize` still exist and still work, but the two of them
alone ship a subtly broken build — see below.

### Why the app is notarized separately from the image

Stapling only the disk image is the mistake this pipeline used to make, and
nothing in the old checks caught it. `spctl` passed. `stapler validate` passed
on the DMG. The 1.0 build was shipped that way.

The image is a delivery container that gets ejected and thrown away. What
survives is the `.app` dragged out of it, and that copy carries a notarization
ticket only if one was stapled **into the bundle before the image was built**.
Without it Gatekeeper has to ask Apple over the network at first launch, so a
recipient who is offline — on a plane, on a locked-down corporate network, or
just behind a firewall that blocks Apple's notary endpoint — gets *"Apple could
not verify Hotch is free of malware"*, whose two buttons are **Move to Trash**
and **Done**. Every developer testing this is online, so nobody sees it.

`syspolicy_check distribution` is the check that does catch it, and it is now
part of `make verify-release`:

```
Notary Ticket Missing — Severity: Fatal
```

`make dmg` switches from ad-hoc to the real identity on its own, adding
`--options runtime --timestamp` (hardened runtime and a secure timestamp, both
required by notarization and both easy to forget), and signs the disk image too.
Expect each of the two submissions to take a few minutes.

Verified in advance: the app runs correctly **with hardened runtime enabled** —
spawning `codex app-server`, reaching the network, and reading its credential file
all still work, so no entitlements are needed.

### Confirming it worked

```bash
make verify-release
```

Mounts the shipped image and checks, in order: the DMG's Gatekeeper verdict and
ticket, then the app *inside* it — Gatekeeper verdict, deep strict signature,
its own stapled ticket, a bundle version matching `VERSION`, and finally Apple's
`syspolicy_check distribution`. The last one is the strict check: `spctl` passes
on any machine that can reach Apple's notary service, which is exactly what
hides a missing ticket.

Want:

```
== Apple pre-distribution check ==
App passed all pre-distribution checks and is ready for distribution.
```

**Check this every release, not just the first one.** A build that skipped
notarization is signed, hardened, and looks entirely healthy — `codesign` passes,
the DMG mounts, the app runs. The only thing that says otherwise is `spctl`
answering `rejected · Unnotarized Developer ID`, and the only person who finds out
the hard way is the recipient.

### Testing it the way a buyer gets it

`spctl` on a freshly built file is not the same thing as a download, because a
build has no quarantine attribute. To test the real path, put one on:

```bash
DMG="build/dist/Hotch-$(make -s print-version).dmg"
cp "$DMG" /tmp/hotch-quarantined.dmg
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;$(uuidgen)" /tmp/hotch-quarantined.dmg
spctl -a -t open --context context:primary-signature -vv /tmp/hotch-quarantined.dmg
```

Then mount it, copy the app out, and check `xcrun stapler validate` on the copy —
that copy is what a buyer actually ends up running, and it is the thing the old
pipeline got wrong.

### If the notarytool profile has vanished

`make notarize` failing with **"No Keychain password item found for profile"**
means the stored credential is gone from the login keychain — it happened once
between releases here, with the keychain unlocked and nothing else disturbed.
Nothing is wrong with the certificate, and it costs one command to put back:

```bash
xcrun notarytool store-credentials Hotch --apple-id <your-apple-id> --team-id WCJ787853P
```

It prompts for an **app-specific password** (account.apple.com → Sign-In and
Security → App-Specific Passwords; generate a fresh one if the old one was
revoked). Leave `--password` off so it never lands in shell history, and run it
yourself — a credential is not something to hand to anyone else, including an
assistant.

The real test is a different Mac: download the DMG through a browser (so it picks
up the quarantine flag) and double-click. No warning means it is done.

### After notarizing (done)

Two things went wrong the moment notarization landed, because both described a
dialog recipients no longer meet. Both are fixed:

- `SHARING.md` — the three install steps collapsed to two, and the "Why macOS
  asks" section is gone.
- The card on the disk image window, in `Sources/Hotch/Views/InstallerArt.swift`
  — `drawSteps` no longer warns about "cannot verify" and **Move to Bin**. It now
  says where to find the app once it is across. Leaving the warning would have sent
  recipients hunting for a prompt that is not there, which is its own kind of
  confusing.

Confirmed by the first recipient of a notarized build: opened the DMG, dragged it
across, double-clicked, and it opened. No trip to Privacy & Security.

## Bumping the version

`VERSION` in the `Makefile`, and the `developmentVersion` literal in
`Sources/Hotch/About.swift` to match.

The app reads its real version from `CFBundleShortVersionString`, so the Makefile
is the source of truth; that literal only covers running the executable directly
out of `.build/release`, where there is no Info.plist. `make check-version` runs
as part of every `bundle` and fails the build if the two disagree — which they
silently did before, with the app reporting `0.1.0` from inside a `1.1` disk
image.

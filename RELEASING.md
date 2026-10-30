# Releasing Hotch

This guide describes a maintainer release from a clean checkout. The release version is defined in `Makefile` and checked against the app's development fallback; read it with `make print-version`. Releases require a macOS machine with a compatible Swift toolchain and SDK. Signed distribution also requires the maintainer's own Developer ID and notarization credentials; do not put credentials, certificates, or private keys in the repository or CI logs.

## Prepare

1. Review the changes and update `CHANGELOG.md`.
2. Set the intended version in `Makefile` and the development fallback in `Sources/Hotch/About.swift` to the same value.
   Update `linux/Cargo.toml`, its `hotch` entry in `linux/Cargo.lock`, and `linux/gnome-extension/metadata.json` (`version-name`) as well. Run `python3 linux/tools/check_version.py`; every version must agree. Unreleased changes stay under `Unreleased` in the changelog until a release version is chosen.
3. Run `make check` and review the resulting app on a Mac. Check the version with `make print-version`.
4. Ensure the release notes accurately state supported macOS versions, known provider limitations, and whether the build is signed and notarized.

## Build and package

For a local architecture build, run `make app`. For a universal bundle run `make app-universal`; this builds arm64 and x86_64 separately, then joins them with `lipo`.

To make a signed and notarized release, configure a Developer ID Application identity in the macOS login keychain. Store a `notarytool` credential profile in that keychain using an interactive terminal:

```sh
xcrun notarytool store-credentials hotch --apple-id you@example.com --team-id YOUR_TEAM_ID
```

Enter your Apple app-specific password only when `notarytool` displays its hidden password prompt. Do not add `--password`, paste the password into an AI chat, or put it in a script or environment file. The prompt keeps it out of the command text and process arguments. An app-specific password is a separate, revocable Apple credential used here to authenticate notarization; Hotch does not use it at runtime. Keep it private even if its label is “Hotch.”

If the password was included in a recorded command, chat, or public file, [revoke that password in your Apple Account](https://support.apple.com/en-us/102654), generate a replacement, and repeat the interactive setup. Revoking this release credential prevents future notarization with it; it does not invalidate existing notarized builds or disconnect Hotch's provider accounts.

Then run:

```sh
make signing-status
make release NOTARY_PROFILE=<keychain-profile-name>
```

`make release` builds the universal app, signs and submits it for notarization, staples the ticket to the app and disk image, and runs release verification. It will fail if the signing identity or profile is missing. If signing is unavailable, distribute source or clearly label any app bundle as an unsigned local build; do not imply notarization.

The Makefile contains additional packaging targets for maintainers (`make dmg`, `make verify-release`). Review its prerequisites before using release-only targets. Never commit local signing material or generated release artifacts unless a repository policy explicitly calls for them.

## Publish

Review the DMG on a clean macOS account or test machine. Confirm the app opens, provider connection steps match current behavior, and privacy notes remain accurate. Publish the release notes and artifacts in the repository's Releases interface, attach checksums if useful, and verify the downloaded artifact after upload. Do not publish credentials, local logs, or user data.

## Experimental Linux assets

The `Linux release assets` workflow runs when a release is published. It first runs `linux/tools/linux_changed.py`, which compares the Linux inputs (`linux/`, the packaged app icon and `LICENSE`) at the release tag with the previous release tag, setting aside the lockstep version fields. A stable release is compared with the previous stable one. If only those fields moved, the release is macOS-only: the workflow attaches nothing and says so in its summary. Otherwise it checks out that release's tag, requires it to match all source versions, tests native amd64 and arm64 builds, and attaches two `.deb` packages, a GNOME extension ZIP, and `SHA256SUMS-linux.txt` to the existing release. Its write permission is limited to the final upload job. It does not create a release, tag, DMG or notarization submission. To retry for an existing release, run it manually with that release tag; tick **force** only to attach Linux assets to a release that does not change Linux.

The Linux update notice relies on this convention: it treats the newest published, non-prerelease release with a `.deb` for the user's architecture as the latest Linux version. So a macOS-only release reaches no Linux user. Do not attach or delete `.deb` files by hand, keep the `hotch_<version>-1_<arch>.deb` names, and mark test builds as prereleases. In a macOS-only release's notes, say that Linux is unchanged and name the current Linux version.

Before publishing, follow the [Linux desktop validation checklist](linux/README.md#desktop-validation) on a supported GNOME desktop. CI verifies parsers, state transitions, extension lifecycle with API doubles, CLI fixtures, version alignment and package contents; it does not certify GNOME rendering, Wayland interactions or a live provider account. State that limitation and the remaining platform gaps in the release notes, credit Simon (@sire6) for the original port, and label Linux downloads experimental.

For local Linux packaging:

```sh
python3 linux/tools/check_version.py
cd linux
cargo test --locked
cargo build --release --locked
node --test tests/*.test.mjs
cargo install cargo-deb --locked
cargo deb --no-build
python3 tools/package_extension.py
```

Install the `.deb` on the architecture it was built for and verify the downloaded files against the Linux checksums. Ubuntu 24.04 or newer is the binary build baseline; the GNOME frontend specifically requires Shell 48, 49 or 50. The extension ZIP alone still requires the matching `hotch` binary. Keep Linux distribution separate from Apple's signing/notarization claims.

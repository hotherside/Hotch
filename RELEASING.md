# Releasing Hotch

This guide describes a maintainer release from a clean checkout. The release version is defined in `Makefile` and checked against the app's development fallback; read it with `make print-version`. Releases require a macOS machine with a compatible Swift toolchain and SDK. Signed distribution also requires the maintainer's own Developer ID and notarization credentials; do not put credentials, certificates, or private keys in the repository or CI logs.

## Prepare

1. Review the changes and update `CHANGELOG.md`.
2. Set the intended version in `Makefile` and the development fallback in `Sources/Hotch/About.swift` to the same value.
3. Run `make check` and review the resulting app on a Mac. Check the version with `make print-version`.
4. Ensure the release notes accurately state supported macOS versions, known provider limitations, and whether the build is signed and notarized.

## Build and package

For a local architecture build, run `make app`. For a universal bundle run `make app-universal`; this builds arm64 and x86_64 separately, then joins them with `lipo`.

To make a signed and notarized release, configure a Developer ID Application identity in the macOS login keychain and store a `notarytool` credential profile in that keychain. Keep those credentials private. Then run:

```sh
make signing-status
make release NOTARY_PROFILE=<keychain-profile-name>
```

`make release` builds the universal app, signs and submits it for notarization, staples the ticket to the app and disk image, and runs release verification. It will fail if the signing identity or profile is missing. If signing is unavailable, distribute source or clearly label any app bundle as an unsigned local build; do not imply notarization.

The Makefile contains additional packaging targets for maintainers (`make dmg`, `make verify-release`). Review its prerequisites before using release-only targets. Never commit local signing material or generated release artifacts unless a repository policy explicitly calls for them.

## Publish

Review the DMG on a clean macOS account or test machine. Confirm the app opens, provider connection steps match current behavior, and privacy notes remain accurate. Publish the release notes and artifacts in the repository's Releases interface, attach checksums if useful, and verify the downloaded artifact after upload. Do not publish credentials, local logs, or user data.

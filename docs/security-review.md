# Publication security review

Reviewed on 23 October 2026 for the Hotch 2.2.0 source publication. This is a targeted source and artifact review, not an independent penetration test or a guarantee that no vulnerabilities exist.

## Scope and findings

- Checked every unique blob in both reachable Git commits (`8784266` and `53c17b6`; 137 blobs), the current tracked files, and the existing `build/Hotch.app` bundle for common provider/GitHub token, JWT, private-key, and Apple app-specific-password patterns. No candidates were found. Pattern scans cannot identify every possible secret format.
- Checked the ignored historical planning notes for the same secret patterns without displaying their contents or password values. They are excluded from publication. No candidates were found.
- Reviewed provider credential storage, outgoing balance requests, local Claude/Codex subprocesses, diagnostics, clipboard history, release tooling, and the Backpack helper's XPC and `pmset` paths.
- Hardened the provider credential writer to restrict an already-existing support directory before writing, reject directory symlinks, and accept only fixed filename characters. A synthetic filesystem check verifies existing/new directory mode `0700`, file mode `0600`, traversal rejection, and symlink rejection without reading real credentials.
- Clarified that API-key storage is plaintext protected by filesystem permissions. It does not isolate keys from other software running as the same user. Kimi's optional read-only CLI-token usage is now documented.

## Apple password and distribution boundary

`Makefile` submits release artifacts with `notarytool --keychain-profile`; `NOTARY_PROFILE` has no embedded default. The password is not required at runtime and no app code accesses a notarization profile. Neither the profile nor signing private keys are copied into the bundle. This follows Apple's [Keychain credential workflow](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool). The Apple team identifier in `BackpackXPC.swift` is public code-signing metadata.

The review did not read or export personal Keychain password values. If a maintainer separately pasted a password into a terminal command, another file, a screenshot, or a remote service, that falls outside this repository check. Apple documents how to [revoke an app-specific password](https://support.apple.com/en-us/102654).

At review time the local 2.2.0 app was an ad-hoc signed arm64 development build without a stapled notarization ticket. The reviewed source can be published, but a downloadable release must be built and verified separately with `make release` before being described as signed and notarized. Re-scan the exact final source and distribution artifacts before uploading them.

## Privileged helper and local data

The Backpack helper exposes a narrow XPC interface with boolean settings rather than arbitrary commands or paths. Both peers pin the expected code identifier and Apple team, and the helper invokes `/usr/bin/pmset` with fixed argument lists. Its recovery marker uses a fixed system path. Heartbeat loss, disconnect, and time limits restore sleep; state-machine tests use simulated power controls. Real lid-close behavior still requires hardware testing.

Hotch reads local session metadata and may display project paths and session titles. Clipboard history is in memory and skips sensitive-pasteboard markers, but an unmarked secret can still enter the history. Diagnostic output can contain paths and third-party error text; inspect it before sharing. The source repository and releases must exclude live screenshots, transcripts, caches, local logs, auth files, signing material, and development build directories.

The GitHub check workflow has read-only repository permissions and does not contain release or signing secrets. Review third-party CLI changes and release dependencies over time; this review does not cover the internals of those tools.

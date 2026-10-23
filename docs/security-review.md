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

## Follow-up after publication

Rechecked the published `main` revision `ba3893e` on 23 October 2026:

- Scanned all three reachable commits and 227 unique Git blobs, including deleted versions and binary files, plus 115 tracked working files. Common Apple app-specific-password, provider/GitHub token, JWT, private-key, credential-URL, and password-argument patterns produced no candidates. A supplemental entropy check of credential-related string literals found only field names, synthetic fixtures, and other code constants. This is a pattern-based check, not proof that every possible secret is absent.
- Scanned the existing local app bundle and source ZIP for credential patterns. No credential candidates were found. GitHub's Releases API returned no releases or downloadable release assets at the time of review.
- Confirmed the public branch points to the reviewed commit and its macOS check run succeeded. The branch is unprotected and the repository has no rulesets. Protect `main` with review and required checks before accepting contributions. The connector did not expose secret-scanning or push-protection settings, so their enabled state and alert status were not verified.
- Confirmed the review machine's Hotch support directory and existing data files use `0700` and `0600` respectively, without opening live credential values. Optional provider API keys still use plaintext file storage; software running as the same user can read them. Moving those keys to Keychain with a stable signed identity remains a recommended security improvement.
- Reviewed fixed HTTPS provider endpoints, subprocess argument handling, clipboard sensitive-data markers, and the helper's code-signing requirements. No confirmed remotely exploitable issue was identified in that targeted review. Third-party client internals and adversarial testing of an installed privileged daemon remain outside its scope.
- Ran `make check` successfully on the local checkout. Credential checks cover directory/file permissions, traversal, and directory-symlink rejection. All 75 helper checks passed, including an actual anonymous XPC connection where the unsigned test client is rejected before the privileged method runs and no simulated power writes occur. These checks do not install the helper or change system power settings.
- Removed the release example's `--password` argument and documented the built-in hidden prompt, verified against the installed `notarytool store-credentials --help`. This avoids recording a new password in command text or process arguments. The original setup interaction was unavailable, so this review cannot establish whether an earlier password appeared in private terminal or agent records.

The local development bundle remains ad-hoc signed and has no stapled notarization ticket. Build and verify a separate signed, notarized artifact before distributing a binary release. Publishing the source does not publish the private signing key or grant access to a maintainer's Apple Account.

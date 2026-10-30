# Security policy

Hotch is maintained as an independent, open-source macOS project with an experimental Linux port. Please report suspected security vulnerabilities privately to **hello@hotherside.com** rather than opening a public issue. Include the affected version, operating system version, a concise impact description, and reproduction steps that do not expose real account data. Do not send live credentials or unredacted session files.

There is no guaranteed response or fix timeline. The maintainer will review reports and coordinate a fix and disclosure when feasible. Please give affected users a reasonable opportunity to update before public disclosure.

## Handling secrets

Never paste API keys, access tokens, Keychain exports, `~/.codex/auth.json`, Claude Code credentials, or raw conversation transcripts into public issues, pull requests, or logs. If a credential is exposed, revoke it with the provider immediately. If a report must include logs, redact paths and identifiers that could reveal private projects or accounts.

Release signing certificates, private keys, Apple app-specific passwords, and `notarytool` profiles are maintainer credentials. They must stay outside the repository and release artifacts. The build takes a Keychain profile name, not a password. Set up profiles interactively so passwords are not saved in shell commands or logs.

See [privacy and data handling](SHARING.md) for the local API-key storage threat model and [the publication review](docs/security-review.md) for the scope and limits of the source review.

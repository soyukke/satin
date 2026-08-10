# Release operations

This document describes Satin's packaging, signing, notarization, and update
pipeline. The stable distribution channel is GitHub Releases; workflow
artifacts are diagnostics only.

## Build a release

`just native-release` creates:

- `spikes/macos-shell/.build/release/Satin-<version>-macOS-arm64.zip`
- `spikes/macos-shell/.build/release/latest.json`

Without Apple credentials, the archive is ad-hoc code-signed, the manifest is
marked as `development`, and the first launch can require approval in macOS
Privacy & Security.

For a Developer ID build, set both `APPLE_SIGNING_IDENTITY` and
`APPLE_NOTARY_PROFILE` before running `just native-release`. The release path
adds a secure timestamp, notarizes and staples the bundle, validates the ticket,
runs Gatekeeper assessment, and only then writes the archive and manifest.

## Publish a release

The release workflow requires a tag that exactly matches the Cargo package
version, for example `vX.Y.Z`, and points at the current `main` commit. Pull
request CI owns the full source and packaged-app verification gates. The tag
workflow builds the release bundle once, signs it, verifies the archive and its
installability, publishes the archive and schema-2 manifest, generates release
notes, and records GitHub build provenance.

The workflow reads `UPDATE_SIGNING_PRIVATE_KEY_B64` from GitHub Actions Secrets.
Signing credentials and notary secrets must never be stored in the repository.

## Update trust boundary

For every update, Satin validates the archive name, declared size, SHA-256,
Ed25519 publisher signature, bundle identifier, semantic version, architecture,
and code signature. A detached helper stages the replacement beside the
installed app, waits for the old process to exit, swaps the bundle, launches the
new version, and moves the previous bundle to Trash so rollback remains
possible.

The Ed25519 public key and identifier are checked in at
[`assets/update-signing-public-key.json`](../assets/update-signing-public-key.json).
The maintainer's recoverable private key copy remains in macOS Keychain under
service `dev.soyukke.neovide-tabs.update-signing`, account `soyukke`. Losing both
the GitHub secret and the Keychain copy would prevent existing installations
from trusting future updates; rotate the key through a shipped, cross-signed
update before retiring it.

The publisher signature authenticates project releases without an Apple
Developer ID. It does not replace Apple notarization or remove the first-install
Gatekeeper warning.

The historical signed migration from Neovide Tabs is recorded in
[ADR 0011](adr/0011-rename-product-to-satin-through-signed-migration-bridge.md).

## Runtime diagnostics

Set `SATIN_LOG=off|error|warn|info|debug|trace` to control Rust diagnostics.
Native lifecycle, runtime, and session events use macOS unified logging.

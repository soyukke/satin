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

The shortest path is one pull request and one command. Put the new version in
the pull request that carries the change: `VERSION` and the five places that
repeat it (`core/nvim/src/launcher/launcher.kizu`,
`core/cli/src/cli/command.kizu`, `core/src/term/spawn.kizu`,
`core/scripts/test-nvim-launcher` and `core/scripts/test-cli`). Then run
`just release-merge <pull-request-number>`. It waits for the checks and the branch policy,
merges, tags `main` with the version it now holds, and waits for the release.
It makes no tag unless `main` holds a version that no tag has.

The release workflow requires a tag that exactly matches the `VERSION` file,
for example `vX.Y.Z`, and points at the current `main` commit. Pull
request CI owns the full source and packaged-app verification gates. A strictly
version-only release PR may skip the redundant macOS lane after the scope check
confirms that `VERSION` is the only changed file. The tag workflow uses a minimal Nix
closure, builds the release bundle once from `main`, signs it, verifies the
archive and its installability, publishes the archive and schema-2 manifest,
generates release notes, and records GitHub build provenance. It also attaches
`Satin-<version>-provenance.intoto.jsonl` so the provenance can be verified
without fetching it from GitHub's attestation API.

The workflow reads `UPDATE_SIGNING_PRIVATE_KEY_B64` from GitHub Actions Secrets.
Signing credentials and notary secrets must never be stored in the repository.

Verify a downloaded archive against GitHub's stored attestation with:

```sh
gh attestation verify Satin-<version>-macOS-arm64.zip --repo soyukke/satin
```

For offline verification, download the matching provenance bundle and pass it
with `--bundle`. The verifier still needs an appropriate trusted Sigstore root.

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

Native lifecycle, runtime, and session events use macOS unified logging. The
Kizu core does not read `SATIN_LOG`; the leveled diagnostics of the Rust core
were not ported.

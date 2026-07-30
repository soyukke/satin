# 0011: Rename the product to Satin through a signed migration bridge

Date: 2026-07-30

Status: Accepted

## Context

`Neovide Tabs` is too close to the established Neovide product name and can
imply an official relationship. The renderer intentionally adapts
MIT-licensed Neovide code, but code provenance and product identity are
separate concerns.

Existing 0.1.x installations trust the checked-in Ed25519 public key and fetch
an archive named `Neovide-Tabs-<version>-macOS-arm64.zip`. Their updater also
requires the extracted bundle to be named `Neovide Tabs.app` with bundle
identifier `dev.soyukke.neovide-tabs`. Publishing only a renamed archive would
strand those installations.

The source repository contains the required Neovide and bundled-font notices,
but early release bundles did not include them. The first Satin release added
the baseline notices; its follow-up completes the Nerd Fonts copyright and MIT
notice for the patched fallback font.

## Decision

The independent product name is `Satin`.

- `soyukke/neovide-tabs` remains public. Version 0.1.6 introduces the bridge;
  0.1.7 is the final, notice-complete Neovide Tabs release.
- Versions 0.1.6 and 0.1.7 keep the legacy archive and bundle identity so every
  existing signed updater can install them.
- The bridge updater switches to `soyukke/satin`, accepts only `Satin.app` with
  bundle identifier `dev.soyukke.satin`, and atomically migrates the installed
  application path while keeping the previous bundle recoverable in Trash.
- Satin starts at version 0.2.0 in the new public repository. Version 0.2.1
  completes the bundled Nerd Fonts attribution.
- The existing Ed25519 key remains the update trust root across the migration.
  Its legacy key identifier is retained until a separately shipped,
  cross-signed rotation is available.
- Product branding is renamed, while source references that document actual
  Neovide provenance remain.
- Every distributed application includes the project license, Neovide notice,
  font copyrights/OFL text, and a generated Cargo dependency license report.
  Packaging and CI fail if those files are absent or the vendored font hashes
  change without an attribution update.

## Consequences

Existing installations have a safe two-step in-app update path:
Neovide Tabs 0.1.x → bridge 0.1.7 → Satin 0.2.1 or newer.

The legacy repository and its bridge Releases must remain available as long as
0.1.x installations may exist. New development, issues, releases, and update
metadata move to `soyukke/satin`.

The repository preserves Neovide attribution without presenting Satin as a
Neovide-branded product. Release artifacts become self-contained with respect
to the known MIT, OFL, and Rust dependency notice obligations.

# 0009: Harden the native runtime and release pipeline

Date: 2026-07-28

Status: Accepted

## Context

The native AppKit host had reached functional terminal parity, but development
builds and a fixed display polling timer were not sufficient release
boundaries. PTY descendants could outlive a pane, reader threads were detached,
Kitty images crossed the FFI/render boundary on every frame, and saved sessions
could not preserve recursive split topology. Failures were also inconsistently
visible outside a debugger.

Shipping on macOS additionally requires a versioned application bundle,
hardened-runtime signing, notarization, a reproducible archive, a stable update
location, and an explicit trust boundary for executable updates. The project
targets Apple Silicon only.

## Decision

- Release builds are assembled as `Satin.app` with versioned bundle
  metadata, a macOS 14 deployment target, an application icon, and
  hardened-runtime entitlements. Developer ID credentials are configuration,
  never repository state. The production path signs with a secure timestamp,
  submits to Apple's notary service, staples the ticket, and runs Gatekeeper
  assessment.
- `just terminal` wraps the current debug binaries in `Satin Dev.app` rather
  than launching an unbundled executable or replacing the installed release.
  The development bundle uses `dev.soyukke.satin.dev`, the `Satin Dev`
  Application Support directory, its own `UserDefaults` domain, and a purple
  variant of the application icon. It omits Finder document/service registration
  and production update checks, so it can run beside `/Applications/Satin.app`
  without sharing session or control state.
- Native development, packaging, and release scripts reject non-arm64 macOS
  hosts. `just native-release` produces an arm64 ZIP archive and
  schema-versioned SHA-256 manifest. Without Apple credentials it is explicitly
  a development artifact; with both signing and notary credentials it is a
  notarized production artifact.
- The bundle's private GUI executable is `satin-app`, leaving `satin` as the
  single public CLI name without a second `satinctl` compatibility command.
- Packaged Mach-O executables link macOS compatibility libraries through the
  Xcode SDK rather than the Nix store. Packaging rejects any `/nix/store`
  dynamic dependency, and package smoke launches the nested `satin` CLI
  executable with a minimal environment so development-machine libraries
  cannot mask a non-portable release.
- A `v<package-version>` tag runs the arm64 production gate and package smoke,
  records GitHub artifact provenance, then publishes the ZIP and manifest as a
  GitHub Release. GitHub Actions workflow artifacts are not a distribution
  channel because their identity, redirect URLs, and retention are run-scoped.
- The packaged application checks the latest GitHub Release after launch and
  from Help → Check for Updates…. Launch checks notify only for a newer semantic
  version; manual checks report all outcomes. Update and Restart drives the
  verified download and replacement flow, with manual download retained only as
  an error fallback.
- Discovery downloads `latest.json` through GitHub's stable
  `releases/latest/download` redirect instead of the unauthenticated REST API,
  so update availability does not depend on the shared 60-request API rate
  limit. A validated version then pins the manifest, archive, and release-notes
  URLs to one concrete tag before installation.
- Release archives carry an Ed25519 signature over the exact ZIP bytes in the
  schema-2 manifest. The trust anchor is the public key embedded in the
  installed application. The private key exists only in the maintainer's macOS
  Keychain and the `UPDATE_SIGNING_PRIVATE_KEY_B64` GitHub Actions Secret.
  Release generation rejects a private key that does not derive the embedded
  public key.
- Version 0.1.1 bootstraps the update trust anchor and requires one final manual
  installation from 0.1.0. Later versions support Update and Restart: download
  the exact manifest and arm64 archive, enforce size and SHA-256, verify the
  Ed25519 signature, validate the extracted bundle ID/version/architecture/code
  signature, and stage it on the install volume.
- A detached, path-constrained helper waits for the old process to exit,
  replaces the bundle, verifies it again, and relaunches. Replacement failure
  restores the old path. Successful replacement moves the old bundle to Trash
  rather than deleting it, preserving user-recoverable rollback.
- The publisher signature is independent of Apple Developer ID signing and
  notarization. It authenticates in-app updates but does not suppress the
  Gatekeeper warning on first installation.
- PTY and embedded-Neovim readers notify AppKit over nonblocking wakeup file
  descriptors. AppKit schedules rendering for runtime events and active
  animation deadlines only; a permanent display polling timer is not retained.
- Pane teardown terminates the PTY process group, reaps the child, and joins the
  reader after its completion signal. Renderer state is forgotten when its
  runtime is removed.
- Kitty RGBA snapshots and Skia images are cached by runtime, image ID, and
  generation. Cache entries are pruned when placements disappear.
- Restorable sessions use schema version 2 and recursively persist split axes,
  pane kinds, working directories, and the active leaf. Version 1 data migrates
  to terminal leaves, corrupt supported data is discarded with a warning, and
  unknown future schemas are preserved.
- Rust emits centrally filtered semantic logs through `SATIN_LOG`; Swift uses
  unified logging categories for lifecycle, runtime, and session events. Fatal
  core or Metal initialization errors are visible to the user before exit.
- The pull-request gate runs platform-independent formatting and repository
  policy checks on Linux in parallel with the macOS lane. The macOS lane
  verifies Rust, builds the native host and release archive, and exercises
  native rendering, resize, session, and lifecycle smoke paths. Documentation,
  demo, and workflow-only changes outside the macOS gate skip the native lane;
  a release bump also skips it only when normalized `Cargo.toml` and
  `Cargo.lock` content proves that the root package version is the sole change.
  The aggregate gate still requires the Linux checks. `just native-soak`
  repeats high-risk native lifecycle scenarios locally.

## Consequences

Normal idle operation no longer wakes at 60 Hz. Runtime output remains
responsive because readable wakeup descriptors are dispatched on the main
queue, while cursor and scroll animation frames are scheduled by the renderer.

Unsigned/ad-hoc output remains useful for development and CI but is labeled as
such in the manifest and is not an update-eligible release. Publisher-signed,
unnotarized releases can use the in-app channel. Apple-trusted publication
still depends on externally supplied Developer ID credentials; the repository
contains the complete deterministic path up to that external trust boundary.

The tag workflow may publish an explicitly labeled, unnotarized arm64 release
for users who approve it through macOS Privacy & Security. GitHub-generated
provenance lets users independently verify the build. The in-app updater
requires both the independently trusted Ed25519 signature and the manifest
integrity checks before it stages executable code.

Key loss is a release continuity failure: GitHub Secrets cannot be read back,
so the Keychain copy must be included in the maintainer's encrypted machine
backup. Rotation requires shipping a release trusted by the current key that
also embeds the next public key before the old private key is retired.

Session restore intentionally starts new shell or Neovim processes. Process
memory and PTY byte streams are not serialized.

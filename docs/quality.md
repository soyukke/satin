# Quality and Security Baseline

This document defines the repository-controlled quality bar for Satin. It is a
working policy, not a claim that Satin holds an external certification.

## Sources

The baseline is derived from:

- the [OpenSSF Best Practices passing criteria](https://www.bestpractices.dev/en/criteria/0),
  especially its build, test, warning, static-analysis, vulnerability-reporting,
  and release requirements;
- GitHub's [community profile guidance](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories);
- GitHub's [CodeQL guidance](https://docs.github.com/en/code-security/reference/code-scanning/codeql)
  and [Dependabot configuration guidance](https://docs.github.com/en/code-security/concepts/supply-chain-security/about-the-dependabot-yml-file);
- the [REUSE specification](https://reuse.software/spec/) as an enhanced
  per-file licensing target, not a requirement for this baseline.

## Required repository baseline

Every change must preserve all of the following.

### Discoverability and governance

- `README.md` explains purpose, installation, operation, build, and support.
- `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the packaged legal resources identify
  project and dependency licenses.
- `CONTRIBUTING.md` states the contribution process and required checks.
- `CODE_OF_CONDUCT.md`, `SUPPORT.md`, issue forms, and the pull request template
  make reporting paths explicit.
- `SECURITY.md` provides a private reporting URL, response expectation, and
  coordinated-disclosure target.
- Significant design decisions are recorded in `docs/adr/`.

### Reproducibility and change safety

- `flake.lock` is committed and pins the Kizu compiler, zig, and every other
  development tool; `core/scripts/build-ghostty` pins the `libghostty-vt`
  commit. Homebrew is not part of the build contract.
- `justfile` is the supported command surface for build, lint, test, smoke, and
  release operations.
- Behavior changes add automated tests. Native rendering changes also run the
  scenario-specific smoke tests documented in `docs/renderer.md`.
- Compiler and linter warnings are errors in CI.

### Language and repository lint coverage

- Kizu core: `kizu check` on the four packages (`just check`) and
  `core/scripts/test` (`just test`), which runs each package's Kizu tests, the
  `satin` and `satin-nvim` commands against stand-ins, and an offscreen render
  into a Metal drawable that is read back. Kizu has no separate formatter or
  linter in this gate.
- Swift: repository-pinned `swift-format` default lint rules plus explicit bans
  on force unwraps, force tries, and implicitly unwrapped optionals; Swift
  compiler warnings as errors, updater self-test, and native smoke.
- Shell: `shfmt`, ShellCheck, and syntax checks for the supported zsh startup
  files.
- Nix: `nixfmt` and `deadnix`.
- Documentation and metadata: markdownlint, typos, Actionlint, and zizmor.

`just fmt-check` and `just swift-lint` are scoped formatting and Swift gates.
`just lint` includes every supported formatter and linter, while `just verify`
adds type checking, tests, and license validation. All four commands are
non-mutating. `just ci-static` and `just ci-core` expose the two CI subsets that
`just verify` composes. `just precommit` adds staged secret scanning. `just
quality` is the local publication gate and adds worktree secret scanning,
native build, updater self-test, and every
app-launching smoke that does not capture the screen. The smokes that do
(settings, kitty, Neovim UI surfaces, and pixel native smoke) need
screen-recording permission, so they live in the explicit `just
native-visual-smoke`. Both suites run only locally: a host that does not
composite the application window renders almost no frames, so a CI runner
cannot judge frame, presentation, or animation assertions. `just quality` is
therefore required before pushing, and `just native-package-verify` checks the
packaged bundle before a release.
The native portion explicitly includes frame-liveness, repeated bottom-line
terminal input, stable tab-title ownership, active-pane Command-T cwd
inheritance, per-pane Finder directory actions, animated pane-header drag/drop,
multi-tab toolbar placement, full tmux control-mode behavior, and the pane/grid
matrix. The Finder checks cover live local PTY cwd, tmux `current_path`, and
event-driven native Neovim `DirChanged` metadata without a home/process-cwd
fallback. The pane drag gate checks
that unchanged sibling-side drops suppress their target highlight, then checks
center swaps and edge reparenting without replacing local pane runtimes. The
gate runs those checks through the same rebuilt `Satin Dev.app` executable used
by `just terminal`, rather than only the unbundled native build. The full tmux
boundary drives the real session popover,
verifies Local and tmux discovery, switches sessions, and creates a visible
Command-T window in the source pane's cwd; it also exercises `swap-pane` and
`join-pane` through the same pane-header gesture callback. `just
native-smoke-suite` runs these same focused input and toolbar checks plus the
full tmux boundary rather than only its zoom/resize subset.
The title/CWD smoke pins `/bin/zsh` so it exercises Satin's bundled, supported
shell integration instead of inheriting the account shell.

Lint suppressions must be scoped to the smallest affected expression or rule
site and include a reason. Repository-wide warning suppression is not allowed.
The `swift-format` `rules` object replaces rather than extends its defaults, so
`.swift-format` records the pinned tool's complete default rule map explicitly.
Review that map when upgrading the tool. Snake-case core and control-protocol
keys use type-scoped naming exceptions; Swift FFI identifiers remain camel-case
while `@_silgen_name` preserves the exported C ABI symbol.

### Complexity and size ratchet

New Swift source files may not exceed 1,000 lines; the lint does not cover the
Kizu sources under `core/`. Files already over
that limit are listed with their current ceilings in `scripts/source-size-lint`.
They may shrink but may not grow. A change that reduces one of those files must
lower its ceiling in the same change.

Line count is only a regression signal. It does not justify compressed code,
artificial file splitting, or abstractions without a clear owner and purpose.

### CI and supply chain

- Pull requests run the same checks composed by local `just verify`. CI runs
  the platform-independent `just ci-static` subset on Linux in parallel with
  `just ci-core` and the native build, signing, and packaging lane on macOS.
  The app-launching smoke suite is a local gate instead, because a CI runner
  does not composite the application window. A release PR
  skips the macOS lane only when CI proves that `VERSION` is the only changed
  file and holds a different `X.Y.Z` version; the tag workflow still
  rebuilds and verifies the release from the resulting `main` commit.
- GitHub Actions are pinned to full commit SHAs and checked by zizmor.
- Workflow permissions default to read-only; write permissions are scoped to
  the job that needs them.
- Gitleaks scans history and the worktree on pull requests, `main`, and a
  schedule. No CodeQL or dependency-advisory job runs: the Rust jobs were
  removed with the Rust core.
- Dependabot checks GitHub Actions weekly with a seven-day cooldown. The Kizu
  compiler and `libghostty-vt` pins are updated by hand.
- Release tags must match the `VERSION` file. CI builds, signs, attests, and
  publishes the arm64 archive, update manifest, and offline provenance bundle.

## External and time-dependent controls

These controls cannot be proven by a local lint command:

- `main` blocks force pushes and deletion, applies protection to administrators,
  and requires strict CI status checks.
- GitHub private vulnerability reporting is enabled.
- A second-person approval is desirable but cannot be required while Satin has
  one maintainer. Automated or AI review does not replace independent human
  review.
- OpenSSF badge enrollment is a maintainer self-assessment and is not claimed
  until the public badge process is completed.
- Project age, contributor diversity, and report-response history improve only
  through real maintenance activity and must not be simulated for a metric.

## Deferred controls

REUSE compliance, SBOM publication, notarization, fuzzing, and Swift
CodeQL coverage are valuable follow-up work. They are not added merely to
collect badges; each should enter the required baseline when its workflow is
reliable and its operational owner is clear.

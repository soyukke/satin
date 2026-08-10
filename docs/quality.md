# Quality and Security Baseline

This document defines the repository-controlled quality bar for Satin. It is a
working policy, not a claim that Satin holds an external certification.

## Sources

The baseline is derived from:

- the [OpenSSF Best Practices passing criteria](https://www.bestpractices.dev/en/criteria/0),
  especially its build, test, warning, static-analysis, vulnerability-reporting,
  and release requirements;
- the [OpenSSF Scorecard checks](https://github.com/ossf/scorecard/blob/main/docs/checks.md),
  especially pinned dependencies, token permissions, dangerous workflows,
  SAST, branch protection, and signed releases;
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

- `flake.lock` and `Cargo.lock` are committed. Development tools are supplied
  by the Nix flake; Homebrew is not part of the build contract.
- `justfile` is the supported command surface for build, lint, test, smoke, and
  release operations.
- Behavior changes add automated tests. Native rendering changes also run the
  scenario-specific smoke tests documented in `docs/renderer.md`.
- Compiler and linter warnings are errors in CI.

### Language and repository lint coverage

- Rust: `rustfmt`, `cargo check`, Clippy with denied warnings, and tests.
- Swift: repository-pinned `swift-format`, safety lint rules, Swift compiler
  warnings as errors, updater self-test, and native smoke.
- Shell: `shfmt`, ShellCheck, and syntax checks for the supported zsh startup
  files.
- Nix: `nixfmt` and `deadnix`.
- Documentation and metadata: markdownlint, typos, Actionlint, and zizmor.
- Rust dependencies: `cargo-audit` against the RustSec advisory database.

`just fmt-check`, `just lint`, and `just verify` are non-mutating gates.
`just precommit` adds staged secret scanning. `just quality` is the local
publication gate and adds worktree secret scanning, dependency auditing, native
build, updater self-test, and native smoke.

### Complexity and size ratchet

New Rust and Swift source files may not exceed 1,000 lines. Files already over
that limit are listed with their current ceilings in `scripts/source-size-lint`.
They may shrink but may not grow. A change that reduces one of those files must
lower its ceiling in the same change.

Line count is only a regression signal. It does not justify compressed code,
artificial file splitting, or abstractions without a clear owner and purpose.

### CI and supply chain

- Pull requests run the same `just verify` gate used locally plus the native
  build and smoke suite.
- GitHub Actions are pinned to full commit SHAs and checked by zizmor.
- Workflow permissions default to read-only; write permissions are scoped to
  the job that needs them.
- CodeQL analyzes Rust on pull requests, `main`, and a schedule.
- Gitleaks scans history and the worktree; RustSec audits run on pull requests,
  `main`, and a schedule.
- Dependabot checks Cargo and GitHub Actions weekly with a seven-day cooldown.
- Release tags must match the package version. CI builds, signs, attests, and
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

## Measurement policy

The public repository's initial OpenSSF Scorecard measurement on 2026-08-11 was
4.2/10. The project uses Scorecard as a regression detector, with priority on
repository-controlled high-risk checks: dangerous workflows, pinned
dependencies, token permissions, SAST, security policy, and release integrity.
The aggregate score is not a release gate because it also includes project age,
contributor count, and independent human review.

REUSE compliance, SBOM publication, notarization, fuzzing, and expanded Swift
CodeQL coverage are valuable follow-up work. They are not added merely to
collect badges; each should enter the required baseline when its workflow is
reliable and its operational owner is clear.

## Accepted dependency warning

RustSec currently reports `RUSTSEC-2025-0141` because `bincode 1.3.3` is
unmaintained. It is a transitive dependency of `syntect`'s bundled syntax data,
not a reported exploitable vulnerability, so `cargo audit` reports it as an
allowed warning and still fails on vulnerability findings. Remove this
exception when `syntect` can provide the required syntax sets without
`bincode 1.x`; do not add another direct use of that crate.

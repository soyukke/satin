# Contributing to Satin

Thank you for helping improve Satin. Bug reports, focused feature proposals,
reproduction cases, and documentation corrections are welcome.

## Contribution model

Satin currently has one maintainer and accepts pull requests only from
repository maintainers. Pull requests from other accounts are closed by an
automated policy without checking out or executing their contents. External
contributors should open an issue before investing in an implementation. A
minimal reproduction, a proposed design, or a patch attached to the issue can
still be useful.

This policy is about current review capacity, not the license. Satin remains
MIT-licensed, and the policy can be relaxed when independent review capacity
exists.

## Before opening an issue

- Search existing issues and the latest release notes.
- Reproduce the problem with the latest release or current `main`.
- Remove credentials, terminal history, private paths, and customer data from
  screenshots and logs.
- Use private vulnerability reporting for security-sensitive findings; see
  [SECURITY.md](SECURITY.md).

## Development environment

Development requires an Apple Silicon Mac, macOS 14 or newer, Xcode, and Nix.
Repository dependencies come from the locked Nix flake. Do not add Homebrew
dependencies.

```sh
nix develop
just doctor
just native-build
```

Run `just` to list supported commands instead of documenting long direct
commands. Install the repository-managed pre-commit hook once per clone with
`just install-hooks`.

## Change requirements

- Keep a change focused and preserve unrelated worktree changes.
- Add or update automated tests for behavior changes and regressions.
- For a renderer change, follow [docs/renderer.md](docs/renderer.md) and run the
  relevant terminal and Neovim smoke tests.
- Record significant architecture decisions in [docs/adr](docs/adr).
- Do not increase a grandfathered source-file size ceiling. When a large file
  shrinks, lower its ceiling in `scripts/source-size-lint` in the same change.
- Keep compiler and linter output warning-free.

## Required checks

Format supported source files:

```sh
just fmt
```

Run the commit gate:

```sh
just precommit
```

Before a release or a broad native change, run the publication-grade gate:

```sh
just quality
```

`just quality` includes formatting, static analysis, tests, license checks,
secret scanning, dependency auditing, the native build, the updater self-test,
the native smoke test, frame-liveness, repeated terminal input, multi-tab
toolbar placement, full tmux control-mode coverage, and the pane/grid matrix.
The complete policy and tool mapping are in
[docs/quality.md](docs/quality.md).

## Review checklist

- The issue or pull request explains user-visible behavior and risk.
- Tests fail before the fix when practical and pass afterward.
- Documentation and release notes are updated when users need to act.
- New dependencies have a clear need, compatible license, and locked version.
- No generated build output, credentials, or private terminal content is
  committed.

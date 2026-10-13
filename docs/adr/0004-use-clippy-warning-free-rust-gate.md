# 0004: Use a warning-free Rust lint gate

Date: 2026-07-02

Status: Superseded by [0019](0019-replace-the-rust-core-with-kizu.md)

## Context

The codebase is moving from a single prototype binary toward a Rust terminal
core/runtime and a native macOS shell with a Metal renderer.

That split will only stay maintainable if new code keeps a low defect surface:
warnings should not accumulate, unsafe blocks should be explained, and obvious
debug scaffolding should not land unnoticed.

## Decision

Use Clippy as the Rust zero-debt lint gate.

`just lint` runs:

```sh
cargo clippy --all-targets --all-features -- -D warnings
```

`just verify` includes the same lint gate after formatting and type checking.

Cargo lint settings deny:

- `rust_2018_idioms`
- `unsafe_op_in_unsafe_fn`
- `unused_must_use`
- `clippy::dbg_macro`
- `clippy::todo`
- `clippy::too_many_lines`
- `clippy::unimplemented`
- `clippy::undocumented_unsafe_blocks`

`clippy.toml` sets `too-many-lines-threshold = 70`.

`rustfmt.toml` sets `max_width = 100`.

## Consequences

Warnings are treated as work to finish, not background noise.

`unsafe` is not globally forbidden because the C ABI and platform integration
need narrow unsafe boundaries, but every unsafe block must document its safety
argument.

This is not a replacement for deeper review. Clippy catches mechanical issues;
protocol correctness, terminal semantics, and renderer invariants still require
tests and review.

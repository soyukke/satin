# Architecture Decision Records

This directory stores Architecture Decision Records for Satin.

ADRs are used for decisions that shape the long-term architecture, especially
choices that are hard to reverse or that explain why the current prototype is
allowed to differ from the target design during a migration.

## Index

- [0001: Manage architecture decisions as ADRs](0001-manage-architecture-decisions-as-adrs.md)
- [0002: Target a native macOS shell with Rust terminal core and Metal renderer](0002-target-native-macos-shell-rust-core-metal-renderer.md)
- [0003: Prioritize Kitty graphics protocol for inline images](0003-prioritize-kitty-graphics-protocol-for-inline-images.md)
- [0004: Use a warning-free Rust lint gate](0004-use-clippy-warning-free-rust-gate.md)
- [0005: Retire the macroquad frontend](0005-retire-macroquad-frontend.md)
- [0006: Use Neovim multigrid for the native Neovim pane](0006-use-neovim-multigrid-for-native-neovim-pane.md)
- [0007: Vendor Neovide rendering assets for native Neovim quality](0007-vendor-neovide-rendering-assets.md)
- [0008: Complete the native terminal interaction and pane model](0008-complete-native-terminal-interaction-and-pane-model.md)
- [0009: Harden the native runtime and release pipeline](0009-harden-native-runtime-and-release-pipeline.md)
- [0010: Use native settings and an owner-only control API](0010-use-native-settings-and-an-owner-only-control-api.md)
- [0011: Rename the product to Satin through a signed migration bridge](0011-rename-product-to-satin-through-signed-migration-bridge.md)

## Workflow

Use `just adr` to list current records.

Use `just adr-new "short decision title"` to create the next ADR from the
template. New records start as `Proposed`; change the status to `Accepted`,
`Rejected`, `Superseded`, or `Deprecated` when the decision is settled.

Keep records short. An ADR should capture the decision, the context that made it
necessary, and the consequences we are accepting.

# 0003: Prioritize Kitty graphics protocol for inline images

Date: 2026-07-02

Status: Accepted

Superseded in part by [0019](0019-replace-the-rust-core-with-kizu.md): where
this record names the Rust core, its crates and Cargo tooling, or the
Skia/Metal renderer, 0019 replaced them with the Kizu core in `core/` and its
CoreText/CoreGraphics renderer. The rest of the decision stands; the text below
is kept as it was written.

## Context

The terminal should support inline images. Common terminal image protocols
include Kitty graphics protocol, iTerm2 inline images, and Sixel.

The renderer also needs Neovide-like scroll behavior, so image placements must
belong to terminal state and scroll with text instead of being drawn as an
unstructured overlay.

## Decision

Prioritize Kitty graphics protocol as the first inline-image protocol.

Kitty support should define the internal image model: image resources,
placements, deletion semantics, pane isolation, scroll interaction, resize
behavior, and renderer texture uploads.

`libghostty-vt` owns parsing, storage, placement, and deletion. The application
allows direct chunked transfer, owner-scoped temporary-file transfer, and shared
memory transfer. Arbitrary regular-file transfer remains disabled so terminal
output cannot read unrelated user files. Temporary files must use the Kitty
protocol filename prefix and are consumed by the parser.

The Skia/Metal renderer consumes visible placements with pane clipping and
z-order. Conformance coverage includes PNG decoding, deletion, scrolling,
resize geometry, pane isolation, temporary-file consumption, and a real
two-pane visual smoke.

iTerm2 inline images can be added later as a compatibility layer. Sixel is not a
near-term target.

## Consequences

Image protocol parsing and image placement state should live in the Rust
terminal core, not only in the renderer.

The renderer must support textured image placement in cell coordinates and make
those placements participate in smooth scroll animation.

Compatibility with iTerm2 and Sixel is intentionally deferred so the first
implementation can focus on one modern protocol and a clean internal model.

Applications that request protocol replies must consume them. Shell-driven
smokes use `q=2` to suppress replies so Kitty acknowledgements are not
interpreted as shell input.

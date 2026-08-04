# Third-Party Notices

## Neovide

Portions of the Neovim rendering command model, retained window line cache,
scrollback animation structure, font shaping/cache structure, and critically
damped spring animation are adapted from Neovide. Message-area pointer
selection, copied-text range construction, and the retained selection overlay
also follow Neovide's structure.

- Source: https://github.com/neovide/neovide
- Audited source revision:
  https://github.com/neovide/neovide/commit/618605b79d70577f4b7ec92b50b3b9b5bf482c1a
- Message-selection source revision:
  https://github.com/neovide/neovide/commit/7f90c1276c4daafc60923bb1be3f175b504969d0
- Adapted source areas:
  `src/renderer/animation_utils.rs`, `src/renderer/rendered_window.rs`,
  `src/renderer/fonts/`, `src/renderer/metal.rs`, `src/renderer/mod.rs`,
  `src/window/mouse_manager.rs`, and `src/window/window_wrapper.rs`
- License: MIT

```text
MIT License

Copyright (c) 2023 Neovide Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Bundled Fonts

The fallback fonts in `assets/fonts/` are byte-for-byte copies of Neovide's
font assets at the audited source revision above. They are embedded in the
application binary and remain under the SIL Open Font License 1.1.

- `FiraCodeNerdFont-Regular.ttf`
  - SHA-256:
    `f6ce2df86c65720b6aa0b1c948bcc63b16ce21a441488e61fb3b5e8b56486b3a`
  - Copyright 2014-2021 The Fira Code Project Authors
  - Fira Code 6.002, patched with Nerd Fonts 2.1.0
  - Sources: https://github.com/tonsky/FiraCode and
    https://github.com/ryanoasis/nerd-fonts
  - Nerd Fonts patch tooling and glyph collection:
    Copyright (c) 2014 Ryan L McIntyre
  - Audited Nerd Fonts release:
    https://github.com/ryanoasis/nerd-fonts/tree/v2.1.0
  - Licenses: Nerd Fonts MIT notice plus SIL Open Font License 1.1
- `LastResort-Regular.ttf`
  - SHA-256:
    `2cdfa3f7d70ee06c32e9bb37c94634cecd54ba018e5a8110e853b394e0f91f01`
  - Copyright © 2020 Unicode, Inc.
  - Last Resort 13.001 for Unicode 13.0.0
  - Source: https://github.com/unicode-org/last-resort-font

The copyright notices, Nerd Fonts MIT notice, and full OFL text are kept in
`assets/fonts/LICENSE` and are included in every application bundle under
`Contents/Resources/Legal/`.

## Rust Dependencies

The application statically links permissively licensed Rust dependencies.
Their resolved license texts and source links are generated from `Cargo.lock`
with `cargo-about` and included in every application bundle as
`Contents/Resources/Legal/RUST_DEPENDENCY_LICENSES.html`.

# Vendored crates

## libghostty-vt 0.2.1

The crates.io release of `libghostty-vt` (MIT OR Apache-2.0) with one
addition: `Terminal::from_raw_borrowed` in `src/terminal.rs`, marked
"Satin patch". The Kizu core (satin-kizu `vt_ffi.kizu`) creates the terminal,
installs its callbacks and feeds it; the Rust runtime borrows it through this
function to render, select and encode input. The crate does not expose its
raw handle otherwise.

Everything else is the published source. `Cargo.toml` at the repository root
points `[patch.crates-io]` here.

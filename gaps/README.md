# Kizu gaps found while porting satin

Porting `satin_core_*` (tabs, pane layout, snapshot / workspace JSON),
`satin::tmux` (tmux control mode, scroll tracking) and `satin_vt_*` (the
libghostty-vt terminal and its callbacks) from Rust.

Added to Kizu along the way: C callbacks (`extern "c" fn(...)` values) for
`satin_vt_*`; `let v = unsafe &var p.*;` with `ptr_write(p, move value)`,
which replaced the read-work-write round trip every handle function did; and
extern structs passed by value, for `ghostty_terminal_new`'s options.

## Bugs

| Gap | Repro | Workaround in this port |
| --- | --- | --- |
| A `bool` returned by a method on a `ptr_read` value is treated as an owner (`write move done`) | `ptr_read_method_result_is_owner.kizu` | copy it out with `if value.f() { done = true; }` |

## Missing features

| Gap | Where it bit | Workaround |
| --- | --- | --- |
| No `sizeof<T>()` | malloc for the handle | fixed 256-byte bound (`core_storage_bytes`) |
| `return null` / `let x: ?ptr<T> = null` rejected | null handle / null string | `unsafe ptr_from_int<ptr<T>>(0)` |
| No module-level `const` | split ratio bounds, epsilon | functions returning the value |
| No closures | every export repeats read/work/write | written out per function |
| `orelse` takes no block | handle create | `if storage \|slot\| { } else { }` |
| No discard (`_ = f()`) | `new_tab` in constructor | bare `try f();` statement |
| String literals have no escapes | JSON in tests | one-line `\\...` multi-line literal |
| `Array` has no `insert` | `move_tab` | walk with `swap` |
| An owner field cannot be replaced | `apply_workspace` swapping tabs | `reserve`, `clear`, move elements one by one |
| `!T` cannot propagate into a declared error set | layout helpers | declare `mem::Error!T` |
| `at` / `at_mut` / `Box.borrow` / `as_bytes` must be bound by capture or `let` | everywhere | capture forms |
| No C string API, no UTF-8 validation | `c_string` | `strlen` + `view_from_ptr`; invalid UTF-8 is accepted |
| No Unicode-aware trim | `rename_tab` blank check | ASCII whitespace only |
| `return f()` does not widen a narrower error union into the declared one | tmux parsers returning `Failure!T` | `try f(); return;` |
| No `catch { ... }` block for a discarded error | ignoring allocation failures | `if f() {} else \|_\| {}` |
| An error value cannot be built as a composed set's value in a helper | `fail(...) -> Failure` | set the message, then `return ParseError::Invalid;` at the call site |
| `at` / `at_mut` borrows block `remove` in the same loop body | pruning per-pane state | find the index first, remove outside the borrow |
| `try` inside an `at_mut` capture is refused when the array has an `errdefer` | appending a pane to its window | `if f() \|_\| {} else \|_\| {}` and return after the borrow |
| `Encoder.finish_into` needs an owned encoder, so it cannot move into a helper | event JSON | end and finish inline in each builder |
| Files of one directory share a namespace | `utf8`, `passthrough` helpers | prefix helper names (`is_valid_utf8`, `dcs_prefix`) |
| Each native object carries the Kizu runtime, so one link takes one Kizu object | core + tmux | one package, one object, linked by the Rust `build.rs` |
| `[a, b, c]` is not an array literal | five OSC fields | separate locals |
| A `ptr<T>` argument does not fill a `?ptr<T>` parameter (a `return` does) | calling `satin_vt_*` from Kizu tests | a helper that returns the pointer |
| `p == null` does not compile for `?ptr<T>` | test asserts | `if p \|_\| { return true; }` |
| `[N]u8` has no mutable view, so a byte buffer cannot be written by index | escape bytes in tests | build a `String` |
| `kizu test` links every C export, so a package calling a C library needs that library to test | `satin_vt_*` | `[native] library_search` + a symlink to the archive cargo built (`scripts/link-ghostty`) |

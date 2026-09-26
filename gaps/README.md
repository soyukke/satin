# Kizu gaps found while porting satin

Porting `satin_core_*` (tabs, pane layout, snapshot / workspace JSON) from Rust.

## Bugs

| Gap | Repro | Workaround in this port |
| --- | --- | --- |
| A `bool` returned by a method on a `ptr_read` value is treated as an owner (`write move done`) | `ptr_read_method_result_is_owner.kizu` | copy it out with `if value.f() { done = true; }` |

## Missing features

| Gap | Where it bit | Workaround |
| --- | --- | --- |
| No way to lend a raw pointer's target as `&var T` | opaque handle for the host | `ptr_read` → work → `ptr_write` on every call |
| `ptr_write` of an owner is a copy; the source needs `mem::leak` | handle create | `ptr_write` then `mem::leak<T>(move value)` |
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

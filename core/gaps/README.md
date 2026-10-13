# Kizu gaps found while porting satin

Porting `satin_core_*` (tabs, pane layout, snapshot / workspace JSON),
`satin::tmux` (tmux control mode, scroll tracking), `satin_vt_*` (the
libghostty-vt terminal and its callbacks) and `satin::term` (the terminal
runtime: frames, input, selection, search, the PTY) from Rust.

Added to Kizu along the way: C callbacks (`extern "c" fn(...)` values) for
`satin_vt_*`; `let v = unsafe &var p.*;` with `ptr_write(p, move value)`,
which replaced the read-work-write round trip every handle function did; and
extern structs passed by value, for `ghostty_terminal_new`'s options; and a
`ptr<T>` filling any `?ptr<T>` position, not only a return; and
`mem::size_of<T>()`, which sizes each handle's malloc; and `return f()`
widening a narrower error union into the declared set; and `null` written
where a `?ptr<T>` is expected.

## Missing features

| Gap | Where it bit | Workaround |
| --- | --- | --- |
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
| No `catch { ... }` block for a discarded error | ignoring allocation failures | `if f() {} else \|_\| {}` |
| An error value cannot be built as a composed set's value in a helper | `fail(...) -> Failure` | set the message, then `return ParseError::Invalid;` at the call site |
| `at` / `at_mut` borrows block `remove` in the same loop body | pruning per-pane state | find the index first, remove outside the borrow |
| `try` inside an `at_mut` capture is refused when the array has an `errdefer` | appending a pane to its window | `if f() \|_\| {} else \|_\| {}` and return after the borrow |
| `Encoder.finish_into` needs an owned encoder, so it cannot move into a helper | event JSON | end and finish inline in each builder |
| Files of one directory share a namespace | `utf8`, `passthrough` helpers | prefix helper names (`is_valid_utf8`, `dcs_prefix`) |
| Each native object carries the Kizu runtime, so one link takes one Kizu object | core + tmux | one package, one object, linked by the Rust `build.rs` |
| `[a, b, c]` is not an array literal | five OSC fields | separate locals |
| `p == null` does not compile for `?ptr<T>` | test asserts | `if p \|_\| { return true; }` |
| `[N]u8` has no mutable view, so a byte buffer cannot be written by index | escape bytes in tests | build a `String` |
| `kizu test` links every C export, so a package calling a C library needs that library to test | `satin_vt_*` | `[native] library_search` + a symlink to the archive (`scripts/build-ghostty`, which builds it with zig) |
| A variadic C function cannot be declared | `ioctl(TIOCSWINSZ)`, `fcntl(F_SETFD)` on the PTY | six unused register arguments, which puts the real one on the stack where arm64 Darwin reads a variadic argument; wrong on any other target |
| No threads outside `thread::each` | the PTY reader thread | the host waits on the PTY itself; a pipe replaces it at its end so the wait goes quiet |
| A C out parameter of a scalar needs storage with an address | every libghostty `*_get` | a malloc "slot" read back with `ptr_read`, or a one-field `extern "c" struct` passed as `&var` |
| An `extern "c" struct` holding a pointer is not copy | `GridRef`, `Selection` | `move` at every use |
| A `?[]u8` parameter is refused | `resolve_user_zdotdir` | an empty view for "unset" |
| A field of a field cannot be deinitialized | a struct nested in the query state | flatten the fields into the owner |
| `std::json::decode<T>` does not compile when `T`'s first field is an optional owner (`?String`, `?Array<..>`, `?Map<..>`): `decode_optional` returns `held` without `move` | the spawn configuration | declare a `?bool` or a required field first |
| A value carrying views (`KeyInput` with `[]u8` fields) built from `view_from_ptr` views cannot be passed to a method of a `&var` read out of a raw pointer: "borrowed value cannot escape" | `satin_runtime_key` | `write_key_of` / `encode_key_of`, which take the parts and build the value inside |
| A view cannot be returned from a helper or assigned to an outer `var` | C string helpers at the host boundary | `strlen` + `view_from_ptr` inline in every export |
| No bare `{ }` block to end a borrow early | two runtimes borrowed in turn | straight-line code, or a helper per borrow |
| No way to embed a file at build time | the skill text `satin skill` prints | `scripts/embed-skill` writes it as a `\\` literal in a generated source file |
| `main` has to be in the package's root module | the `satin` command, whose code is `satin::cli` | a three-line root file that calls into the module |
| A package cannot depend on another package | the app core, the host boundary and the commands share code | one source root each, listed in every manifest that needs it (`shared`, `host/src`, `cli/src`) |
| An `export "c" fn` anywhere in a package is linked into every executable of it | the `satin` command would link the terminal library | keep exports out of the source roots a command lists |
| No `unsafe { }` block | a run of libc calls setting up one spawn | `unsafe` and a `// SAFETY:` on each statement |
| An integer literal above `i64::MAX` is refused, and a literal does not take a `u64` operand's type in a product | MessagePack's 64-bit values, float bit layouts | `cast<u64>(9223372036854775807) + 1`, and typed `let` constants |
| A local cannot hold an error union to `try` later | freeing malloc storage before propagating a failure | a `failed` flag, and `return mem::Error::OutOfMemory` after the free |
| `std::process` starts a child only to wait for it, with no pipes | the embedded editor's RPC | `posix_spawnp` with file actions, declared by hand |
| `std::net` has no Unix sockets and no readiness queue for foreign descriptors | the control socket | `socket` / `bind` / `kqueue` / `kevent`, declared by hand |
| A loop variable and an owned local of the same name in one function pass `check` and then emit invalid IR | the editor's grid rows | distinct names |
| Struct `==` passes `check` and fails in codegen | artifact model comparisons | a function comparing the fields |
| `kizu check` does not check `_test.kizu` files | every module | `kizu test` is the check for tests |
| A `let`-bound view used inside a loop stays borrowed to the end of the function | deferred `deinit` after a send loop | move the loop into a helper taking the view |
| `&self.field` cannot be returned as `?&T` | the popup menu's window | a one-element `Array` and `at(0)` |
| An `Array<T>` cannot hold a struct with raw pointers, and every field write of an `unsafe struct` needs `unsafe` | the renderer's bitmap and font caches | pointers kept in a nested struct, fields swapped by hand |

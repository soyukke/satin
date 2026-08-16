# AGENTS.md

このファイルは Codex 向けの恒久的な repo ルールを書く場所。
現在進行中の作業リストは `TODO.md`、設計判断は `docs/adr/` に書く。

## 使い分け

- `AGENTS.md`: 毎回守る repo 規約、検証コマンド、設計上の禁止事項。
- `TODO.md`: 現在の作業チェックリスト。完了したら空に戻す。
- `docs/adr/`: 技術スタック、renderer、プロトコル、移行方針などの意思決定。

`TODO.md` が空でなければ、作業前に必ず読む。完了した項目は削除し、
全項目が完了したら `TODO.md` を空に戻す。

## 基本方針

- Homebrew で依存を追加しない。開発環境と依存は Nix flake / repo 管理に寄せる。
- コマンド導線は `justfile` に追加する。ユーザーに長い直接コマンドを覚えさせない。
- 大きな設計変更は実装とあわせて ADR を更新する。
- Rust は zero-debt を守る。clippy warning、fmt 差分、幅超過、長すぎる関数を放置しない。
- 既存の未関係な dirty change は戻さない。
- self-host 中は screen / system-audio 権限を使う visual smoke や
  `native-window-capture` を実行しない。pixel capture が必要な場合は、ユーザーの明示確認後に
  Satin 外から `just native-visual-smoke` を実行する。

## Renderer 方針

Neovim pane の描画品質は Neovide parity を目標にする。

- Neovim pane の描画問題は、まず Neovide upstream の構造を読んでから直す。
- AppKit cell renderer の延命だけで終わる変更を追加しない。
- snapshot 後の差分推測による新しい nvim スクロール検出を追加しない。
- nvim のスクロール、ジャンプ、ウィンドウ移動は Neovim UI event 起点の retained command model に寄せる。
- Neovide 由来の `DrawCommand` / `WindowDrawCommand` / `RenderedWindow` / line cache /
  scrollback animation / font shaping / Skia-Metal 境界を優先して移植する。
- AppKit/Swift は macOS window、tabs、menus、pane layout、native UI を担当する。
- Rust 側は terminal runtime、Neovim compositor、renderer state、FFI 境界を担当する。
- terminal pane は `libghostty-vt` を尊重する。Neovim 専用設計で terminal path を壊さない。
- Macroquad は最終構成に戻さない。

### Pane / grid geometry の不変条件

- `Command-+/-/0` は Satin window 全体で共有する。pane、tab、runtime、tmux window ごとの
  font size / zoom offset を追加しない。
- font、cell、PTY/Neovim grid、Skia geometry、cursor、mouse、IME は
  `TerminalTextView.terminalCellSize()` の同じ値から導出する。glyph と配置用 cell を分けない。
- tmux control client は window ごとに一つの grid を持つ。renderer-only scale や crop で
  pane ごとの差を吸収せず、全 leaf の content frame と pane header を layout 時に合成する。
- font、pane frame、grid の変更では `just pane-grid-smoke` を必ず通す。

暫定実装が必要な場合は、同じ変更内で削除条件、置換先、検証ケースを明記する。

## 主要コマンド

- `just terminal`: native AppKit terminal host を起動する。
- `just native-build`: Swift/AppKit host をビルドする。
- `just native-smoke`: native host の基本表示スモークを実行する。
- `just pane-grid-smoke`: local/tmux terminal と native/tmux Neovim の grid 契約を検証する。
- `just verify`: Rust fmt / lint / test gate を実行する。
- `just precommit`: pre-commit 相当の検証を実行する。

Neovim pane の描画変更では、通常 smoke に加えて nvim scroll / jump smoke も確認する。

## 完了条件

- 関連する `just` コマンドが通っている。
- font、pane frame、grid の変更では `just pane-grid-smoke` が通っている。
- renderer 変更では、二重表示、statusline/cmdline/side pane の残像、nvim scroll/jump の regressions を確認している。
- stopgap を増やした場合は、削除条件と移行先が `TODO.md` または ADR にある。
- 作業 TODO が完了したら `TODO.md` を空に戻す。

# Satin Party Frames デモ動画 制作指示書

この文書は、PC を操作するエージェント（以下「操作者」）が、Satin の遊び用ブランチ
`party-frames-fx` に入っている「Party frames」の演出を約 60 秒の動画に収めるための手順書です。

## 1. 動画のゴール

見る人が次の 4 点を理解できれば成功です。

1. 右側の **PARTY 列** に、タブごとの枠が並び、各タブのエージェントの状態がひと目でわかる。
2. 状態ごとに **動きが違う**（実行中＝バーが明滅、承認待ち＝オレンジのリングが脈打つ、完了＝緑に一瞬光る）。
3. 見ていないタブが承認待ちになると、画面上部に **警告バナー** が 4 秒出る。
4. **`⌘J`** や **枠のクリック** で、そのタブのエージェントの pane に一発で飛べる。

## 2. 仕様（動画で映るもの）

| 状態 | 枠の見た目 | 動き |
| --- | --- | --- |
| IDLE | 灰色のバー | なし |
| RUNNING | 青緑のバー、右上に `RUNNING 00:12` と経過時間 | バーが 0.9 秒周期でゆっくり明滅 |
| WAITING | 枠の背景がうっすらオレンジ、`WAITING 00:05` | オレンジのリングが 0.55 秒周期で脈打つ |
| FAILED | 赤のバー | なし |
| CLEAR（未読の完了） | 緑のバー、`CLEAR` | 完了に変わった瞬間、枠が緑に一瞬フラッシュ（約 0.9 秒） |

- 現在のタブの枠には白い枠線が付く。
- 各枠のイニシャルの下に `⌘1` などタブのショートカットが出る。
- 警告バナーは「`⚠ <タブ名> needs you`」「`<要約> · ⌘J to jump`」の 2 行。
  pane エリアの上部中央に出て、4 秒で消える。クリックすると飛ぶ。
- **注意**: macOS の「視差効果を減らす」（アクセシビリティ › ディスプレイ）が ON だと動きが全部止まる。
  収録前に OFF を確認すること。

## 3. 事前準備（収録しない）

### 3.1 条件

- **Satin の外のターミナル（Terminal.app など）で作業すること。** Satin 本体の中から実行しない。
- Mac のロックを解除し、ディスプレイをスリープさせない。
- 画面収録の権限をスクリーンショットアプリ（`⌘⇧5`）に与えておく。
- 「視差効果を減らす」を OFF にする。

### 3.2 ビルドと起動

```sh
cd ~/dev/app/satin
git switch party-frames-fx
just native-dev-app

# Party frames を ON にする（開発版だけの設定）
defaults write dev.soyukke.satin.dev partyFrames -bool true

# 開発版が起動中なら終了してから起動する
pkill -f satin-dev-app || true
just terminal
```

「Satin Dev」というウィンドウが開く。ウィンドウを **1440×900 前後** にし、画面中央に置く。
右側に「PARTY」列が出ていることを確認する。

### 3.3 デモ用タブの作成

Terminal.app で次を実行する。4 つのタブ（`api` `web` `docs` `infra`）が作られ、
それぞれ左右 2 分割になる（左＝エージェント役、右＝エディタ役）。

```sh
cd ~/dev/app/satin
sat() { target/debug/satin --socket "$HOME/Library/Application Support/Satin Dev/run/control.sock" "$@"; }

for name in api web docs infra; do
  sat new-tab --cwd "$HOME" --title "$name" --background
done
sleep 1
for name in api web docs infra; do
  pane=$(sat list --json | jq -r --arg t "$name" \
    '.result.tabs[] | select(.title == $t) | .panes[0]')
  sat split --pane "$pane" --vertical --background
done
sat list --json | jq -r '.result.tabs[] | "\(.title)\t\(.panes)"'
```

最初からある `session 1` タブは閉じてよい（ウィンドウ上で × を押す）。
PARTY 列に `api` `web` `docs` `infra` の 4 枠が IDLE で並んでいれば準備完了。

## 4. 進行スクリプト

次を `demo.sh` として保存する。状態の切り替えはすべてこのスクリプトが行う。
**`>>> ACTION:` と表示されたら、操作者がその操作を行う。**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd ~/dev/app/satin
sat() { target/debug/satin --socket "$HOME/Library/Application Support/Satin Dev/run/control.sock" "$@"; }
tab_id()   { sat list --json | jq -r --arg t "$1" '.result.tabs[] | select(.title == $t) | .id'; }
agent_of() { sat list --json | jq -r --arg t "$1" '.result.tabs[] | select(.title == $t) | .panes[0]'; }
cue()      { printf '\n>>> %s\n' "$*"; }

API=$(agent_of api); WEB=$(agent_of web); DOCS=$(agent_of docs); INFRA=$(agent_of infra)
for p in "$API" "$WEB" "$DOCS" "$INFRA"; do sat status set --pane "$p" idle >/dev/null; done
sat select-tab --tab "$(tab_id api)" >/dev/null

cue "ACTION: 5 秒以内に Satin Dev のウィンドウをクリックして前面にし、録画を開始する"
sleep 5

cue "シーン1: 全タブ IDLE（5 秒）"
sleep 5

cue "シーン2: api と infra が実行中になる（10 秒）"
sat status set --pane "$API"   running "Claude Code working" >/dev/null
sleep 1
sat status set --pane "$INFRA" running "Claude Code working" >/dev/null
sleep 9

cue "シーン3: 見ていない web が承認待ちになる → 警告バナーとオレンジのリング（8 秒）"
sat status set --pane "$WEB" waiting "Claude Code needs approval" >/dev/null
sleep 8

cue "ACTION: ⌘J を押す（web の左 pane に飛ぶ）"
sleep 6

cue "シーン4: web を再開、api が完了 → api の枠が緑にフラッシュ（8 秒）"
sat status set --pane "$WEB" running "Claude Code working" >/dev/null
sleep 2
sat status set --pane "$API" done "Claude Code finished" >/dev/null
sleep 6

cue "ACTION: PARTY 列の api の枠をクリックする（api の左 pane に飛び、CLEAR が消える）"
sleep 6

cue "シーン5: infra が失敗、docs が承認待ち（8 秒）"
sat status set --pane "$INFRA" failed "Claude Code failed" >/dev/null
sleep 2
sat status set --pane "$DOCS" waiting "Claude Code needs input" >/dev/null
sleep 6

cue "ACTION: ⌘J を 2 回、2 秒おきに押す（待ちの長い順に infra → docs と巡回する）"
sleep 7

cue "シーン6: 全部片付く（5 秒）"
for p in "$INFRA" "$DOCS" "$WEB"; do sat status set --pane "$p" done "Claude Code finished" >/dev/null; sleep 1; done
sleep 3

cue "ACTION: 録画を停止する"
```

実行は `bash demo.sh`。スクリプトは Terminal.app で動かし、録画するのは **Satin Dev のウィンドウだけ**。

## 5. 収録手順

1. `⌘⇧5` を押し、「選択したウィンドウを収録」を選ぶ。まだ収録は始めない。
2. Terminal.app で `bash demo.sh` を実行する。
3. 最初の `>>> ACTION` が出たら、Satin Dev のウィンドウをクリックして収録を開始する。
4. 以降は `>>> ACTION` の指示どおりに操作する。**それ以外はマウスもキーボードも触らない。**
   - Terminal.app を前面に出すと Satin Dev のウィンドウが隠れるので、指示は画面の端に置いた
     Terminal.app を横目で見るか、音声読み上げを使う。
5. 最後の `>>> ACTION` で収録を停止する。

## 6. ショットリスト（完成形）

| 時間 | シーン | 映っているべきもの |
| --- | --- | --- |
| 0:00–0:05 | 1 全タブ IDLE | 左に 2 分割の pane、右に PARTY 列の 4 枠（灰色） |
| 0:05–0:15 | 2 実行中 | api と infra のバーが青緑に変わり明滅、経過時間が進む |
| 0:15–0:23 | 3 承認待ち | 上部に「⚠ web needs you」のバナー。web の枠にオレンジのリングが脈打つ |
| 0:23–0:29 | ⌘J | 画面が web タブに切り替わり、左 pane にフォーカス。web の枠に白い枠線 |
| 0:29–0:37 | 4 完了 | web が RUNNING に戻り、api の枠が緑に一瞬光って CLEAR |
| 0:37–0:43 | 枠クリック | api タブに切り替わる。api の CLEAR が IDLE に戻る |
| 0:43–0:51 | 5 失敗と承認待ち | infra が赤（FAILED）、docs にリングとバナー |
| 0:51–0:58 | ⌘J 巡回 | ⌘J 1 回目で infra、2 回目で docs に飛ぶ |
| 0:58–1:03 | 6 片付く | infra・docs・web が順に緑にフラッシュして CLEAR |

## 7. 仕上げ

- 冒頭と末尾の余分な部分をカットする（QuickTime Player の「編集 › トリム」で可）。
- 形式は `.mov` のままでよい。共有用に必要なら MP4 に書き出す。
- ファイル名: `satin-party-frames-demo.mov`
- 字幕を付ける場合は、ショットリストの「シーン」列の言葉を使う。

## 8. うまくいかないとき

| 症状 | 対処 |
| --- | --- |
| PARTY 列が出ない | `defaults read dev.soyukke.satin.dev partyFrames` が `1` か確認し、開発版を起動し直す |
| 動きがない | 「視差効果を減らす」が OFF か確認する |
| バナーが出ない | 承認待ちになったタブを表示中だと出ない仕様。シーン3の時点で api タブが前面か確認する |
| `sat` が接続できない | 開発版が起動しているか、ソケット `~/Library/Application Support/Satin Dev/run/control.sock` があるか確認する |
| ⌘J でビープ音 | 承認待ち・失敗の pane がない。スクリプトのタイミングより早く押していないか確認する |
| 描画が止まる | Mac がロック・スリープしていないか確認する。ウィンドウが他のアプリに完全に隠れていないか確認する |

## 9. 撮影後の片付け

```sh
defaults delete dev.soyukke.satin.dev partyFrames   # Party frames を既定（OFF）に戻す場合
```

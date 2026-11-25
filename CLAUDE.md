# CLAUDE.md — 交通整理系パズルゲーム（仮題）

## 役割分担
- 企画・仕様・レビュー = Muse（ユーザー経由）。実装 = Claude Code。
- 仕様の正本は `docs/spec/`。優先順位: 作業指示書（`claude-code-greybox-instructions.md` など） > `spec-v0.1.md` > 企画書 > context。食い違いは勝手に解釈せず報告する。

## 絶対ルール
- 「TBD」「未決定」は確定させない。試作に必要な値は「試作で置いた初期値」として `game/scripts/core/tuning.gd` などに集約し、報告に明記する。
- 「作らないもの」「不採用」「保留」は実装しない（`docs/spec/claude-code-context-traffic-game.md` の該当節）。
- 事故（接触）は仕様上発生させない。優先度: 歩行者 > 自転車 > 車両。低優先側が必ず停止して譲る。ヒヤリはカウントする。
- ロジックとモデルの分離: `game/scripts/sim/` は見た目（Node3D/メッシュ）に依存しない。表示は `game/scripts/view/` が sim の状態を読んで描く。
- モデル規約: footprint（占有マス）・高さ区分・ピボット（footprint 底面中心）を守る。詳細は `docs/greybox-plan.md` の「グリッド規約」。

## 技術前提
- Godot 4.7.2（4.3以降の要件を満たす）、GDScript のみ（C# 不可）。
- レンダラーは **Compatibility（gl_compatibility）**。Web 書き出しでは Forward+／Mobile は使えない。
- Web 書き出しはシングルスレッド（`variant/thread_support=false`）。COOP/COEP 不要。
- 横画面、タッチ前提（`emulate_touch_from_mouse` 有効）。マウスでも操作可能にする。
- 演出は Godot 標準の Tween。GSAP／three.js などの JS ライブラリは使わない。

## ディレクトリ
- `game/` — Godot プロジェクト（`project.godot`, `export_presets.cfg`）
  - `scripts/sim/` 交通ロジック（純ロジック）／`scripts/view/` 表示（`world_view.gd` 地面・信号・熱マップ・波、`agents_view.gd` 車・人・立ち話・雨、`camera_rig.gd`）／`scripts/ui/` UI／`scripts/core/` 起動・設定・調整値
- `docs/spec/` — Muse の企画書・仕様書（編集しない。更新版は差し替え）
- `docs/` — 実装側の計画・報告
- `tools/setup_godot.sh` — Godot と Web テンプレートの導入（冪等・SHA512 検証）
- `tools/build_web.sh` — Web 書き出し（`build/web/`）とサイズ表示
- `tools/make_font.sh` — UI 用日本語フォントの部分抽出（Web ではシステムフォントが使えない。UI の文言を変えたら再実行）
- `game/tests/sim_test.gd` — 1交差点の回帰テスト（接触ゼロ・ゲージ・ヒヤリ。基準: 信号なし87.8／普通61.0）。1交差点側のロジックを変えたら必ず実行
- `game/tests/stage1_test.gd` — ステージ1（1日 6:00→翌6:00）の検証。`godot --headless --script res://tests/stage1_test.gd -- --none`（信号なし）／`--key`（主要な置き方の比較）／`--play`（疑似プレイヤー）／`--sweep`（置く場所の総当たり。候補数は検証する）／`--traj`（1日の推移）／`--one`（信号1基）／`--policy`（5 シードの方針比較）。ステージ1側を変えたら実行
- ステージ1（`scripts/sim/town_map.gd`, `town_world.gd`, `scripts/view/town_view.gd`）が **通常のURLで開く**。1交差点の旧マップは `?map=legacy`。確認用: `?debug=1`（24時間・雨のボタン）、`&t=<時刻>`、`&rain=1`、`&result=fail|clear`（結果画面の確認）
- 通貨は「開発ポイント」（「資金」は使わない）。開始100
- `build/` は git 管理外

## コマンド
- 導入: `bash tools/setup_godot.sh`
- インポート確認: `cd game && godot --headless --import`
- Web 書き出し: `bash tools/build_web.sh`
- ブラウザ確認: `build/web` を `python3 -m http.server` で配信し、Playwright（Chromium, `--use-angle=swiftshader`）で開く。ヘッドレス Chromium の FPS はスマホ実機の FPS ではない（報告時に区別する）。

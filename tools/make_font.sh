#!/usr/bin/env bash
# UI 用の日本語フォント（Noto Sans CJK JP, SIL OFL 1.1）を、ゲームで使う文字だけに絞って作る。
# Web 版ではシステムフォントが使えないため、フォントを同梱する必要がある。
# UI の文言を変えたら再実行すること。
# 必要: apt-get install fonts-noto-cjk / pip install fonttools
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
OUT="$ROOT/game/assets/fonts/ui_font.otf"
mkdir -p "$(dirname "$OUT")"
CHARS=$(mktemp)
python3 - "$ROOT/game/scripts" > "$CHARS" <<'PY'
import sys, pathlib
s = set(chr(c) for c in range(0x20, 0x7f))       # ASCII
s |= set("、。・ー〜（）「」：／→←↑↓％")
for p in pathlib.Path(sys.argv[1]).rglob("*.gd"):
    s |= set(p.read_text(encoding="utf-8"))
print("".join(sorted(c for c in s if c.isprintable())))
PY
pyftsubset "$SRC" --font-number=0 --text-file="$CHARS" --output-file="$OUT" \
  --layout-features='*' --no-hinting --desubroutinize
rm -f "$CHARS"
cp /usr/share/doc/fonts-noto-cjk/copyright "$ROOT/game/assets/fonts/LICENSE-NotoSansCJK.txt"
ls -la "$OUT"

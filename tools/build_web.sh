#!/usr/bin/env bash
# Exports the Web (single-threaded) build to build/web and prints sizes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/game"
godot --headless --import >/dev/null 2>&1 || true
mkdir -p "$ROOT/build/web"
godot --headless --export-release "Web" "$ROOT/build/web/index.html"
cd "$ROOT/build/web"
echo "--- sizes (bytes) ---"
for f in index.wasm index.pck index.js; do
  printf "%-10s raw=%-10s gzip=%s\n" "$f" "$(stat -c%s "$f")" "$(gzip -9c "$f" | wc -c)"
done

#!/usr/bin/env bash
# Installs Godot 4.7.2 (headless-capable editor) and Web export templates.
# Idempotent. Verifies SHA512 checksums from the official GitHub release.
set -euo pipefail
VER="4.7.2"
BASE="https://github.com/godotengine/godot/releases/download/${VER}-stable"
DL=/opt/godot-dl
TPL="$HOME/.local/share/godot/export_templates/${VER}.stable"
if command -v godot >/dev/null && godot --version 2>/dev/null | grep -q "^${VER}.stable" && [ -f "$TPL/web_nothreads_release.zip" ]; then
  echo "Godot ${VER} already installed"; exit 0
fi
mkdir -p "$DL" /opt/godot "$TPL"
cd "$DL"
for f in "Godot_v${VER}-stable_linux.x86_64.zip" "Godot_v${VER}-stable_export_templates.tpz" SHA512-SUMS.txt; do
  [ -f "$f" ] || curl -fsSL -o "$f" "$BASE/$f"
done
grep -E "Godot_v${VER}-stable_(linux.x86_64.zip|export_templates.tpz)$" SHA512-SUMS.txt | sha512sum -c -
unzip -oq "Godot_v${VER}-stable_linux.x86_64.zip" -d /opt/godot
ln -sf "/opt/godot/Godot_v${VER}-stable_linux.x86_64" /usr/local/bin/godot
TMP=$(mktemp -d)
unzip -oq "Godot_v${VER}-stable_export_templates.tpz" 'templates/web*' 'templates/version.txt' -d "$TMP"
mv "$TMP"/templates/* "$TPL"/ && rm -rf "$TMP"
godot --version

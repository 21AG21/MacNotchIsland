#!/usr/bin/env bash
# Renders every island state at 2x (see Tests/MacNotchIslandTests/GalleryTests.swift) and
# prints each image as base64 JPEG, so the whole gallery can be read back from a CI job log.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/build/gallery"
rm -rf "$OUT"
GALLERY_DIR="$OUT" swift test --filter GalleryTests 2>&1 | grep -v "^\[" | tail -n 30
count=$(ls "$OUT"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "--- gallery: $count images"
[ "$count" -gt 0 ] || exit 1
for f in "$OUT"/*.jpg; do
  name=$(basename "$f" .jpg)
  echo "--- gallery $name (base64 jpeg, $(stat -f %z "$f") bytes)"
  base64 -i "$f" | fold -w 400
done
echo "--- gallery done"

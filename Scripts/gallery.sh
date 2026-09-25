#!/usr/bin/env bash
# Renders every island state at 2x (see Tests/MacNotchIslandTests/GalleryTests.swift) and
# prints each image as base64 JPEG, so the whole gallery can be read back from a CI job log.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/build/gallery"
rm -rf "$OUT"
GALLERY_DIR="$OUT" swift test --filter GalleryTests 2>&1 | grep -v "^\[" | tail -n 30
# The test run's own status, not the pipeline's: grep exits 1 when it has nothing to print,
# which is no failure of the gallery's. A run that failed used to pass here as long as one
# image had been written before it did.
tested=${PIPESTATUS[0]}
count=$(ls "$OUT"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "--- gallery: $count images"
[ "$count" -gt 0 ] || { echo "GALLERY FAILED: no images were written"; exit 1; }
for f in "$OUT"/*.jpg; do
  name=$(basename "$f" .jpg)
  echo "--- gallery $name (base64 jpeg, $(stat -f %z "$f") bytes)"
  # Long lines: the job log stamps every one of them with a timestamp, and at 400 characters
  # that stamp was seven percent of everything the gallery printed.
  base64 -i "$f" | fold -w 1200
done
echo "--- gallery done"
# After the images, so the ones that were drawn can still be looked at.
if [ "$tested" -ne 0 ]; then echo "GALLERY FAILED: swift test exited $tested; see its output above"; exit 1; fi

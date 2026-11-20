#!/bin/bash
# Downloads and builds every clip listed in clips.txt that you don't have yet.
# usage: tools/get-clips.sh        (about 10 minutes per clip, mostly the 4K upscale)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -vE '^\s*(#|$)' "$ROOT/clips.txt" | while read -r url name flags; do
  if ls "$ROOT"/clips-hd/*-"$name".mp4 >/dev/null 2>&1; then echo "have $name"; continue; fi
  echo "== $name"
  opts=(); for f in $flags; do opts+=("--$f"); done
  "$ROOT/tools/add-reel.sh" "$url" "$name" "${opts[@]}" < /dev/null || echo "!! $name failed, moving on"
done

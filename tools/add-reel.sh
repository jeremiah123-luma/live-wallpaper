#!/bin/bash
# Adds an Instagram reel (or any video URL yt-dlp can read) to the rotation.
# usage: tools/add-reel.sh <url> <short-name> [--keep]   e.g. tools/add-reel.sh https://www.instagram.com/reel/... empty-tomb
#        --keep plays the clip exactly as posted (no black-frame trim or loop blend)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
url="$1"; name="$2"; keep="$3"
[ -n "$url" ] && [ -n "$name" ] || { echo "usage: $0 <url> <short-name>"; exit 1; }

n=$(( $(ls "$ROOT"/clips-src/*.mp4 2>/dev/null | wc -l) + 1 ))
clip="$n-$name"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "1/4 downloading"
yt-dlp -q --no-warnings -f "bv*+ba/b" --merge-output-format mp4 -o "$tmp/raw.mp4" "$url"

echo "2/4 checking for black frames and a loop jump"
mkdir -p "$ROOT/clips-src"
if [ "$keep" = "--keep" ] || python3 "$ROOT/tools/check_clip.py" "$tmp/raw.mp4"; then
  ffmpeg -v error -i "$tmp/raw.mp4" -an -c copy "$ROOT/clips-src/$clip.mp4"
else
  echo "    fixing: keeping the clean stretch and blending the loop"
  python3 "$ROOT/tools/check_clip.py" "$tmp/raw.mp4" --fix "$ROOT/clips-src/$clip.mp4"
fi

echo "3/4 upscaling to 4K (a few minutes)"
"$ROOT/tools/upscale.sh" >> "$ROOT/upscale.log" 2>&1
[ -f "$ROOT/clips-hd/$clip.mp4" ] || { echo "upscale failed, see upscale.log"; exit 1; }

echo "4/4 saving a still and restarting the player"
mkdir -p "$ROOT/stills"
mid=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ROOT/clips-hd/$clip.mp4" | awk '{print $1/2}')
ffmpeg -v error -y -ss "$mid" -i "$ROOT/clips-hd/$clip.mp4" -frames:v 1 "$ROOT/stills/$clip.png"
launchctl kickstart -k "gui/$(id -u)/${LABEL:-local.livewallpaper}" 2>/dev/null || echo "    (player not running yet: run tools/setup.sh)"
echo "added $clip"

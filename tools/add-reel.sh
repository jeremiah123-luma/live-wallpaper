#!/bin/bash
# Adds an Instagram reel (or any video URL yt-dlp can read) to the rotation.
# usage: tools/add-reel.sh <url> <short-name> [--keep] [--crop=W:H:X:Y] [--extend] [--blend] [--pixel]
#        e.g. tools/add-reel.sh https://www.instagram.com/reel/... empty-tomb
#        --keep   plays the clip exactly as posted (no black-frame trim or loop blend)
#        --crop   cuts a landscape window out of a portrait reel (ffmpeg crop, in source pixels)
#        --extend keeps a portrait reel whole and grows new sides out of its own scenery
#                 (tools/extend_sides.py, with the options saved in tools/extend/<short-name>.args)
#        --blend  always blends the loop, for a jump too small for the check to flag
#        --pixel  turns ordinary footage into pixel art (tools/pixelate.sh)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
url="$1"; name="$2"; keep=""; crop=""; extend=""; blend=""; pixel=""
for a in "${@:3}"; do
  case "$a" in --keep) keep="--keep" ;; --crop=*) crop="${a#--crop=}" ;; --extend) extend=1 ;; --blend) blend=1 ;; --pixel) pixel=1 ;; esac
done
[ -n "$url" ] && [ -n "$name" ] || { echo "usage: $0 <url> <short-name>"; exit 1; }

n=$(( $(ls "$ROOT"/clips-src/*.mp4 2>/dev/null | wc -l) + 1 ))
clip="$n-$name"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "1/4 downloading"
yt-dlp -q --no-warnings -f "bv*+ba/b" --merge-output-format mp4 -o "$tmp/raw.mp4" "$url"
if [ -n "$crop" ]; then
  ffmpeg -v error -i "$tmp/raw.mp4" -an -vf "crop=$crop" -c:v libx264 -crf 12 -preset slow "$tmp/crop.mp4"
  mv "$tmp/crop.mp4" "$tmp/raw.mp4"
fi
if [ -n "$extend" ]; then
  echo "    growing the sides out to the screen's shape"
  python3 "$ROOT/tools/extend_sides.py" "$tmp/raw.mp4" "$tmp/wide.mp4" $(cat "$ROOT/tools/extend/$name.args" 2>/dev/null)
  mv "$tmp/wide.mp4" "$tmp/raw.mp4"
fi

echo "2/4 checking for black frames and a loop jump"
mkdir -p "$ROOT/clips-src"
if [ "$keep" = "--keep" ] || { python3 "$ROOT/tools/check_clip.py" "$tmp/raw.mp4" && [ -z "$blend" ]; }; then
  ffmpeg -v error -i "$tmp/raw.mp4" -an -c copy "$ROOT/clips-src/$clip.mp4"
else
  echo "    fixing: keeping the clean stretch and blending the loop"
  python3 "$ROOT/tools/check_clip.py" "$tmp/raw.mp4" --fix "$ROOT/clips-src/$clip.mp4"
fi
if [ -n "$pixel" ]; then
  echo "    turning it into pixel art"
  "$ROOT/tools/pixelate.sh" "$ROOT/clips-src/$clip.mp4" "$tmp/px.mp4"
  mv "$tmp/px.mp4" "$ROOT/clips-src/$clip.mp4"
  # hard-edged pixels only need enlarging; the upscaler would smear them, so make the 4K file here and it will skip this clip
  mkdir -p "$ROOT/clips-hd"
  ffmpeg -v error -y -i "$ROOT/clips-src/$clip.mp4" -vf "scale=3840:-2:flags=neighbor" \
    -c:v hevc_videotoolbox -b:v 30M -tag:v hvc1 -pix_fmt yuv420p "$ROOT/clips-hd/$clip.mp4"
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

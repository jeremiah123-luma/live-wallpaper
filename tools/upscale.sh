#!/bin/bash
# Upscales every clip in clips-src/ that isn't in clips-hd/ yet to 4K with Real-ESRGAN.
# usage: tools/upscale.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/tools/resr"
W="$ROOT/work"
[ -x "$R/realesrgan-ncnn-vulkan" ] || { echo "Real-ESRGAN missing: run tools/setup.sh first"; exit 1; }
mkdir -p "$ROOT/clips-hd"
for src in "$ROOT"/clips-src/*.mp4; do
  b=$(basename "$src" .mp4)
  [ -f "$ROOT/clips-hd/$b.mp4" ] && continue
  rm -rf "$W"; mkdir -p "$W/in" "$W/out"
  fps=$(ffprobe -v error -select_streams v -show_entries stream=r_frame_rate -of csv=p=0 "$src")
  w=$(ffprobe -v error -select_streams v -show_entries stream=width -of csv=p=0 "$src")
  s=4; [ "$w" -gt 1400 ] && s=2          # 2x is already 4K for 1080p sources
  ffmpeg -v error -i "$src" "$W/in/%05d.png"
  # -m matters: without it the tool looks for models in the current folder and crashes
  "$R/realesrgan-ncnn-vulkan" -i "$W/in" -o "$W/out" -n realesr-animevideov3 -s $s -f jpg -m "$R/models" || exit 1
  ffmpeg -v error -y -framerate "$fps" -i "$W/out/%05d.jpg" -vf "scale=3840:-2:flags=lanczos" \
    -c:v hevc_videotoolbox -b:v 30M -tag:v hvc1 -pix_fmt yuv420p "$ROOT/clips-hd/$b.mp4" || exit 1
  echo "done $b $(date)"
done
rm -rf "$W"
echo ALLDONE

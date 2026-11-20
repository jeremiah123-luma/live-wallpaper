#!/bin/bash
# Turns ordinary footage into pixel art so it sits with the rest of the rotation:
# shrinks it to a coarse grid, limits it to one fixed palette for the whole clip (so colours don't flicker),
# and scales it back up with hard edges.
# usage: tools/pixelate.sh in.mp4 out.mp4 [cell-px=6] [colours=40]
set -e
in="$1"; out="$2"; cell="${3:-6}"; cols="${4:-40}"
[ -n "$in" ] && [ -n "$out" ] || { echo "usage: $0 in.mp4 out.mp4 [cell-px] [colours]"; exit 1; }
w=$(ffprobe -v error -select_streams v -show_entries stream=width -of csv=p=0 "$in")
h=$(ffprobe -v error -select_streams v -show_entries stream=height -of csv=p=0 "$in")
sw=$(( w / cell )); sh=$(( h / cell ))
ow=$(( sw * cell / 2 * 2 )); oh=$(( sh * cell / 2 * 2 ))
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# tmix averages 3 frames first: film grain would otherwise make cells flip colour every frame
small="tmix=frames=3:weights='1 2 1',scale=$sw:$sh:flags=area,eq=saturation=1.25:contrast=1.08"
ffmpeg -v error -y -i "$in" -vf "$small,palettegen=max_colors=$cols:stats_mode=full" "$tmp/pal.png"
ffmpeg -v error -y -i "$in" -i "$tmp/pal.png" -an \
  -lavfi "[0]$small[s];[s][1]paletteuse=dither=none,scale=$((sw*cell)):$((sh*cell)):flags=neighbor,crop=$ow:$oh:0:0" \
  -c:v libx264 -crf 12 -preset slow -pix_fmt yuv420p "$out"

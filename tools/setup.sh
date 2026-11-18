#!/bin/bash
# One-time setup: downloads Real-ESRGAN, builds the player, and starts it at login.
# Expects this repo at ~/Wallpapers (the player reads ~/Wallpapers/clips-hd).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=local.livewallpaper
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

for t in ffmpeg ffprobe yt-dlp swiftc; do
  command -v $t >/dev/null || { echo "missing $t (brew install ffmpeg yt-dlp; xcode-select --install)"; exit 1; }
done

if [ ! -x "$ROOT/tools/resr/realesrgan-ncnn-vulkan" ]; then
  echo "downloading Real-ESRGAN"
  mkdir -p "$ROOT/tools/resr" && cd "$ROOT/tools/resr"
  curl -sL -o r.zip https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip
  unzip -oq r.zip && rm r.zip
  chmod +x realesrgan-ncnn-vulkan
  xattr -dr com.apple.quarantine . 2>/dev/null || true
fi

echo "building the player"
swiftc -O "$ROOT/src/main.swift" -o "$ROOT/LiveWallpaper"
mkdir -p "$ROOT/clips-src" "$ROOT/clips-hd" "$ROOT/stills"

echo "installing the login agent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$ROOT/LiveWallpaper</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "done. Add a clip with: tools/add-reel.sh <url> <short-name>"

#!/usr/bin/env python3
"""Check a clip before it goes into the rotation, and optionally fix it.

Looks for two problems:
  1. black frames (the tomb reel had 24 of them in the middle)
  2. a jump where the clip loops back to the start

usage:
  check_clip.py clip.mp4                 report only (exit 1 if it needs fixing)
  check_clip.py raw.mp4 --fix out.mp4    keep the longest stretch without black frames
                                         and blend its last second into its first,
                                         so the loop has no visible jump
"""
import subprocess
import sys

import numpy as np

W, H = 160, 90          # analysis size; plenty to see a black frame or a jump
BLACK = 5               # mean brightness (0-255) below this counts as black


def probe(path, key):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries",
                          f"stream={key}", "-of", "csv=p=0", path], capture_output=True, text=True)
    return out.stdout.strip()


def frames(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf",
                          f"scale={W}:{H}:flags=area,format=gray", "-f", "rawvideo", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.float32)


def diff(a, b):
    return float(np.abs(a - b).mean())


def longest_clean_run(f):
    dark = f.mean(axis=(1, 2)) < BLACK
    best, start = (0, 0), None
    for i, d in enumerate(list(dark) + [True]):
        if not d and start is None:
            start = i
        elif d and start is not None:
            if i - start > best[1] - best[0]:
                best = (start, i)
            start = None
    return best, int(dark.sum())


def analyse(f, s, e):
    steps = [diff(f[i], f[i + 1]) for i in range(s, e - 1)]
    normal = float(np.percentile(steps, 99)) if steps else 0
    seam = diff(f[e - 1], f[s])
    return seam, normal


def report(path):
    f = frames(path)
    (s, e), dark = longest_clean_run(f)
    seam, normal = analyse(f, 0, len(f))
    jump = seam > max(2 * normal, 0.5)
    print(f"{path}: {len(f)} frames, {dark} black, loop jump {seam:.2f} "
          f"(biggest normal step {normal:.2f}){'  <- visible jump' if jump else ''}")
    if dark:
        print(f"  longest clean stretch: frames {s}-{e - 1}")
    return f, (s, e), dark == 0 and not jump


def fix(src, out, f, run):
    s, e = run
    fps = probe(src, "r_frame_rate")
    num, den = (int(x) for x in fps.split("/"))
    k = min(round(num / den), (e - s) // 3)   # blend over about one second
    width = int(probe(src, "width"))
    rate = "30M" if width >= 3000 else "10M"
    # body = run[k : n-k], then run[n-k : n] with run[0 : k] fading in over it.
    # The last output frame is exactly run[k-1], and the loop restarts on run[k].
    n = e - s
    graph = (f"[0:v]trim=start_frame={s}:end_frame={e},setpts=PTS-STARTPTS,split=3[a][b][c];"
             f"[a]trim=start_frame={k}:end_frame={n - k},setpts=PTS-STARTPTS[body];"
             f"[b]trim=start_frame={n - k}:end_frame={n},setpts=PTS-STARTPTS[tail];"
             f"[c]trim=end_frame={k},setpts=PTS-STARTPTS,format=yuva420p,fade=t=in:s=0:n={k}:alpha=1[head];"
             f"[tail][head]overlay=format=auto,format=yuv420p[mix];[body][mix]concat=n=2:v=1[v]")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-filter_complex", graph, "-map", "[v]", "-an",
                    "-c:v", "hevc_videotoolbox", "-b:v", rate, "-tag:v", "hvc1", "-pix_fmt", "yuv420p", out],
                   check=True)


def main():
    if len(sys.argv) not in (2, 4) or (len(sys.argv) == 4 and sys.argv[2] != "--fix"):
        sys.exit(__doc__)
    src = sys.argv[1]
    f, run, ok = report(src)
    if len(sys.argv) == 2:
        sys.exit(0 if ok else 1)
    out = sys.argv[3]
    fix(src, out, f, run)
    report(out)


if __name__ == "__main__":
    main()

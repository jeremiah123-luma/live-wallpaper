#!/usr/bin/env python3
"""Widen a portrait pixel-art reel to the screen's shape by growing new sides out of its own scenery.

The reel stays whole in the middle. Each side is quilted from patches of the reel itself, taken from
the same rows (so the sky gradient, the horizon and the ground line up), snapped to the art's pixel
grid, joined along the least visible seam, and never taken from the areas passed with --avoid
(the figure, a halo, a rock you'd recognise twice). The layout is worked out once, then every frame
is copied through it, so the sides keep whatever faint motion the scenery has.

usage:
  extend_sides.py in.mp4 out.mp4|- [--aspect 3024:1964] [--avoid x0:y0:x1:y1 ...] [--loose-below Y]
                  [--seed N] [--preview out.png]
"""
import argparse
import subprocess

import cv2
import numpy as np


def grid(img):
    """Pixel-art cell size and phase, from where the colour edges line up."""
    out = []
    for axis in (1, 0):
        g = np.abs(np.diff(img.astype(np.float32), axis=axis)).sum(axis=2)
        prof = g.sum(axis=0 if axis == 1 else 1)
        prof = prof - prof.mean()
        idx = np.arange(len(prof))
        best = max(((abs((prof * np.exp(2j * np.pi * idx / p)).sum()), p) for p in np.arange(3.0, 16.0, 0.01)))
        p = best[1]
        ang = np.angle((prof * np.exp(2j * np.pi * idx / p)).sum())
        out.append((p, ((-ang / (2 * np.pi)) * p + 0.5) % p))   # edges sit at phase + k*p
    return out[0][0], out[0][1], out[1][1]


def seam(err, axis):
    """Cheapest path through an overlap: err is rows x cols; axis 0 = path runs down (vertical seam)."""
    e = err if axis == 0 else err.T
    h, w = e.shape
    c = e.copy()
    for i in range(1, h):
        left = np.r_[np.inf, c[i - 1, :-1]]
        right = np.r_[c[i - 1, 1:], np.inf]
        c[i] += np.minimum(np.minimum(left, c[i - 1]), right)
    path = np.zeros(h, int)
    path[-1] = int(np.argmin(c[-1]))
    for i in range(h - 2, -1, -1):
        j = path[i + 1]
        lo, hi = max(0, j - 1), min(w, j + 2)
        path[i] = lo + int(np.argmin(c[i, lo:hi]))
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("dst")
    ap.add_argument("--aspect", default="3024:1964")
    ap.add_argument("--avoid", action="append", default=[])
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--patch", type=int, default=16)
    ap.add_argument("--overlap", type=int, default=4)
    ap.add_argument("--loose-below", type=int, default=0, help="y (px) under which patches may shift up/down and mirror")
    ap.add_argument("--shift", type=int, default=8, help="how many grid rows a loose patch may shift")
    ap.add_argument("--reuse", type=float, default=2.0, help="penalty for copying the same reel cells again")
    ap.add_argument("--mirror", action="store_true", help="also try mirrored patches (can look like ink blots)")
    ap.add_argument("--cap", default="0", help="most times one reel cell may be copied per side: N, or L=N,R=M (0 = no cap)")
    ap.add_argument("--preview")
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)

    cap = cv2.VideoCapture(a.src)
    fps = cap.get(cv2.CAP_PROP_FPS)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    sample = []
    for i in np.linspace(0, n - 1, 24).astype(int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(i))
        ok, f = cap.read()
        if ok:
            sample.append(f)
    H, W = sample[0].shape[:2]
    ref = np.median(np.stack(sample), axis=0).astype(np.uint8)
    p, px, py = grid(ref)
    aw, ah = map(int, a.aspect.split(":"))
    OW = int(round(H * aw / ah / 2)) * 2
    L = (OW - W) // 2
    print(f"grid {p:.2f}px (phase {px:.1f},{py:.1f}); {W}x{H} -> {OW}x{H}")

    # native cells fully inside the reel: cols 0..nc-1 start at px, rows 0..nr-1 start at py
    nc = int((W - px) // p); nr = int((H - py) // p)
    cy = (py + (np.arange(nr) + 0.5) * p).astype(int)
    cx = (px + (np.arange(nc) + 0.5) * p).astype(int)
    N = ref[cy][:, cx].astype(np.float32)
    bad = np.zeros((nr, nc), bool)
    for r in a.avoid:
        x0, y0, x1, y1 = map(int, r.split(":"))
        bad[(cy[:, None] >= y0) & (cy[:, None] < y1) & (cx[None] >= x0) & (cx[None] < x1)] = True

    # target native columns: from the canvas's left edge to its right edge
    jl = int(np.floor((-L - px) / p)); jr = int(np.floor((OW - 1 - L - px) / p))
    tw = jr - jl + 1; o = -jl            # target col t <-> reel col t - o
    sy = np.full((nr, tw), -1, int)       # which reel cell each target cell copies...
    sx = np.full((nr, tw), -1, int)
    fl = np.zeros((nr, tw), bool)         # ...and whether it's mirrored
    sy[:, o:o + nc] = np.arange(nr)[:, None]; sx[:, o:o + nc] = np.arange(nc)
    use = np.zeros((nr, nc))              # how often each reel cell has been copied
    P, O, S = a.patch, a.overlap, a.patch - a.overlap
    lb = int((a.loose_below - py) // p) if a.loose_below else nr   # below this row, patches may shift and mirror
    D = a.shift
    caps = {k: int(v) for k, v in (c.split("=") for c in a.cap.split(","))} if "=" in a.cap else {"L": int(a.cap), "R": int(a.cap)}
    caps = {"L": caps.get("L", 0), "R": caps.get("R", 0)}
    win = np.lib.stride_tricks.sliding_window_view

    def place(y, x, side):
        h = min(P, nr - y); y1 = y + h
        x0c, x1c = max(0, x), min(tw, x + P); w = x1c - x0c
        have = sy[y:y1, x0c:x1c] >= 0
        cur = np.where(have[..., None], N[np.clip(sy[y:y1, x0c:x1c], 0, nr - 1), np.clip(sx[y:y1, x0c:x1c], 0, nc - 1)], 0)
        best = []
        dys = [0] if y < lb else [d for d in range(-D, D + 1) if y + d >= lb and y1 + d <= nr]
        for dy in dys:
            for flip in ((False, True) if a.mirror else (False,)):
                blk = win(N[y + dy:y1 + dy], (h, w, 3))[0, :, 0]           # (positions, h, w, 3)
                if flip:
                    blk = blk[:, :, ::-1]
                d = ((blk - cur[None]) ** 2).sum(axis=3)
                cost = (d * have[None]).sum(axis=(1, 2)) / max(1, have.sum()) if have.any() else np.ones(len(d))
                uw = win(use[y + dy:y1 + dy], (h, w))[0]
                u = uw.mean(axis=(1, 2))
                ok = ~win(bad[y + dy:y1 + dy], (h, w))[0].any(axis=(1, 2))
                fresh = uw.max(axis=(1, 2)) < (caps[side] or np.inf)
                cost = (cost + 1.0) * (1 + a.reuse * u)
                for sidx in np.flatnonzero(ok):
                    best.append((cost[sidx], dy, flip, int(sidx), d[sidx], bool(fresh[sidx])))
        if not best:
            raise SystemExit(f"no clean source for rows {y}-{y1}; loosen --avoid")
        if any(c[5] for c in best):
            best = [c for c in best if c[5]]          # nothing gets copied more than --cap times if avoidable
        lo = min(c[0] for c in best)
        pick = [c for c in best if c[0] <= lo * 1.2]
        _, dy, flip, s0, d, _ = pick[rng.integers(len(pick))]
        take = ~have
        if have.any():
            sel = np.zeros_like(have)
            # vertical seam against the already-filled side, horizontal seam against the row above
            if side == "L":
                ov = slice(w - O, w)
                path = seam(np.where(have[:, ov], d[:, ov], 0), 0)
                for i in range(h):
                    sel[i, :w - O + path[i]] = True
            else:
                path = seam(np.where(have[:, :O], d[:, :O], 0), 0)
                for i in range(h):
                    sel[i, path[i] + 1:] = True
            if y > 0:
                hp = seam(np.where(have[:O], d[:O], 0), 1)
                for j in range(w):
                    sel[:hp[j] + 1, j] = False
            take |= sel & have
        rc = np.arange(x0c, x1c) - o
        take &= ~((rc >= O) & (rc < nc - O))[None]     # the reel itself stays; only its outer edge can be seamed
        cols = s0 + (np.arange(w)[::-1] if flip else np.arange(w))
        sy[y:y1, x0c:x1c][take] = (np.arange(y, y1) + dy)[:, None].repeat(w, 1)[take]
        sx[y:y1, x0c:x1c][take] = cols[None].repeat(h, 0)[take]
        fl[y:y1, x0c:x1c][take] = flip
        use[y + dy:y1 + dy, s0:s0 + w] += 1

    for side in ("L", "R"):
        use[:] = 0                         # each side keeps its own count
        x = o - P + O if side == "L" else o + nc - O
        while (side == "L" and x + P > 0) or (side == "R" and x < tw):
            y = 0
            while y < nr:
                place(y, x, side)
                y += S if y + P < nr else nr
            x += -S if side == "L" else S
    assert (sy >= 0).all()

    # full-resolution lookup: every canvas pixel -> a reel pixel, cell by cell
    X = np.arange(OW) - L
    j = np.floor((X - px) / p).astype(int)
    i = np.clip(np.floor((np.arange(H) - py) / p).astype(int), 0, nr - 1)
    t = np.clip(j - jl, 0, tw - 1)
    fx = X - (px + j * p)                                  # position inside the cell
    fy = np.arange(H) - (py + i * p)
    SY, SX, FL = sy[i][:, t], sx[i][:, t], fl[i][:, t]
    mapx = px + SX * p + np.where(FL, p - 0.001 - fx[None], fx[None])
    mapy = py + SY * p + fy[:, None]
    mapx = np.clip(np.floor(mapx + 1e-6), 0, W - 1).astype(np.float32)
    mapy = np.clip(np.floor(mapy + 1e-6), 0, H - 1).astype(np.float32)

    if a.preview:
        cv2.imwrite(a.preview, cv2.remap(sample[len(sample) // 2], mapx, mapy, cv2.INTER_NEAREST))
        if a.dst == "-":
            return
    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{OW}x{H}",
                            "-r", str(fps), "-i", "-", "-c:v", "libx264", "-crf", "12", "-preset", "slow",
                            "-pix_fmt", "yuv420p", a.dst], stdin=subprocess.PIPE)
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    while True:
        ok, f = cap.read()
        if not ok:
            break
        enc.stdin.write(cv2.remap(f, mapx, mapy, cv2.INTER_NEAREST).tobytes())
    enc.stdin.close(); enc.wait()
    print("wrote", a.dst)


if __name__ == "__main__":
    main()

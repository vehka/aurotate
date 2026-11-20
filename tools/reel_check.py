#!/usr/bin/env python3
"""Check a reel_test() recording (test/reel.lua): is a sine split into parts
continuous where the tape crosses a part boundary?

usage: tools/reel_check.py reel.wav reel_events.txt [boundary_s ...]

The second difference of a sine of amplitude A is at most A (2 pi f r / sr)^2
at speed r. A read that is off at a boundary jumps the phase and shows as a
spike far above that. For every crossing of a boundary (found in the position
log) the largest second difference within +-60 ms is printed, relative to a
clean 1x sine; a crossing passes under 2 r^2 (the jump/loop fades elsewhere in
the run are not checked here; clicks_test covers those).
"""
import sys
import numpy as np
from scipy.io import wavfile

F = 440.0
BOUNDS = [14412345 / 48000, 25933122 / 48000]


def main(wav, events, bounds):
    sr, x = wavfile.read(wav)
    if x.dtype.kind == 'i':
        x = x.astype(np.float64) / np.iinfo(x.dtype).max
    x = x.astype(np.float64)
    if x.ndim > 1:
        x = x[:, 0]
    pos = []
    for line in open(events):
        p = line.split(None, 2)
        e = p[2].split(' xruns ')[0].strip() if len(p) > 2 else ''
        if e == 'pos':
            pos.append((float(p[0]), float(p[1])))
        elif e:
            print(f'{float(p[0]):8.2f} {e}')
    pos = np.array(pos)
    A = np.percentile(np.abs(x), 99.9)
    clean = A * (2 * np.pi * F / sr) ** 2
    d2 = np.abs(np.diff(x, 2))
    print(f'amplitude {A:.3f}, clean 1x d2 {clean:.2e}')
    fails = n = 0
    # the latency of the position log against the recording isn't known
    # exactly; search a window around each crossing
    for i in range(1, len(pos)):
        (ta, pa), (tb, pb) = pos[i - 1], pos[i]
        for b in bounds:
            if (pa - b) * (pb - b) < 0 and abs(pb - pa) < 1:
                r = (pb - pa) / (tb - ta)
                tc = ta + (b - pa) / (pb - pa) * (tb - ta)
                i0, i1 = int((tc - 0.06) * sr), int((tc + 0.12) * sr)
                if i0 < 0 or i1 > len(d2):
                    continue
                m = d2[i0:i1].max() / clean
                lim = 2 * max(1, r * r)
                ok = m < lim
                n += 1
                fails += not ok
                print(f'{"PASS" if ok else "FAIL"} crossing {b:9.4f} s at rec {tc:7.2f} s, speed {r:+5.2f}: '
                      f'max d2 {m:5.2f}x clean (limit {lim:.1f})')
    # spikes anywhere, for reference (seeks and loop seams fade: a few x)
    win = int(sr * 0.01)
    k = len(d2) // win
    peaks = d2[: k * win].reshape(k, win).max(1) / clean
    print(f'whole run: max {peaks.max():.1f}x clean, median {np.median(peaks):.2f}x; '
          f'{n} crossings, {fails} failed')
    return fails if n else 1


if __name__ == '__main__':
    b = [float(v) for v in sys.argv[3:]] or BOUNDS
    sys.exit(1 if main(sys.argv[1], sys.argv[2], b) else 0)

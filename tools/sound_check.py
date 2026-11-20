#!/usr/bin/env python3
"""Check a sound_test() recording (test/sound.lua): levels per region and clicks.

usage: tools/sound_check.py sound.wav sound_events.txt

Levels: the recording is mapped to tape time from the event log during the
first 1x pass (pos = rec time + offset; the offset is then refined on the
64 s boundary, where the sound goes silent). Each region is measured away
from its edges and compared with the neutral stretch before 60 s.

Clicks: the second difference of a sine is at most A (2 pi f / sr)^2. A gain
or pan change that jumps shows as a spike far above that; a glide doesn't.
Spikes are listed with the nearest event.
"""
import sys
import numpy as np
from scipy.io import wavfile

F = 440.0


def db(x):
    return 20 * np.log10(max(x, 1e-9))


def main(wav, events):
    sr, x = wavfile.read(wav)
    if x.dtype.kind == 'i':
        x = x.astype(np.float64) / np.iinfo(x.dtype).max
    x = x.astype(np.float64)
    if x.ndim == 1:
        x = np.stack([x, x], 1)
    ev = []
    for line in open(events):
        p = line.split(None, 2)
        e = p[2].strip() if len(p) > 2 else ''
        e = e.split(' xruns ')[0]
        ev.append((float(p[0]), float(p[1]), e))

    # 1x pass: tape pos = rec time + off
    pts = [(t, pos) for t, pos, e in ev if e == 'pos' and 58 < pos < 77]
    off = np.median([pos - t for t, pos in pts])
    # refine on the 64 s boundary: the first block that goes quiet
    blk = int(sr * 0.002)
    env = np.sqrt(np.convolve(x[:, 0] ** 2, np.ones(blk) / blk, 'same'))
    s0 = int((64 - off - 0.3) * sr)
    s1 = int((64 - off + 0.3) * sr)
    seg = env[s0:s1]
    ref = np.median(seg[: len(seg) // 4])
    k = np.argmax(seg < ref * 0.5)
    off = 64 - (s0 + k) / sr  # half level about mid-glide
    print(f'offset {off:.3f} s (rec time + offset = tape time), sr {sr}')

    def rms(a, b, ch):
        i0, i1 = int((a - off) * sr), int((b - off) * sr)
        return np.sqrt(np.mean(x[i0:i1, ch] ** 2))

    nL, nR = rms(57.8, 59.7, 0), rms(57.8, 59.7, 1)
    print(f'neutral 58-60: L {db(nL):.1f} dBFS R {db(nR):.1f} dBFS')
    checks = [
        ('60-64 gain -12', 60.3, 63.7, -12, -12),
        ('64-68 dry 0', 64.3, 67.7, None, None),
        ('68-70 pan L', 68.3, 69.7, 0, None),
        ('70-71 pan L +6', 70.2, 70.8, 6, None),
        ('71-72 pan L', 71.2, 71.8, 0, None),
        ('72-76 tone +1', 72.3, 75.7, 'x', 'x'),
        ('76- neutral', 76.3, 77.0, 0, 0),
    ]
    fails = 0
    for name, a, b, eL, eR in checks:
        L, R = db(rms(a, b, 0)) - db(nL), db(rms(a, b, 1)) - db(nR)
        def ok(v, e):
            if e == 'x':
                return True
            if e is None:
                return v < -60
            return abs(v - e) < 0.5
        good = ok(L, eL) and ok(R, eR)
        fails += not good
        print(f'{"PASS" if good else "FAIL"} {name:18s} L {L:+6.1f} dB  R {R:+6.1f} dB'
              f'  (want {eL if eL is not None else "off"} / {eR if eR is not None else "off"})')

    # clicks over the whole recording
    A = max(np.max(np.abs(x[int((58 - off) * sr):int((59.5 - off) * sr), 0])), 1e-6)
    clean = A * (2 * np.pi * F / sr) ** 2
    d2 = np.abs(np.diff(x, 2, axis=0)).max(1)
    win = int(sr * 0.01)
    n = len(d2) // win
    peaks = d2[: n * win].reshape(n, win).max(1) / clean
    print(f'clean d2 max {clean:.2e}; whole run: max {peaks.max():.1f}x clean, '
          f'median {np.median(peaks):.2f}x')

    def nearest(t):
        best = min(ev, key=lambda e: abs(e[0] - t))
        return f'{best[2]} @ {best[0]:.2f}'
    hot = np.where(peaks > 3)[0]
    groups = []
    for i in hot:
        if groups and i - groups[-1][-1] <= 5:
            groups[-1].append(i)
        else:
            groups.append([i])
    print(f'{len(groups)} spots above 3x clean:')
    for g in groups[:40]:
        i = max(g, key=lambda j: peaks[j])
        t = i * win / sr
        print(f'  rec {t:7.3f} s tape~{t + off:8.3f}  {peaks[i]:6.1f}x  (near: {nearest(t)})')
    print(f'{fails} level failures')
    return fails


if __name__ == '__main__':
    sys.exit(1 if main(sys.argv[1], sys.argv[2]) else 0)

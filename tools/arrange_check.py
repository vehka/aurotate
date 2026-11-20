#!/usr/bin/env python3
"""Check an arrange_test() recording (test/arrange.lua): exact row ends, STOP
and WAIT, clicks.

usage: tools/arrange_check.py arrange.wav arrange_spans.txt arrange_ref.wav

Each span plays tape positions p(t) = start + rate * (t - ts) from rec time
ts. The right channel of test3h is pink noise, so ts is found exactly by
correlating the recording with the reference file read along p(t).

Row ends: at a jump the output is silent for a moment (the old span fades
out by position before its end, the new one fades in after the switch), so
the switch is the sample after the run of exact zeros. There the old span
must be just past its end (the switch notices the crossing one control block
late, two coming out of reverse; silent) and the new one exactly at its
start (a reverse span starts one quantum, 64 frames, below its end). A span
that continues the previous one (no jump, only the speed changes) is checked
by where the position was when the speed changed.

STOP: the tape rolls on from the end of the row before and spins down (the
pitch falls) for its time; WAIT: silence for its time; the next row starts
after both, to the block. The span before a HALT must go silent at its end.

Clicks: the second difference of the left channel (a ~100 Hz sine at the
start of test3h) against a clean sine's, shown as "x440": scaled to what the
same spot would be on a 440 Hz sine, the yardstick of the earlier phases
(sound_check, reel_check: a gain step there is ~200x, fade corners <= 8x).
"""
import sys
import numpy as np
from scipy.io import wavfile

BLOCK = 64


def read(path):
    sr, x = wavfile.read(path)
    if x.dtype.kind == 'i':
        x = x.astype(np.float64) / np.iinfo(x.dtype).max
    x = x.astype(np.float64)
    if x.ndim == 1:
        x = np.stack([x, x], 1)
    return sr, x


def main(wav, spans_path, ref_path):
    sr, x = read(wav)
    rsr, ref = read(ref_path)
    assert sr == rsr == 48000, (sr, rsr)
    spans = []
    for line in open(spans_path):
        t, a, b, rate, row, kind, secs = line.split()
        spans.append(dict(t=float(t), a=float(a), b=float(b), rate=float(rate), row=row, kind=kind,
                          secs=float(secs)))
    print(f'{len(spans)} spans')
    L, R = x[:, 0], x[:, 1]

    def template(start, rate, t_from, n):
        t = t_from + np.arange(n) / sr
        p = (start + rate * t) * sr
        return np.interp(p, np.arange(len(ref)), ref[:, 1])

    def rms(t0, t1):
        return np.sqrt(np.mean(x[int(t0 * sr):int(t1 * sr)] ** 2)) + 1e-12

    def db(v):
        return 20 * np.log10(v)

    # where each span starts in the recording (timed rows follow on)
    guess = spans[0]['t']
    for i, s in enumerate(spans):
        if s['kind'] != 'span':
            s['ts'], s['dur'] = guess, s['secs']
            guess += s['secs']
            continue
        dur = (s['b'] - s['a']) / abs(s['rate'])
        start = s['a'] if s['rate'] > 0 else s['b']
        s['start'], s['dur'] = start, dur
        # where it really starts: reverse spans one quantum below b
        s['true_start'] = start if s['rate'] > 0 else start - BLOCK / sr
        skip = min(0.02, dur * 0.2)
        n = int(min(0.4, dur - 2 * skip) * sr)
        tpl = template(s['true_start'], s['rate'], skip, n)
        win = 0.4 if i == 0 else 0.08
        lo = max(0, int((guess - win + skip) * sr))
        hi = int((guess + win + skip) * sr) + n
        seg = R[lo:hi]
        c = np.correlate(seg, tpl, 'valid')
        norm = np.sqrt(np.convolve(seg ** 2, np.ones(n), 'valid') * np.sum(tpl ** 2)) + 1e-12
        cn = c / norm
        k = int(np.argmax(cn))
        dk = 0
        if 0 < k < len(cn) - 1:
            y0, y1, y2 = cn[k - 1], cn[k], cn[k + 1]
            dk = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)
        s['ts'] = (lo + k + dk) / sr - skip
        s['corr'] = cn[k]
        guess = s['ts'] + dur

    def pos(s, t):
        return s['true_start'] + s['rate'] * (t - s['ts'])

    def zc(a, b):
        seg = L[int(a * sr):int(b * sr)]
        return np.sum(np.abs(np.diff(np.sign(seg))) > 0) / (b - a) / 2

    fails = 0
    print(' #  row  kind  span (s)          rate   ts (s)   corr   check')
    for i, s in enumerate(spans):
        nxt = spans[i + 1] if i + 1 < len(spans) else None
        want = None
        if s['kind'] == 'span':
            head = (f'{i:2d} {s["row"]:>4} span {s["a"]:7.3f}-{s["b"]:7.3f} {s["rate"]:6g} {s["ts"]:8.4f}'
                    f'  {s["corr"]:.3f}  ')
            ok = s['corr'] > 0.95
            want = s['b'] if s['rate'] > 0 else s['a']
        else:
            head = f'{i:2d} {s["row"]:>4} {s["kind"]:4s} {s["secs"]:6g} s{"":19s} {s["ts"]:8.4f}         '
            ok = True
        msg = ''
        if nxt is None:
            t_end = s['ts'] + s['dur']
            after = db(rms(t_end + 0.03, t_end + 0.33) / rms(t_end - 0.3, t_end - 0.02))
            msg = f'then HALT: {after:.0f} dB after the end'
            ok = ok and after < -60
        elif s['kind'] == 'span' and nxt['kind'] == 'span':
            cont = abs(nxt['start'] - want) < 1e-6 and np.sign(nxt['rate']) == np.sign(s['rate'])
            if cont:
                # the speed changed where the position was `err` past the end;
                # the new span's line, extrapolated back, is off by that times
                # the speed change
                err = (pos(s, nxt['ts']) - want) * sr * np.sign(s['rate'])
                if nxt['rate'] != s['rate']:
                    err = err / (1 - s['rate'] / nxt['rate'])
                good = -40 <= err <= 2 * BLOCK * abs(s['rate']) + 40
                msg = f'continues: speed changed {err:+.0f} frames past the end'
            else:
                # the silence just before the next span starts (not its own
                # end, when it is short)
                c = int(nxt['ts'] * sr)
                w = 400
                z = np.where(L[c - w:c + 100] == 0)[0]
                if len(z) == 0:
                    good, msg = False, 'no silent switch found'
                else:
                    t_sw = (c - w + z[-1] + 1) / sr
                    over = (pos(s, t_sw) - want) * sr * np.sign(s['rate'])
                    land = (pos(nxt, t_sw) - nxt['true_start']) * sr
                    # (ends are rounded to 64 frames: +-32)
                    good = -40 <= over <= 2 * BLOCK * abs(s['rate']) + 40 and abs(land) <= 4
                    msg = f'ended {over:+.0f} frames past its end (silent), next landed {land:+.1f}'
            ok = ok and good
        elif nxt['kind'] == 'stop':
            # the brake: the tape rolls on and the pitch falls
            t0 = s['ts'] + s['dur']
            q = nxt['secs'] / 4
            f1, f3 = zc(t0, t0 + q), zc(t0 + 2 * q, t0 + 3 * q)
            lev = db(rms(t0, t0 + q) / rms(t0 - 0.2, t0))
            good = f3 < f1 * 0.8 and lev > -6
            msg = f'then STOP: rolls on ({lev:+.1f} dB), pitch {f1:.0f} -> {f3:.0f} Hz'
            ok = ok and good
        if s['kind'] in ('stop', 'wait') and nxt is not None:
            t0, t1 = s['ts'], s['ts'] + s['secs']
            if s['kind'] == 'wait':
                quiet = db(rms(t0 + 0.03, t1 - 0.03) / rms(t0 - 0.6, t0 - 0.4))
                msg = f'silent: {quiet:.0f} dB; '
                ok = ok and quiet < -60
            if nxt['kind'] == 'span':
                late = (nxt['ts'] - t1) * 1000
                msg += f'next row {late:+.1f} ms after its time'
                ok = ok and abs(late) < 3
        fails += not ok
        print(head + msg + ('   PASS' if ok else '   FAIL'))

    # clicks
    a0 = int(spans[0]['ts'] * sr) + int(0.1 * sr)
    A = np.max(np.abs(L[a0:a0 + int(0.5 * sr)]))
    f0 = 100 * 40 ** (21 / 10800)
    d2 = np.abs(np.diff(L, 2))
    win = int(sr * 0.005)
    print(f'clicks: L amplitude {A:.3f}')
    worst = 0
    for i, s in enumerate(spans):
        r = abs(s['rate']) if s['kind'] == 'span' else 1
        clean = A * (2 * np.pi * f0 * max(1, r) / sr) ** 2
        i0 = int(s['ts'] * sr) - win
        t_next = spans[i + 1]['ts'] if i + 1 < len(spans) else s['ts'] + s['dur'] + 0.3
        seg = d2[max(0, i0):int(t_next * sr) - win] / clean
        if len(seg) == 0:
            continue
        k = int(np.argmax(seg))
        x440 = seg[k] * (f0 * max(1, r) / 440) ** 2
        worst = max(worst, x440)
        where = (max(0, i0) + k) / sr - s['ts']
        print(f'  {i:2d} {s["kind"]:4s}: {x440:4.1f} x440 at {where:+.3f} s from its start')
    print(f'worst {worst:.1f} x440 (a gain step: ~200)')
    print(f'{fails} failures')
    return fails


if __name__ == '__main__':
    sys.exit(1 if main(*sys.argv[1:4]) else 0)

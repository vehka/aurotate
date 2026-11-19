# aurotate

An audio-anthropology workbench for norns: play recordings hours long on an
analog-feeling tape, mark and annotate them, and give regions their own
sound. Work in progress; see `docs/PLAN.md`.

Current state: **phase 2, analysis and cue.** A SuperCollider engine streams
the file from disk through a RAM ring window, so length is limited by disk,
not RAM. When a tape is opened for the first time it is analysed in the
background (about 1 minute per 2 hours on a Pi 3; the tape plays meanwhile).
The analysis writes a waveform overview and two decimated copies (proxies)
that stay in RAM. They give fast-forward and rewind the real sound of tape
at speed, up to 256×, and a far seek plays at once, muffled, then comes into
focus.

## Requirements

- norns 3.x (developed on the 260616 beta; Pi 3 and Pi 4)
- 48 kHz WAV or FLAC files work best (other rates play at the right speed)
- `sox` and `gcc` on the device for the analysis (both are on standard
  norns images); the helper `aurpeaks` is built on first use
- After installing or updating: SYSTEM > RESTART (the engine is a new class)

## Controls

| | |
|---|---|
| K2 | play / stop (spins up / down) |
| K3 | loop in, then loop out (starts the loop); again: loop off |
| K1+K3 | cancel a pending loop in |
| E2 | scrub with inertia (the first turn takes over from play and coasts) |
| K1+E2 | seek ±1 min per tick (E2 ticks just after it are ignored, so it doesn't fall into scrub) |
| E3 | speed: −64…64× (−256…256× once analysed), detents at 0 and 1× |

Choose a tape in PARAMS > TAPE > tape. The same group holds speed, level,
spin-up time, the lifter (how much of the tape you hear at speed: 0 % = full
head contact, 100 % = lifted, silent), the focus time, scrub feel (nudge,
acceleration, stop time), loop points, the ring window size, the seek/seam
fade time and the proxy memory budget.

The analysis cache lives in `dust/data/aurotate/cache/` (about 85 MB per
2-hour mono tape); delete a tape's folder there to redo it. Play / stop, speed and the loop
can be MIDI-mapped.

## Tests (on the device, from the REPL)

```lua
transport_test()        -- ~8 min; results in dust/data/aurotate/transport_*.txt
transport_test(nil, {analysis = true, cue = true})  -- fresh analysis while playing; cue speeds
clicks_test()           -- records the output while seeking/looping a sine
```

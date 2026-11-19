# aurotate

An audio-anthropology workbench for norns: play recordings hours long on an
analog-feeling tape, mark and annotate them, and give regions their own
sound. Work in progress; see `docs/PLAN.md`.

Current state: **phase 1, transport.** A SuperCollider engine streams the file
from disk through a RAM ring window, so length is limited by disk, not RAM.

## Requirements

- norns 3.x (developed on the 260616 beta; Pi 3 and Pi 4)
- 48 kHz WAV or FLAC files work best (other rates play at the right speed)
- After installing or updating: SYSTEM > RESTART (the engine is a new class)

## Controls

| | |
|---|---|
| K2 | play / stop (spins up / down) |
| K3 | loop in, then loop out (starts the loop); again: loop off |
| K1+K3 | cancel a pending loop in |
| E2 | scrub with inertia (the first turn takes over from play and coasts) |
| K1+E2 | seek ±1 min per tick |
| E3 | speed: −64…64×, detents at 0 and 1× |

Choose a tape in PARAMS > TAPE > tape. The same group holds speed, level,
spin-up time, scrub feel (nudge, acceleration, stop time), loop points, the
ring window size and the seek/seam fade time. Play / stop, speed and the loop
can be MIDI-mapped.

## Tests (on the device, from the REPL)

```lua
transport_test()        -- ~8 min; results in dust/data/aurotate/transport_*.txt
clicks_test()           -- records the output while seeking/looping a sine
```

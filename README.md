# aurotate

An audio-anthropology workbench for norns: play recordings hours long on an
analog-feeling tape, mark and annotate them, and give regions their own
sound. Work in progress; see `docs/PLAN.md`.

Current state: **phase 4, marks, regions and notes.** A SuperCollider engine streams
the file from disk through a RAM ring window, so length is limited by disk,
not RAM. When a tape is opened for the first time it is analysed in the
background (about 1 minute per 2 hours on a Pi 3; the tape plays meanwhile).
The analysis writes a waveform overview and two decimated copies (proxies)
that stay in RAM. They give fast-forward and rewind the real sound of tape
at speed, up to 256×, and a far seek plays at once, muffled, then comes into
focus.

The screen shows the tape around a fixed playhead, zoomable from 1 s to the
whole tape, with the whole tape in a strip below (a bracket marks the part
shown above). Louder sound draws taller, brighter-sounding sound draws
brighter. While a tape is analysed for the first time its waveform grows in
as the pass goes; a far seek draws the waveform near the playhead dithered
until the tape is in focus. The four dots at the top are pages (collection,
tape, regions, settings); only the tape page exists so far.

On the tape you drop **marks** (points) and **regions** (stretches), and give
each a label, a note and tags. Regions show as bright bands with the waveform
cut out of them, marks as thin lines; a small flag at the top is filled when
the mark or region has a note. Notes are written on a USB keyboard (just
start typing) or with the on-screen text entry. They are saved per tape, on
their own, in `dust/data/aurotate/tapes/` (not in PSETs), a couple of seconds
after each edit; the previous save is kept as `.bak`. The script reopens the
tape you had open last, where you left it.

## Requirements

- norns 3.x (developed on the 260616 beta; Pi 3 and Pi 4)
- 48 kHz WAV or FLAC files work best (other rates play at the right speed)
- `sox` and `gcc` on the device for the analysis (both are on standard
  norns images); the helper `aurpeaks` is built on first use
- After installing or updating: SYSTEM > RESTART (the engine is a new class)

## Controls

| | |
|---|---|
| E1 | zoom: 1 s … 10 min across the screen, then the whole tape |
| K1+E1 | page |
| E2 | scrub with inertia (the first turn takes over from play and coasts) |
| K1+E2 | move along the whole tape, one strip pixel (1/128 of the tape) per tick (E2 ticks just after it are ignored, so it doesn't fall into scrub) |
| E3 | speed: −64…64× (−256…256× once analysed), detents at 0 and 1× |
| K2 | play / stop (spins up / down) |
| K3 tap | mark |
| K3 hold | region in (the selection grows from there); K3 again: region out |
| K1+K3 | open the mark or region under the playhead (label, note, tags, times, delete); with a region in pending: cancel it |
| K1+K2 | loop the region under the playhead; again: loop off |
| K3 with no tape | choose one |

In the popup: E2 picks a row, E3 changes it (tags: step through the palette,
K3 toggles; in / out / time: 0.1 s a tick, 1 s with K1, and the tape jumps
there to let you hear it), K3 edits, K2 closes. The note editor scrolls with
E2/E3; K3 opens the text entry.

USB keyboard, on the tape page:

| | |
|---|---|
| typing | writes the note of the mark or region under the playhead (a new mark if there is none) |
| Enter | close the note (Shift+Enter: new line); arrows, Home, End, Backspace, Delete edit |
| Esc | play / stop; resuming backs up by *resume rewind* (PARAMS > TAPE, 2 s) |
| F6 / F7 | −5 s / +5 s |
| F8 | mark |
| F9 | region in, then out |

(F1–F5 open the system menu, as everywhere on norns.) The tag palette is
`dust/data/aurotate/tags.lua`, a plain list you can edit.

Choose a tape with K3 (when none is open) or in PARAMS > TAPE > tape. The same group holds speed, level,
spin-up time, the resume rewind for Esc, the lifter (how much of the tape you hear at speed: 0 % = full
head contact, 100 % = lifted, silent), the focus time, scrub feel (nudge,
acceleration, stop time), loop points, the ring window size, the seek/seam
fade time and the proxy memory budget.

The analysis cache lives in `dust/data/aurotate/cache/` (about 85 MB per
2-hour mono tape); delete a tape's folder there to redo it. Play / stop, speed and the loop
can be MIDI-mapped.

## Tests (on the device, from the REPL)

```lua
notes_test()            -- marks/regions store (also off the device: lua5.3 test/model_test.lua)
transport_test()        -- ~8 min; results in dust/data/aurotate/transport_*.txt
transport_test(nil, {analysis = true, cue = true})  -- fresh analysis while playing; cue speeds
clicks_test()           -- records the output while seeking/looping a sine
dbg_status()            -- transport state, redraw time and Lua heap
dbg_shot('name')        -- screenshot to dust/data/aurotate/name.png
```

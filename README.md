# aurotate

An audio-anthropology workbench for norns: play recordings hours long on an
analog-feeling tape, mark and annotate them, and give regions their own
sound. Work in progress; see `docs/PLAN.md`.

Current state: **phase 9**: marks, regions and notes (phase 4), the
**regions list** with a reader and **notes export as Markdown** (phase 5),
**per-region sound** (phase 6), the **collection**, **split-file reels**
and the **wall clock** (phase 8), and **downloads** by URL and from
Freesound (phase 9). Phase 7 (region voices) is deferred. A SuperCollider engine streams
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
tape, regions, settings); all but settings exist so far.

On the tape you drop **marks** (points) and **regions** (stretches), and give
each a label, a note and tags. Regions show as bright bands with the waveform
cut out of them, marks as thin lines; a small flag at the top is filled when
the mark or region has a note. Notes are written on a USB keyboard (just
start typing) or with the on-screen text entry. They are saved per tape, on
their own, in `dust/data/aurotate/tapes/` (not in PSETs), a couple of seconds
after each edit; the previous save is kept as `.bak`. The script reopens the
tape you had open last, where you left it.

The **regions page** (K1+E1 to the third dot) lists every mark and region
in tape order, nested regions indented. It follows the playhead until you
pick something with E2; a bar at the left edge marks what the playhead is
in. E3 filters by tag. K3 jumps the tape there, K1+K3 opens the reader (the
whole note, E2/E3 scroll; K3 there edits, K1+K2 loops the region), K1+K2
loops the selected region, K2 plays / stops. On a USB keyboard Up/Down,
PgUp/PgDn and Home/End select, Enter jumps; the transport hotkeys work as on
the tape page.

**Region sound:** a region can change how the tape sounds while the
playhead is inside it: *dry* (the direct sound), *send a* / *send b* (into the
fx mod's two send chains), *gain*, *pan* and *tone* (a tilt: dark … bright).
Set them in the region's popup (K1+K3, the rows after *out*: E3 changes, K1+E3
in finer steps, K3 resets the row) or in PARAMS > SOUND > *region here*,
which always shows the innermost region under the playhead and edits it, so
those params can be MIDI-mapped to tweak whatever region is playing. Where
regions overlap they combine: dry multiplies, sends and gain (dB), pan and
tone add. Changes glide at the boundaries (*boundary glide*, 50 ms) and start
exactly at them, also after a seek or a loop wrap. *region sound* off makes
every region neutral. A region with sound has a checkered bottom edge on the
tape and a ♪ on the regions page.

**Send-as-insert:** dry 0 % and send a (or b) 100 % hears the region only
through that send's effects: an effect on just that stretch of tape. In the
fx mod, set the send's own tap level to 0, so it gets only what regions send
it. Such a region has a checkered top edge too. Without the fx mod, or with
nothing in the send, the sends go nowhere: the popup says `(no fx)` or
`(empty)` next to a send, and `SILENT` when the region can't be heard.

**Collection** (K1+E1 to the first dot): every tape you have opened, newest
first (E3: by name, by length). Each row has the title, a dot when it has
notes and the length; ≡ marks a reel, `?` a tape whose file is gone. Under
the list is the selected tape's overview with where you left it, its notes
and when it was recorded. E2 selects, K3 opens it (and goes to the tape),
K3 on the last row adds a tape, K2 plays / stops. K1+K3 opens the tape's
popup:

- *start*: when the recording started. Read from the WAV's BWF `bext`
  chunk when there is one (`FROM FILE`); otherwise set it here (`BY HAND`):
  E3 ±1 min, K1+E3 ±1 h, K3 types it (`YYYY-MM-DD HH:MM:SS`; the first guess
  is the file's time stamp minus its length; empty goes back to the file's).
- *join*: field recorders split long takes into 2/4 GB files. E3 picks how
  many of the following files in the folder belong to this one (`ok` when
  their `bext` time stamps say they continue it), K3 twice joins them into a
  **reel**: a small text file `<first part>.reel` next to the parts, one
  file name per line, which plays as one seamless tape. Notes already made on
  the parts move onto the reel at the right places. You can write a `.reel`
  by hand too, and open it like any tape. Opening a file that the next file
  continues says so in the header.
- *relink*: a tape whose file was moved or renamed: K3 searches
  `dust/audio` for a file with its name and size, E3 picks, K3 twice moves
  its notes (and its analysis) there.
- *source*: a downloaded tape: who made it (the license is in the popup's
  title); K3 shows the whole credit line. *author* and *license*: for a tape
  from a plain URL, type them (K3) so it can be credited.
- *forget*: drops it from the list; its notes stay on disk.

**Downloads:** K3 on the last row (*+ add a tape*) opens the add popup:
*file* (the file browser), *url* (type an http/https link), *freesound*
(type a Freesound sound id, or paste a link to the sound), *queue*, *login*,
*api key*, *client id*. A USB keyboard makes the typing easy. You can also
write requests into `dust/data/aurotate/downloads.txt` (over SMB or in
maiden), one per line, `https://…` or `freesound:12345`, and fetch them with
*queue*; requests that fail are written back into the file as comments.
From maiden: `download('https://…')`, `download('freesound:12345')`,
`downloads()`.

Downloads run one at a time in the background and show as rows in the
collection with their progress (K3 twice cancels; a failed one says why,
K3 drops it). Plain URLs go into `dust/audio/aurotate/`, Freesound sounds
into `dust/audio/aurotate/freesound/`. A file that isn't WAV or FLAC is
converted to FLAC at 48 kHz (ogg, aif with sox; mp3 and m4a need ffmpeg,
which the script offers to install). Next to each file is
`<file>.source.txt` with the credit line and where it came from, and the
tape's notes know it too: the tape popup and `notes.md` give the credit
(marking non-commercial licenses). A Freesound sound's description and tags
become its first note, a mark at 0:00.

**Freesound** needs your own API credentials, once: log in at
freesound.org and apply at https://freesound.org/apiv2/apply. Put the
*client id* and the *client secret* (the API key) into the add popup's
*client id* and *api key* rows, or into `dust/data/aurotate/freesound.lua`:
`return { api_key = '…', client_id = '…' }`. With the key alone you get the
sound's **preview** (an ogg, good enough to listen and annotate; the tape
says `(preview)`). For the **original file**, log in: *login* (K3) writes a
link to `dust/data/aurotate/freesound_login.txt` (and prints it in maiden);
open it on a computer or phone, allow access, and type the code Freesound
shows into the text entry that opened (within 10 minutes; maiden:
`freesound_code('…')`). The login lasts until you log out (K3 twice on
*login*) or revoke it on freesound.org; the tokens stay in
`freesound.lua`, readable only by the `we` user.

On a USB keyboard Up/Down select, Enter opens, Esc plays / stops.

**Wall clock:** PARAMS > TAPE > *clock* shows *time of day* instead of the
offset (in the header, the regions list and the popup), for tapes whose
start is known. The notes export always gives both.

**Export:** PARAMS > TAPE > *export notes (md)* writes
`dust/data/aurotate/exports/<tape>/notes.md` (reach it over SMB or `scp`):
one section per mark and region in tape order, with its times (and the time
of day, when the recording's start is known), label, enclosing region, tags
(as `#hashtags`), sound settings and note. The previous export is kept
as `notes.md.bak`. The `<!-- aur:m3 -->` lines tie each section to its mark or
region, for reading edits back in later; leave them as they are.

## Requirements

- norns 3.x (developed on the 260616 beta; Pi 3 and Pi 4)
- 48 kHz WAV or FLAC files work best (other rates play at the right speed);
  the parts of a reel must share rate and channel count
- `sox` and `gcc` on the device for the analysis (both are on standard
  norns images); the helper `aurpeaks` is built on first use
- for downloads: `curl` (offered for install when missing), and `ffmpeg`
  for mp3 / m4a (offered when one comes in)
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
| K1+K3 | open the mark or region under the playhead (label, note, tags, times, sound, delete); with a region in pending: cancel it |
| K1+K2 | loop the region under the playhead; again: loop off |
| K3 with no tape | choose one |

The regions page has its own keys; see above.

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

Choose a tape in the collection, with K3 (when none is open) or in PARAMS > TAPE > tape. The same group holds speed, level, the clock,
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
sound_test()            -- region sound: records a sine through test regions;
                        -- then tools/sound_check.py sound.wav sound_events.txt
reel_test()             -- reels: records a sine split into 3 parts across the
                        -- boundaries; then tools/reel_check.py reel.wav reel_events.txt
export_notes()          -- same as PARAMS > TAPE > export notes (md)
dbg_status()            -- transport state, redraw time and Lua heap
dbg_shot('name')        -- screenshot to dust/data/aurotate/name.png
```

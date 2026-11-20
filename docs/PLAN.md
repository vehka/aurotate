# aurotate: implementation plan (draft 10, phase 9 built; phase 7 deferred)

An audio-anthropology workbench for norns: play recordings hours long on an
analog-feeling tape, mark points and regions, attach notes and per-region
sound treatment, trigger regions from MIDI (later grid), export the notes.

Target: norns 3.x (the user's fork, fates / Pi 4 first). Two reasons: fx v2
only runs on 3.x, and the 4TRK UI we borrow from lives there. A Pi 3 (1 GB)
mode is designed in from the start, with smaller budgets (see §2.5).

---

## 1. Why concrete stops at 320 s, and what to do instead

concrete keeps the audio in softcut. A softcut buffer is fixed at 2^24
samples per channel (~349 s at 48 kHz), and that limit is compiled into crone.
Raising it means rebuilding norns, and hours of audio would not fit in RAM in
any case.

Loading the whole file into RAM doesn't work either:

| file | float32 in RAM (as SC buffers hold it) |
|---|---|
| 1 h stereo 48 k | 1.38 GB |
| 3 h stereo 48 k | 4.15 GB |

norns userland on the Pi 4 is (to verify: `getconf LONG_BIT`) 32-bit armhf.
That gives scsynth about 3 GB of address space whatever the board's RAM, so
whole-file loading stops at about 1 h even on an 8 GB Pi 4. Streaming is
needed whatever the hardware.

### Phase 0 spike result (2026-11-19, shield: Pi 3B+, 903 MB, 32-bit, 260616)

The SC-engine design (option C below) works on the weakest target, the Pi 3. Test file: 3 h, stereo, 16-bit 48 kHz WAV (2.07 GB),
ring 64 s (16 × 4 s chunks, 24.6 MB), cold reads from the SD card.

| phase | dropouts | xruns | chunk read avg / max | seek to sound avg / max |
|---|---|---|---|---|
| 1× play, 60 s + 30 s | 0 | 0 | 43 / 51 ms | — |
| seeks within ±20 s ×10 | 0 | 0 | — | 16 / 16 ms (already resident) |
| seeks anywhere in 3 h ×16 | 0 | 0 | 43 / 60 ms | 52 / 60 ms |
| FF 2, 4, 8, 16, 32, 64× (full res) | 0 | 0 | ≤ 58 ms | — |
| REW 1×, 4× | 0 | 0 | ≤ 58 ms | — |
| jog: random walk −3…3×, 30 s | 0 | 0 | ≤ 53 ms | — |
| FLAC (30 min): seeks, FF 16/64×, REW 4× | 0 | 0 | 41 / 56 ms | 42 / 51 ms |

- A 4 s chunk takes about 40 ms to read, about 100× realtime. At 64×,
  full-resolution streaming still keeps up (11.9 MB/s). Above about 64× on
  a Pi 3, the proxies are needed.
- scsynth RSS was 159 MB (fx rack loaded) and stayed flat. The ring costs
  24.6 MB. MemAvailable stayed above 420 MB.
- **Analysis**, all disk-bound, about 95–100 s per pass over 3 h:
  `tools/aurpeaks` (C, 2.16 MB of peaks + RMS + brightness) 93 s; sox P2
  (750 Hz mono) 94–98 s; P1 (6 kHz mono) 102 s. One pass through `tee` can
  do all of them at once, so analysis on first open takes about 100 s.
- **Peaks in Lua:** unpacking 540 k bins into tables took 0.96 s and 38 MB,
  too heavy. Instead, keep the file as one string, read it with
  `string.byte` while drawing, and have the helper write pre-reduced
  levels (×16, ×256). That loads instantly and uses about 2 MB.
- FLAC encodes at about 21× realtime on the Pi 3: affordable as an import
  step, but it costs CPU.
- **Gotchas found:** `==` between UGens is identity in sclang (use
  `BinaryOpUGen('==', …)`). A command named `load` collides with Lua's
  `engine.load`. `_norns.audio_get_xrun_count()` resets on every read.
- **Precision:** `BufRd` takes its phase as float32. With more than 2^24
  frames, or for varispeed at large indices, that is not good enough. So
  the voice plays the ring with **PlayBuf**, whose phase is internally
  double, and runs a parallel `Phasor` in file frames only for bookkeeping.
  float32 error there is ≤ 32 frames at 3 h, which doesn't matter.

Not yet measured: CPU under load. top's single-sample readings were noisy,
with peaks during FF 32/64. Pi 4 runs. Real field recordings.

### Options considered

| | approach | verdict |
|---|---|---|
| A | softcut | no: 349 s ceiling |
| B | new crone C++ voice ("LongTape", like MultiTape, but streaming from disk) | the most efficient (16-bit chunks, own worker thread), but it ties a script to a forked core. Keep it as a fallback if B-measurements below fail |
| **C** | **SuperCollider engine: RAM ring window + always-resident decimated proxies** | **chosen**: no core changes; works with fx v2 per-voice sends; the same code path covers "whole file fits" (Pi 4, short files) and "window only" (Pi 3, long files) |
| D | `VDiskIn` alone | forward only, no jog or reverse, a gap on every seek: not enough by itself. Possibly useful for MIDI region voices (§2.4) |

## 2. Engine architecture (Engine_Aurotate.sc + lib/sc/*.sc)

### 2.1 Ring window ("the head")
- One stereo `Buffer` of W seconds (W = param; Pi 4 default 600 s = 230 MB,
  Pi 3 default 90 s = 35 MB). If the file is shorter than W, the whole file
  is loaded and nothing below needs to run.
- The voice runs a `Phasor` in **file frames**; `BufRd` reads at
  `filePos % W`. Interpolation is cubic, rate is any real number
  (jog, reverse, varispeed).
- An sclang **Feeder** gets the play position from the voice via `SendReply`
  at ~20 Hz, with no round trip through matron. It keeps
  `[pos - behind, pos + ahead]` resident in 4 s chunks with
  `b_read(path, fileFrame, n, bufFrame)`, reading more ahead in the direction
  of travel. It keeps a table of chunk states (empty / pending / ready).
- The voice reads a "valid" flag per chunk (a small control-rate buffer the
  Feeder writes). If the playhead reaches a chunk that isn't ready, the voice
  crossfades to the proxy (§2.2) and doesn't click.

### 2.2 Proxies ("the tape you can always hear")
Each file gets decimated copies that stay in RAM: lowpassed, then resampled.

| level | rate | 3 h stereo | 3 h mono |
|---|---|---|---|
| P1 ÷8 | 6 kHz | 518 MB | 259 MB |
| P2 ÷64 | 750 Hz | 65 MB | 32 MB |

P1 and P2 serve three purposes:
1. **Cue / shuttle sounds.** Playing P2 at 64× gives the real 64× spectrum.
   Fast-forward therefore sounds like a tape pressed to the head, with
   chatter and squeal, and the cost is no higher than normal playback. A
   "lifter" param (OP-1 / reel-to-reel) sets how much head contact you hear:
   a bandpassed, quieter, slightly distorted cue path.
2. **Seek far away.** Playback starts at once from P1 (muffled and narrow)
   and crossfades to full resolution when the chunks arrive. In practice the
   tape "comes into focus". The UI shows this too (§4.3).
3. **Pi 3 mode.** Mono P2 only (32 MB for 3 h). P1 only where it fits.

The level for a given speed is chosen as `|rate| ≥ decimation`, with a
crossfade between levels.

**As built (phase 2):** proxies are **mono** on every platform (P1 stereo on
the Pi 4 is deferred: at ≥ 8× or during a 50 ms focus nobody hears the
width). Each level crossfades in over one octave of speed around its factor
(P1: 5.7–11.3×, P2: 45–90×). A missing chunk is covered by P1 if loaded,
else P2. The proxies are lowpassed at 0.45 × their rate × |speed| to remove
interpolation images. With P2 loaded the shuttle goes to ±256× (aliasing
above 64×, since P2 is the coarsest level; masked by the lifter; a P3 ÷512
is the fix if it bothers by ear). sclang loads proxies in 2^19-frame pieces
between ring reads (the NRT queue is shared), and the ring stops streaming
above the speed where a proxy takes over (11.3× with P1, 90× with P2 only).

### 2.3 Analysis pass (one time per file, cached; measured, see §1)
- One disk pass, as a background job at nice +10:
  `sox in -t raw - | tee >(aurpeaks …) >(sox … P1) | sox … P2`.
  `tools/aurpeaks` is a small C helper, built on the device with gcc. It
  writes 20 ms bins (min, max, RMS, brightness) plus reduced levels, and
  reads the BWF `bext` timestamp.
- Cache in `norns.state.data/cache/<id>/` with `id = hash(path, size, mtime)`.
- The tape is playable before analysis finishes: the window streams, there is
  no proxy yet, and the waveform appears in pieces as the analysis proceeds.
- **As built:** `tools/analyze.sh` (named FIFOs rather than `>(…)`, so every
  branch is waited for), detached with `setsid nice -n 10 ionice -c2 -n7`;
  one job at a time, killed (process group) on another open or cleanup.
  `aurpeaks` reads raw s16 on stdin, is built on first use into
  `dust/data/aurotate/bin/`, and writes `AURPK2` (level 0 + ×16 + ×256,
  format in its header) with `n0 = 0` until done, so a reader can draw level 0
  from a growing file (phase 3). Proxies are only used after the pass ends.

### 2.3b File formats (working copies; the masters live elsewhere)
- **Import** converts every tape into one working format:
  - 48 kHz, so the engine never resamples;
  - 16-bit;
  - **mono if the source is mono**, which halves disk, RAM and analysis;
  - **FLAC** by default. It seeks and streams as fast as WAV (§1) and real
    field recordings compress to about half. WAV is the option for anyone
    who wants zero decode CPU.
- Import also splits the BWF metadata into the tape document, and joins
  recorder split files (§6.1) into one virtual tape.
- Proxies: 16-bit mono WAV, never FLAC (they are loaded whole).

### 2.4 Voices
- **Tape voice** (one): the transport. Play/stop with a spin-up/spin-down
  ramp, rate glide, jog with inertia (port the MultiTape `jog_turn` model),
  shuttle, loop region, transcription auto-rewind.
- **Region voices** (four, polyphonic): triggered by MIDI, later by grid.
  Each has its own small ring (e.g. 20 s) and the same Feeder logic. For
  instant attack, cache the first 3 s of every MIDI-mapped region at full
  resolution. Until its ring catches up, a voice reads from that cache and
  falls back to the proxy if it has to. *Superseded by the AurVoice plan
  below (2026-11-20).*
- **Region voices, revised plan (2026-11-20; phase 7 deferred):** not a
  second AurTape per voice. Three reasons, from the phase 6 code:
  - AurTape allocates its proxies per instance (`prApplyProxy`); P1 for a
    2 h tape is 83 MB, so copies per voice don't fit the shield. Shared
    proxies would be a refactor of their own.
  - The AurTape synth is transport machinery (3 PlayBufs, proxy crossfades
    and LPFs, lifter cue, jog, loop seams). A triggered region needs almost
    none of it, and 4 more copies on a Pi 3 risk the CPU budget (§9.3).
  - 5 independent streams seeking on an SD card share one NRT queue; each
    feeder keeps one read in flight, so the voices delay each other's chunks.

  Instead a light **`AurVoice`** class (`lib/sc/AurVoice.sc`), two modes:
  1. **Resident** (build first, maybe the only mode): when a region is
     MIDI-mapped, read just its range into its own Buffer (`b_read` with
     offset + length; split at reel part boundaries, §6.1). The voice is a
     PlayBuf over it: instant attack, loop inside the region and reverse for
     free, any `rate` (a MIDI note may set pitch), nothing streams while it
     plays. Region length is capped by a budget param, e.g. shield 16 × 10 s
     stereo ≈ 61 MB; most triggered material (a phrase, a word, an event)
     fits.
  2. **Streamed** (long regions; later, if ever): SC's `cueSoundFile` +
     `VDiskIn` pattern. The cued buffer *is* the head cache (instant
     attack), then it streams. Forward only; loop / retrigger need a second
     cued buffer to swap to. Until then a long region plays its first N s
     resident.

  Each voice has its own `AurOut`, fed from the voice's position bus, so a
  region's sound (and nested regions inside it) applies the same way as on
  the transport. Move the segment partition up to the engine and share it
  (now per AurOut). Add `rate` (product, §3) to `lib/sound.lua`. Voices:
  2 on the shield, 4 on the Pi 4. Softcut was considered and rejected for
  this: its output bypasses AurOut (a second implementation of region sound,
  fx sends per voice unverified), voices are mono (a stereo voice takes two
  of six), 349 s of buffer shared with other mods, no resampling on read.
  It may suit the "audio notes" idea (IDEAS.md) instead.

  **Open design questions** (decide before building):
  - Trigger modes: one-shot / gate / loop, or all three? Does the MIDI note
    set pitch (`rate`), or only choose the region?
  - The transport while a voice plays: independent, ducked, or paused?
  - Polyphony: may the same region play twice at once? Choke groups?
  - UI: voice playheads on the tape view; MIDI learn from the region popup.
  - Priority: voices are for performance; for the ethnographer workflow,
    the keyboard items and region LFOs in IDEAS.md may matter more.
- Each voice has an output stage: `gain · pan · tone (tilt EQ) → dry → main bus`,
  `→ sendA`, `→ sendB`.
  - **"send-as-insert"** = dry 0, send 1, with the fx send return set to
    100 % wet. Per region, this is a send that behaves like an insert.
  - fx v2 per-voice sends go to `FxSetup.sendA/B`. These are nil while a send
    is empty, so the engine re-checks them when the rack changes. The UI warns
    when a region's dry is at 0 and its send is empty, because then the
    region is silent.
  - Reserve a **per-voice insert slot** for aurotate's own effects (voice
    transformation, phase 7). `FxUnit.all` exposes the registered effect
    functions, so a voice can instance an fx v2 effect *inside the voice*.
    That makes a true per-region insert, without the global rack.
- **As built (phase 6):** `lib/sc/AurOut.sc`, one per voice, in a voice group
  after the tape synth (tape → voice bus → AurOut → `context.out_b`, sends).
  Order: tilt EQ (`BLowShelf` 250 Hz −9·tone dB, `BHiShelf` 2.5 kHz +9·tone
  dB), balance (unity in the middle), gain, then dry / send A / send B. In fx
  v2, `FxSetup.sendA/B` are the send chain buses and exist as soon as the rack
  is built (an empty send has its return muted, so writing to it is silent);
  the engine looks them up every 2 s (fx v1, a late rack) and writes to a
  private bus while there is none. Cost: within the noise (idle 18.9 %, 1×
  20.8 % scsynth on the shield; phase 2 had 20.6 / 20.0).

### 2.5 Memory budget (params, with per-platform defaults from MemTotal)
| | Pi 4 / fates 4 GB | Pi 3 / shield 1 GB |
|---|---|---|
| ring window | 64 s is enough for streaming (§1); more only buys instant seeks nearby | 64 s (24.6 MB) |
| proxies | P1 stereo + P2 | P2 mono (+P1 mono for files under ~1 h) |
| region voice rings | 4 × 20 s | 2 × 10 s |
| region head cache | 64 regions × 3 s | 16 × 3 s |

Show the budget in settings, OP-1-style, as a "tape remaining" style
gauge.

## 3. Data model and persistence (lib/model.lua, lib/store.lua)

```
tape    = { id, path(s), duration, sr, ch, bext_origin?, last_pos, title, meta }
mark    = { id, t, label, note, tags }                         -- a point
region  = { id, t0, t1, label, note, tags, color,
            snd = { dry, send_a, send_b, gain, pan, tone, rate, insert? },
            midi = { ch, note }?, loop?, fade_in, fade_out }
```

- A **per-tape document**: `norns.state.data/tapes/<id>.lua`. It is versioned
  (`version = 1`), saved (debounced) after every edit, keeps a `.bak` of the
  previous save, and has migrations from day one.
- The PSET holds the performance state: current tape, budgets, cue
  character, MIDI channel. The tape documents are not PSET data, because
  annotations must not change when a different PSET loads.
  `params.action_write` stores only a reference to the tape.
- **Overlapping regions mix.** Sound belongs to a *place on the tape*, so
  every voice, the transport or a MIDI-triggered region voice, hears the
  combination of all regions containing its position:

  | field | combined as | why |
  |---|---|---|
  | send_a, send_b | sum, clipped to 1 | effects layer |
  | dry | product | any region can take the dry away; send-as-insert stays send-as-insert inside a parent |
  | gain | product (dB add) | |
  | pan, tone | sum, clipped | |
  | rate (region voices) | product | |
  | inserts | chained, outermost (longest) region first | The voice has a fixed number of insert slots (start with 2). If more overlap, the innermost win and the UI marks the overflow |
  | mask | **OR**; the strongest settings win | fails closed: if any masking region applies, masking is on |
  | redaction | overrides everything | |

  When a voice crosses a boundary, the combined settings glide (default
  50 ms). Lua computes the combination (a sorted interval list, recomputed
  only when a boundary is crossed). The engine receives one flat settings
  set per voice.

  **As built (phase 6):** Lua (`lib/sound.lua`) turns the regions with sound
  into segments (only those regions make boundaries; neutral stretches are
  left out, equal neighbours joined) and sends the list when it changes
  (`snd_clear n`, `snd_seg` × n, `snd_commit n`). sclang holds it as a
  partition of the tape. The synth holds the current segment's bounds and
  three sets (previous, current, next) and switches on the control block
  where the position crosses a bound, then asks sclang to re-centre
  (SendReply, also 8×/s while outside, so a lost reply or a double crossing
  recovers). The position comes from the tape synth on a control bus, in
  seconds, with a jump/wrap trigger; after a jump or wrap the new settings
  apply without a glide for 30 ms (the jump lands in silence). Boundaries
  are thus exact to a control block (measured: ~1 ms between boundaries),
  not to the 20 Hz position poll. Gain −60 dB means off and wins over any
  added gain. Not built yet: `rate` (region voices, phase 7), inserts, mask.
- "Current region" params (`aur_cur_dry`, `aur_cur_send_a`, …) mirror the
  innermost region under the playhead. You can PMAP them to MIDI CCs and edit whatever
  region is playing. This keeps editing params-first (§modern.md), even though
  the regions themselves are dynamic.

## 4. UI (lib/ui/*)

Four screens, shown as four dots at the top (· ● · ·). **E1 is zoom; K1+E1
changes screen** (decided). **Popups** are layers about
112×52 px with a 1 px bright frame and a dimmed screen behind them.

### 4.1 Tape view (derived from 4TRK `menu/multitape.lua`)
- The playhead stays fixed at the centre and the tape scrolls (4TRK model).
  Header: tape name · state (PLAY / FF ×16 / JOG / FOCUS…) · time.
  The time can show **file offset or wall-clock time** from the BWF `bext`
  origination stamp ("14:32:07, 3 Aug 2025"), which matters for fieldwork.
- Ruler with ticks. ZOOMS goes from 1/128 s/px to whole-tape.
- Waveform: mirrored min/max columns. **Brightness → level** (bright
  sound draws brighter), so voices, wind and silence look different at a
  glance.
- **Regions are drawn inverted**: a bright band with the waveform cut out of
  it in black, so it reads as a negative. A region with sound settings gets a
  dither/hatching pattern on its band edge, and a send-as-insert region gets
  a dotted outline. **Marks** are a 1 px line with a small flag at the top; a
  mark or region with a note gets a filled flag.
- **Layout: a zoomed view above, the whole tape below.** The top ~44 px is
  the zoomable tape around the fixed playhead. Under it is a thin strip
  (about 8 px) with the whole file. On the strip:
  - a bright bracket for the part shown above, which also shows the zoom
    level;
  - region bands as inverted segments;
  - mark flags as single dots.

  K1+E2 can move the bracket and jump there, like a scrollbar.
- Optional "reading" mode fully zoomed out: the tape folded into 4–6 rows,
  like lines of text.
- **Focus effect:** while a seek is loading, the waveform near the playhead
  is drawn dithered or blurred (every other pixel). It sharpens as chunks
  arrive.

### 4.2 Collection view ("the archive shelf")
A list of tapes, with duration, number of notes, last position and a small
overview strip for each. A virtual tape can be made of **several files
joined** (§6.1).

✅ Built (2026-11-20, `lib/ui/collection.lua`, `lib/ui/tape_popup.lua`,
`lib/collection.lua`, `lib/shelf.lua`):
- **The index** `dust/data/aurotate/collection.lua`: one entry per tape ever
  opened (path, title, dur, opened, marks/regions counts, last_pos, size,
  analysis cache dir, parts, origin). A summary, updated when a tape opens
  (`Tape.on_opened` → `Annot.opened`) and when it is left (`Annot.leave`);
  the tape documents stay the truth. The first run builds it from the
  documents in `tapes/`.
- **Page:** 5 rows (tom-thumb): a bar for the open tape, ≡ for a reel, title
  (`? ` and dim when missing), a dot when it has notes, length. The last row
  is `+ add a tape` (fileselect). Below a rule: the selected tape's overview
  (rms of the coarsest peaks level, read from the cache's peaks file: only
  that level, a few KB; `Collection.strip`) with a level-15 tick at the last
  position (the playhead for the open tape), and a line: notes, date and
  start time. Details are looked up when shown and cached 10 s. E2 select,
  E3 sort (recent / name / length), K2 play/stop, K3 open and go to the
  tape page, K1+K3 tape popup. USB keyboard: Up/Down/PgUp/PgDn/Home/End,
  Enter open, Esc play/stop.
- **Tape popup:** file, length, *start* (E3 ±1 min, K1+E3 ±1 h, K3
  textentry with a check; empty = back to bext; first guess = file mtime −
  length; title says FROM FILE / BY HAND), *join* (single files: E3 how
  many of the next files, `ok` when bext confirms all; title shows the last
  file joined; K3 twice), *relink* (missing tapes: K3 search, E3 pick, K3
  twice), *forget* (K3 twice). A changed start is written when the popup
  closes or the row changes (the open tape: `Annot.set_origin`, debounced
  by the store; another tape: `Store.peek` / `Store.put`).

### 4.3 Regions/annotations list
- A list of marks and regions sorted by time. Each shows a timecode, its
  label, a ♪ if it has sound settings and a MIDI note if mapped. K3 jumps the
  tape there. K1+K3 opens the **reader popup**: the full note, word-wrapped
  and scrollable with E2/E3, plus tags. Read it while the region plays on
  loop.
- Filter by tag.
- ✅ Built (2026-11-20, `lib/ui/regions.lua`): 7 rows in tom-thumb, region =
  square, mark = tick, indented 3 px per enclosing region (max 4), a dot at
  the right when there is a note; the row shows the label, else the note's
  first line, else the id. The selection follows the playhead (last item
  started before it, or "here") until E2 turns; K3 / re-entering the page
  follows again. E3 cycles all → each tag. K1+K2 loops the selected region
  (`Annot.loop_item`; again: off). The reader is a popup kind (`reader`):
  label, tags, note; E2 line, E3 page, K3 the item popup (K2 comes back),
  K1+K2 loop. Popups close on a page change. No ♪ / MIDI columns yet
  (phases 6–7).

### 4.4 Settings
Budgets, cue/lifter character, transcription rewind, display (offset or
wall-clock), MIDI channel and mapping mode, and export.

### 4.5 Controls (tape view; built in phase 4)
| | |
|---|---|
| E1 | zoom (K1+E1: change screen) |
| E2 | jog with inertia (MultiTape model) |
| E3 | shuttle: −64…+64, centre detent at 0 and 1× |
| K2 | play / stop (with auto-rewind if transcription mode is on) |
| K3 tap | drop a mark |
| K3 hold, then K3 again | region in, then region out (a selection grows while you hold the first press) |
| K1+K3 | open the popup for the mark or region under the playhead: note, sound, MIDI (cancels a pending region in instead, if there is one) |
| K1+K2 | loop the region under the playhead (again: loop off) |

### 4.6 Text entry
- A **USB keyboard** (`keyboard.char` / `keyboard.code`) is the main way to
  write notes. In the tape view, typing goes to the note of the current
  mark/region. Fixed hotkeys borrow from transcription software: Esc =
  play/pause with auto-rewind, F6/F7 = −5 s / +5 s, F8 = mark, F9 = region
  in/out (F1–F5 belong to the system menu: core takes them before the
  script sees them, so the usual F1–F4 can't be used).
- On-device, without a keyboard: `textentry` for short labels, plus a
  **tag palette** (a user-editable list) for quick coding.
- The notes also round-trip as Markdown (§5), so you can do the long writing
  on a computer.

### 4.7 Speaker masking (for public use)
**An insert for listening and tuning, a render on disk for anything public.**
- A live insert *fails open*: a bypass, a fx rack change, a script switch
  or a crash plays the real voice. A public tape must not depend on
  something staying switched on.
- **Masking regions** have a type in the model (`mask = { method, params }`).
  The same SynthDef runs live as the per-voice insert, for audition, and in
  an offline render, so what you hear is what gets written.
- **"Make public copy"** renders a new working tape:
  - masked regions processed;
  - **redaction regions** (names, places) replaced with tone, noise or
    silence;
  - the notes copied, minus notes marked private.

  The public tape document records only its own audio, never the path of
  the source. With "public mode" on, the collection shows only public
  tapes.
- **Method:**
  - Don't use pitch shift alone: shifting back undoes it.
  - Use McAdams-coefficient formant warping (the VoicePrivacy challenge
    baseline) together with pitch shift and parameters randomised per
    region, or vocoder resynthesis for strong masking.
  - The UI should say plainly that masking the voice ≠ anonymising the
    recording. Content, accents and background still identify people,
    hence the redaction regions.
- **Render speed:** offline on the Pi 3 should be several × realtime for
  a few masked regions. Only regions are rendered; the rest is copied.
  To be measured.

## 5. Export / import (lib/export.lua)
Write to `_path.data/aurotate/exports/<tape>/`:
- `notes.md` ✅ (2026-11-20): one section per mark/region, with timecode
  (offset; the time of day too when the start is known, ✅ phase 8), label, tags and note. Phase 5b: **re-import** edits to the
  notes from this file, matched by id comment `<!-- aur:r12 -->`. Format, as
  built:
  ```
  ## 0:01:40–0:06:40 · arrival story        heading: start(–end) · label
  <!-- aur:r1 -->                            the id; the re-import key
  `r1` · region 0:01:40.000–0:06:40.000 (5:00) · in … (`r0`) · #story
                                             exact times, enclosing region, tags
  note, verbatim (lines starting with # or <!-- get a leading \)
  ```
  Items in tape order (a region before the marks inside it, a longer region
  before a shorter one at the same start). `H:MM:SS` for tapes ≥ 1 h, else
  `M:SS`. Tags as `#tag`, or `#[[two words]]` when not a plain word. The file
  header has the path, length, counts, all tags, export time and
  `<!-- aur:tape <id> -->`. A new export keeps the old one as `.bak`.
- `labels.txt`: Audacity label track (`t0\tt1\tlabel`).
- `notes.vtt`: WebVTT, to subtitle the recording in a video or web player.
- `regions.csv`: for spreadsheets / ELAN-adjacent workflows.
- **Excerpts:** each region as a WAV in `_path.audio/aurotate/excerpts/`,
  with its note as a `.txt` beside it. NRT does this offline.

## 6. Suggested features that fit the "workbench" idea

1. **Split-file reels.** Field recorders split long takes at 2/4 GB (Zoom,
   Sound Devices). A virtual tape that spans the parts as one continuous
   tape. The Feeder maps file frames to (part, offset). This is the most
   practically useful item on the list.
   ✅ Built (phase 8): a `.reel` text file next to the parts (one name per
   line, relative; `#` comments), `lib/reel.lua`. Its path is the tape's
   identity (document, cache, PSET, last tape). Lua sends `reel_clear n`,
   `reel_part s` × n, `open_reel s f f n`; `AurTape` keeps `parts`
   ([path, first frame, frames]) and splits a chunk read at part boundaries
   (`prPieces`: one `b_readChannel` per part, the last carries the valid
   flags; the read completes when every piece is done or failed). All parts
   must share rate and channels (checked in Lua and sclang). The analysis
   gets every part (`analyze.sh <dir> <bin> <file>...`; sox concatenates),
   so peaks and proxies cover the reel; the cache hash includes every
   part's size and mtime. **Join** is offered, never automatic: candidates
   are the files after the chosen one in its folder (by name) with the same
   format, and bext `time_ref` continuity (`t2 = t1 + frames1`, ±2 samples,
   across midnight) marks the ones that really continue it. Joining writes
   `<first>.reel`, appends each part's notes at its offset with new ids
   (`Model.append`), takes part 1's position and a hand-set start, and
   replaces the parts' collection entries with the reel. Opening a single
   file that the next one continues shows `PART OF n: JOIN IN COLLECTION`.
2. **Wall-clock time** from BWF `bext` (§4.1); notes export with the real
   time of day.
   ✅ Built (phase 8): `lib/bext.lua` reads the chunk headers (RIFF and
   RF64; fmt, bext, ds64, data), `lib/wallclock.lua` does dates and times
   (pure Lua, across midnight). `doc.tape.origin = { date, secs, source }`.
   bext `time_ref` wins over the origination time when it is set and
   agrees with it within a minute (some recorders run free timecode).
   A bext origin is taken from the file on every open (not saved by itself);
   a manual one wins and is saved. PARAMS > TAPE > *clock* (offset / time of
   day) switches the header, the regions list and the item popup times.
   `notes.md` gives the time of day in each heading and `date time` in the
   metadata line, plus a `recorded:` line (and a reel's parts) in the header.
   No bext in FLAC (yet): set the start by hand.
3. **Transcription mode:** auto-rewind on resume, slowing down without
   changing pitch (granular `Warp1`/`GrainBuf` on the ring buffer),
   keyboard hotkeys.
4. **Activity suggestions.** The analysis file can propose regions
   (non-silent stretches, bright/voiced stretches) as "ghost regions": you
   accept one with K3 or ignore it.
5. **Dérive mode.** The tape wanders by itself between regions with
   a chosen tag. Each jump is *heard as tape travel*: a FF/REW cue sound
   from the proxies, whose speed and length follow the distance between
   regions. A short jump is a quick chirp; a jump across hours is a long
   squeal that slows into the next region. Parameters:
   - choice: random / nearest / by tag / along links (7);
   - dwell time;
   - "lifter" amount.

   The archive plays itself as an installation, and you can hear where on
   the tape it is.
6. **Wear.** Parts of the tape you listen to often look slightly worn: noise
   pixels in the waveform. A listening history kept as a trace on the tape,
   which suits the anthropological framing.
7. **Region links.** "See also" between regions; the reader popup can jump
   along the links.
8. Tape **spin-up / spin-down** wow on start/stop, with a depth param.

### 6.9 Downloads: by URL and from Freesound (phase 9; planned 2026-11-20)
Bring recordings onto the device without a computer: an http(s) URL, or a
Freesound sound id. Every downloaded tape keeps where it came from and who
made it, so it can be credited.

**Getting a request onto the device.** Typing a URL with `textentry` is
painful, so three ways in:
- the collection's last row *+ add a tape* gets a choice: file browser /
  URL / Freesound id (textentry; a USB keyboard makes it easy; a Freesound
  id is just digits);
- a queue file `dust/data/aurotate/downloads.txt` (written over SMB or in
  maiden): one request per line, `https://…` or `freesound:12345`; the
  collection page offers to fetch what is in it;
- the REPL: `download('https://…')`, `download('freesound:12345')`.

**Plain http(s).** A detached job (like the analysis, §2.3) runs `curl -L
--fail` with a size cap and a timeout into `dust/audio/aurotate/downloads/`,
then converts what isn't WAV/FLAC (see *formats*). Only `http://` and
`https://`. The name comes from `Content-Disposition` or the URL path,
sanitised, never overwriting (`-2`, `-3`). Free space is checked first
(`df`) against `Content-Length` when given. Progress from curl's `-#` /
`NN%` output, shown in the collection row. Metadata kept: the URL, the
final URL after redirects, `Content-Type`, `Last-Modified`, the download
time. Author and license are unknown for a plain URL: the tape popup gets
*author* and *license* rows to fill in by hand.

**Freesound.** API v2 (https://freesound.org/docs/api/). Yes, it needs a
registration, done once by the user with their own Freesound account:
1. Apply at https://freesound.org/apiv2/apply (logged in). The page gives
   a **client id** and a **client secret / API key**. These are the user's;
   aurotate ships none. The user puts them in
   `dust/data/aurotate/freesound.lua` (`{ api_key = '…', client_id = '…' }`)
   over SMB / maiden, or types them in a settings popup.
2. **API key only** (token auth: `Authorization: Token <key>`) gives the
   sound's metadata (`GET /apiv2/sounds/<id>/`) and its **previews**:
   `preview-hq-ogg` (~192 kbps) and `preview-hq-mp3` (~128 kbps). Lossy,
   but enough to listen and annotate. Prefer the ogg (sox and libsndfile
   read Vorbis on the device; this sox has no mp3).
3. **The original file** (`GET /apiv2/sounds/<id>/download/`) needs
   **OAuth2** (authorization code grant, PKCE `S256`, which is required for
   apps registered from November 2026 on). On a norns there is no browser,
   so:
   - aurotate makes `state`, `code_verifier` (32 random bytes, base64url)
     and `code_challenge = base64url(sha256(verifier))` (`openssl dgst
     -sha256 -binary | base64`; Lua has no sha256), and writes the authorize
     URL (`https://freesound.org/apiv2/oauth2/authorize/?client_id=…&
     response_type=code&code_challenge=…&code_challenge_method=S256&state=…`)
     to `dust/data/aurotate/freesound_login.txt` and prints it in maiden;
   - the user opens it on a computer or phone and allows access. The app
     is registered with Freesound itself as the redirect target, so the
     page shows the **code** to copy;
   - the user types the code within **10 minutes** (USB keyboard /
     textentry, or into a file). aurotate POSTs to
     `https://freesound.org/apiv2/oauth2/access_token/` (`client_id`,
     `grant_type=authorization_code`, `code`, `code_verifier`,
     `redirect_uri`) and stores `access_token` (valid 24 h), its expiry and
     `refresh_token` in `freesound.lua` (mode 600; never in PSETs, never
     printed). Before a download it refreshes when expired
     (`grant_type=refresh_token`); every refresh returns a **new** refresh
     token, which must be saved at once. A 401 "Invalid token" (access
     revoked) clears the tokens and asks for a new login.
   - Without a login, a Freesound request falls back to the hq preview and
     says so (`PREVIEW` in the tape's source).
4. Limits: per user, readable from `GET /apiv2/usage/` (not throttled). A
   few requests per sound (metadata, maybe a refresh, the file) is far below
   them; a queue runs one download at a time.

**Attribution metadata** goes into the tape document (truth, travels with
the notes) and into a sidecar next to the audio file (travels with the
file):

```
doc.tape.source = {
  kind = 'freesound' | 'url',
  url,                    -- what was asked for
  final_url, content_type, last_modified,       -- url
  freesound = { id, name, username, url (the sound's page), license
                (e.g. "Attribution 4.0"), description, tags, created,
                pack, geotag, original = { type, samplerate, channels,
                duration, filesize, md5 }, gen_ai_preference,
                file = 'original' | 'preview-hq-ogg' | … },
  author, license, title, -- for crediting; from Freesound or typed by hand
  downloaded,             -- os.time()
}
```

- The sidecar `<file>.source.txt` (plain text, also the credit line):
  `"<name>" by <username> (https://freesound.org/s/<id>/), <license>`, then
  the fields above, one per line.
- `Model.validate` keeps `source` (cleaned like `origin`), and the
  collection index carries `author` / `license` for the list.
- The tape popup gets a *source* row (author · license; K3 shows the whole
  credit in the reader); *author* / *license* editable for plain URLs.
- `notes.md` header: `- source:` with the credit line and the license, so
  an export can be used as is. Later, a `credits.md` over the whole
  collection (every tape with a source).
- A Freesound `created` date is *not* the recording's start; the wall clock
  (§6.2) stays unset unless the file has bext.
- Non-commercial licenses (`Attribution NonCommercial`) are shown as such in
  the popup and the export.

**Formats.** Freesound originals can be wav, aif(f), flac, ogg, mp3 or m4a,
44.1 kHz or other rates, URLs anything. A download that isn't WAV/FLAC is
converted to FLAC (the working format, §2.3b; 48 kHz so the engine doesn't
resample). sox does wav/aif/flac/ogg on the device; mp3 and m4a/aac need
**ffmpeg**. WAV/FLAC at other rates are played as they are (the engine
handles the rate) unless the import step converts them.

**Dependencies via norns-deps** (`../norns-deps`: copy `lib/deps.lua` and
`lib/deps/` into `lib/`; `deps.new { name = 'aurotate', dir =
norns.state.data .. 'deps' }`). Checked when a download is first asked
for, never at init; `d:ensure` opens its installer screen only if something
is missing:
- `curl` (check `curl`, pkg `curl`): http(s) and the API;
- `openssl` (check `openssl`): PKCE's sha256 (only for the Freesound login);
- `ffmpeg` (check `ffmpeg`, pkg `ffmpeg`, optional, size ~20 MB with its
  libraries): mp3 / m4a. Without it such a download stops with "needs
  ffmpeg" and the installer offers it;
- JSON: no package. Vendor a small pure-Lua decoder (e.g. rxi/json.lua,
  MIT) as `lib/json.lua`; norns core has none, and jq isn't on the image.

Measured on the shield (2026-11-20): curl, wget, openssl and ffmpeg are
installed (ffmpeg probably by hand; not assumed on a stock image); sox has
no mp3 format; no jq.

**Built as** `lib/download.lua` (job runner: curl into a temp file,
progress, cancel, convert, move into place, sidecar), `lib/freesound.lua`
(API calls, OAuth2 + PKCE, token store, metadata → `source`),
`lib/json.lua` (vendored), `lib/deps.lua` + `lib/deps/` (vendored
norns-deps), UI in the collection (add-row choice, a row per running
download with progress, a *source* row in the tape popup, a Freesound
settings popup: key / client id present, login state, log in / log out).

**Tests:** off the device: JSON fixtures of a sound instance → `source`,
the credit line, file names, the PKCE challenge against RFC 7636's test
vector (appendix B), the token store's expiry logic, `validate` of
`source`. On the device: a URL download (a WAV and an mp3), a Freesound id
with only an API key (preview), the login and an original download, a
refresh after expiry (set `expires` in the past), a revoked token, a
cancelled download leaving no partial file, and the analysis of the result.

**Settled before building** (2026-11-20):
- Ids only, no search on the device (yet).
- Packs: later; when they come, one tape per sound.
- Folders: Freesound downloads go to `dust/audio/aurotate/freesound/`,
  plain URLs to `dust/audio/aurotate/` itself.
- A Freesound tape's description (and its tags, as text) becomes a first
  note: a mark at 0:00 labelled with the sound's name.

✅ **Built (phase 9, 2026-11-20)** as planned, with these differences:
- **No openssl:** SHA-256 and base64url are pure Lua (`lib/pkce.lua`, checked
  against RFC 7636 appendix B and the FIPS vectors), so the login needs only
  curl.
- **No HEAD / Content-Length check:** one GET with `--max-filesize` = the
  smaller of 4 GB and the free space (`df`) minus 200 MB.
- The type comes from the file's first bytes (`Source.sniff`), not the
  server's `Content-Type`; an HTML or JSON error page is refused. HTTP
  status from curl's write-out (`--fail` would drop the headers).
- Secrets never go on a command line: each authorised request is a curl
  config file (`-K`, mode 600) in a mode 700 temp folder, deleted after.
- The token request also sends `client_secret` (the API key); `redirect_uri`
  only when `freesound.lua` sets one (otherwise Freesound uses the
  registered one). `freesound.lua` may set `base` (the mock server in tests).
- Freesound names with an audio extension lose it in the tape title
  (`wind.wav` → `wind`); the credit keeps the name as it is.
- The popup's *source* row shows the author (and `(preview)`); the license,
  short (`CC BY-NC 4.0`), is in the popup title. The tape font has no `·`.

## 7. Phases

| # | deliverable | done when |
|---|---|---|
| 0 | ✅ **Feasibility spike** (2026-11-19, Pi 3 only; see §1) | done. Still open: Pi 4 run, CPU numbers (§9.3) |
| 1 | ✅ **Transport** (2026-11-19, Pi 3; see §9.1): tape voice, jog with inertia (port MultiTape `jog_turn`), shuttle, loop, position poll, params; `spike_test` kept as `test/transport.lua` | done: a 3 h WAV and a 1 h 56 min FLAC field recording play, scrub, loop and park without dropouts; CPU baseline in §9.3; hands-on test on the device: works well. Open: sporadic xruns (§9.1) |
| 2 | ✅ **Analysis + cache** (2026-11-19, Pi 3; see §9.1): `aurpeaks` + sox in one pass, P1/P2, reduced levels; proxy crossfade, lifter cue, focus on far seeks, shuttle to ±256× | done: CPU at 8–256× recorded (§9.3), far seeks covered by the proxy, analysis during playback without xruns; hands-on on the device: "great" (user, 2026-11-19) |
| 3 | ✅ **Tape view UI** (2026-11-19, Pi 3; see §9.1): zoomed view + whole-tape strip, ruler, zoom, waveform from the raw peaks string, page dots, growing waveform during analysis, focus dither | done: reads well at every zoom (screenshots, `field_L`), redraw 5.5 ms avg at 1×, 8.5 ms at FF 64× (15 fps, no drawing in polls), Lua heap 3.9 MB after GC; hands-on on the device: "works great" (user, 2026-11-20) |
| 4 | ✅ **Marks, regions, notes** (2026-11-20, Pi 3; see §9.1): model + tape document store, K3 tap/hold gestures, region bands and mark flags, item popup and note editor, USB keyboard notes and hotkeys | done: annotations survive a script reload, a reboot and PSET switches between two tapes (each with its own notes and position); off-device and on-device store tests pass. Hands-on on the device still to do |
| 5 | ✅ Regions list + reader popup (2026-11-20); exports: ✅ md, Audacity / VTT / CSV still to do; excerpts still to do | export opens correctly in Audacity and a VTT player |
| 6 | ✅ **Per-region sound** (2026-11-20, Pi 3; see §9.1): output stage, fx v2 sends, send-as-insert, boundary glides, current-region params | done: `sound_test()` levels exact (−12 dB, mute, hard pan, nested +6 dB) and no clicks at boundaries, loop wraps or jumps; sends fall back to a private bus without fx. Hands-on (by ear, an effect in a send) still to do |
| 7 | Region voices + MIDI triggers (note→region mapping and learn, choke groups, one-shot/gate/loop modes). *Deferred (2026-11-20); plan in §2.4* | 4-voice polyphony from MIDI with instant attack |
| 8 | ✅ **Collection view, split-file reels, wall-clock time** (2026-11-20, Pi 3; see §9.1) | done: a sine split into 3 WAV parts plays across every boundary without a phase jump (forward, reverse, 2×, seek next to it, loop over it); a stereo FLAC reel passes the transport test; join, relink and the start time work from the UI; export has the time of day. Hands-on still to do |
| 9 | ✅ **Downloads by URL and from Freesound** (§6.9; 2026-11-20, Pi 3, against a mock Freesound; see §9.1) | a WAV and an mp3 by URL, a Freesound id as preview (API key) and as original (OAuth2 login) become tapes with their source; credit line in the popup and in notes.md |
| 10 | Grid; aurotate's own effects (voice transformation) in the per-voice insert slot | — |

Suggested layout:
```
aurotate.lua                 -- init, params, callbacks, screen routing
Engine_Aurotate.sc
lib/sc/AurFeeder.sc  AurVoice.sc  AurAnalysis.sc
lib/tape.lua                 -- engine glue, transport, poll handling
lib/analysis.lua  lib/cache.lua
lib/model.lua  lib/store.lua  lib/export.lua
lib/midi_map.lua  lib/keys.lua (norns keys/encoders + USB keyboard)
lib/ui/draw.lua  tape_view.lua  overview.lua  collection.lua
lib/ui/regions.lua  settings.lua  popup.lua
```

## 8. Decisions
- Engine vs. core: the SC engine passed phase 0 on a Pi 3; no core changes.
- File formats: FLAC working copies, imported (§2.3b).
- Pi 3: supported with a 64 s ring + P2 proxy; P1 only for files up to ~1 h.
- Proxies mono everywhere; proxy memory is a param (Pi 3 128 MB, else 600 MB),
  P2 first, then P1 if both fit.
- Lifter = head contact at speed: above 2× (fully at 4×) the sound is lowpassed
  (800 Hz…16 kHz), highpassed (40…440 Hz), driven and attenuated by the lifter
  amount; 100 % is silent winding.
- E1 = zoom, K1+E1 = screen.
- Overlapping regions mix (§3); masking fails closed.
- Speaker masking: insert for audition, render to disk for public copies (§4.7).
- Startup resumes the tape that was open last, where it was left, whatever
  tape the startup PSET names; loading a PSET during a session switches tapes.
- A tape's document is `<name>-<fnv(path)>`: same-named files in different
  folders don't share notes, and editing the audio (mtime, size) doesn't lose
  them. Moving the file does (phase 8 can relink by name + size).
- USB keyboard hotkeys are F6–F9 (core owns F1–F5).
- Reels are `.reel` text files **next to the parts** in `dust/audio`, not in
  the data dir: they move with the folder, can be written or fixed by hand
  over SMB, and fileselect / the `aur_file` param open them like any tape.
- Joining split files is always the user's choice (the collection's tape
  popup); bext continuity only marks candidates `ok`. Name patterns alone
  can't tell a split take from the next take (Zoom `ZOOM0001` / `ZOOM0002`).
- The parts' own documents and analysis caches are kept after a join
  (nothing is deleted); the reel gets copies of their notes.
- The collection lists tapes that were opened (an index), not everything
  under `dust/audio`.
- A tape's start (the wall clock) comes from bext unless set by hand; a
  hand-set one wins and survives reopening.

## 9. Development notes (read this first in a new session)

### 9.1 State of the code (phases 1–9)
| file | status |
|---|---|
| `lib/model.lua` | Phase 4. The document (§3, without `snd`/`midi` yet): `marks` sorted by `t`, `regions` by `t0`, ids `m<n>`/`r<n>` from one `next_id`, times rounded to 1 ms. Queries: `innermost`, `regions_at` (outermost first, for §3's mixing), `mark_near`, `at` (a mark within tolerance wins over the region it sits in). Every change goes through it and calls `Model.changed`. `validate` runs migrations (`Model.migrations[v]`, none yet), drops malformed items and counts them, keeps `next_id` above every id. Pure Lua, no norns calls |
| `lib/store.lua` | Phase 4. `dust/data/aurotate/tapes/<name>-<fnv(path)>.lua`, plain Lua loaded with an empty env. Debounced saves (2 s after the last edit, from the UI metro), atomic (`.tmp`, old file → `.bak`, rename). A corrupt file is renamed `.corrupt-<date>` and the `.bak` loaded; a file from a newer version makes the store read-only. No file until a tape gets its first note. `last_tape` (startup resume), `tags.lua` (the tag palette, written with defaults on first use, user-editable) |
| `lib/annot.lua` | Phase 4. Glue: opens/closes the document with the tape (`Tape.on_open`, saving the old tape's position), K3 tap/hold (hold 0.4 s), pending region in (`Tape.st.pending_in`), "here" (mark within max(3 px, 0.25 s), else innermost region), K1+K2 loop, parks the position every 5 s while stopped. Owns the shared Model/Store instances (`include` runs a file anew each time, so other modules get them from here) |
| `lib/ui/popup.lua` | Phase 4. Item popup (label, note, tags, in/out or time, delete with confirm; E2 row, E3 value: tags cycle the palette, times nudge 0.1 s / 1 s with K1 and audition the edge 0.3 s after the last tick) and note editor (word wrap, cursor, UTF-8 aware, arrows/Home/End, blink). Background dimmed with `blend_mode('multiply')`. Labels go through `textentry`. User text is drawn in tom-thumb (face 25, 6 px): the norns font has no ä/ö/å |
| `lib/keys.lua` | Phase 4. USB keyboard: typing on the tape page writes the note of the item here (a new mark when there is none); Esc play/stop with `aur_rewind`, F6/F7 ∓5 s, F8 mark, F9 region in/out, Enter closes (Shift+Enter newline) |
| `lib/ui/tape_view.lua` | Phase 4: region bands (levels 8/11/13 by overlap depth, 3 for the growing selection) with the waveform and baseline cut out in level 0; on the strip as segments (5/7/9) with the rms columns cut out. Marks: 1 px line (level 7, 12 when here), cut-out notches at the band edges when inside a region; flags at y 15–17 (filled = has a note; regions get one at `t0`); dots on the strip at y 54. All of it per column, not per item, and batched by level (`Draw.add`/`Draw.flush`): a screen call per mark cost ~30 µs, 400 marks were 12 ms. Header shows the label of the item here. `V.redraw` no longer calls `screen.update` (the popup goes over it). Phase 3 tape view: header, ruler, loop bar, waveform (peak columns dim, rms core bright; level from per-tape stretched brightness × loudness), playhead, whole-tape strip (rms heights, levels ≤ 11 so 15 means playhead/bracket) with the view bracket. Columns sit on a fixed grid (k·spp) so they don't shimmer while scrolling; recomputed only when the grid moves. Zooms 1/128…300 s/px while narrower than the tape, then "whole" (the playhead travels). Focus dither within 28 px × proxy share. Header messages (`View.message`) e.g. the zoom span |
| `lib/ui/draw.lua` | Header with page dots (name optionally in tom-thumb); `Draw.columns` fills one level at a time (levels 0–15, 0 cuts out); `Draw.runs` (runs of equal levels → one rect each); `Draw.add`/`Draw.flush` (rects batched per level); dotted lines |
| `lib/sc/AurTape.sc` | The ring + feeder + transport + proxies (P1/P2 PlayBufs synced to the file position, focus crossfade, lifter cue). One instance per voice (`id`; OSC handlers filter on node id + reply id). Next: output stage (phase 6) |
| `Engine_Aurotate.sc` | Phase 6: a group per voice (tape at its head writing to a voice bus, AurOut at its tail); `snd_clear i`, `snd_seg ffffffff`, `snd_commit i`, `snd_glide f`; poll `aur_fx` (bit 1/2: send a/b bus found). Commands: `open sff` (path, start s, ring s), `ring f`, `rate ff`, `jog_nudge f`, `jog_stop f`, `jump f`, `loop iff`, `amp f`, `fade f`, `proxy iss` (level, tape path, proxy path or ""), `lifter f`, `focus f`, `phase s`. Polls: `aur_pos`, `aur_rate`, `aur_ok`, `aur_misses`, `aur_dur`, `aur_proxies` (bitmask), `aur_proxy_share`. **Never name a command `load`** (collides with `engine.load`) |
| `lib/tape.lua` | Engine glue, transport (play/stop, shuttle steps with detents at 0 and 1×, ±128/256 only with P2, jog ported from `audio.multitape.jog_turn`, `Tape.loop(a, b)` for K1+K2, `toggle_rewind` for Esc), `Tape.on_open` hook (returns the start position from the document), `Tape.hold_open` (startup), proxy budget → `engine.proxy`, params group TAPE (22, now with `aur_rewind`), polls (set `dirty` only when a value changes, so a stopped tape doesn't redraw), reloads `peaks.tmp` every 3 s during the analysis |
| `lib/analysis.lua` | Cache dir (`<name>-<fnv(path, size, mtime)>`), detached job, 1 s watcher for `done` / `fail` / `progress`, kill on stop |
| `lib/peaks.lua` | `AURPK2` reader (one string, `string.byte`), `columns(p, t0, t1, w, amp, rms, bright)` picks the coarsest level with ≥ 1 bin per column and reuses the given arrays; reads ≤ 24 bins per column (strided: only matters for level 0 during analysis). Per-tape stats on load: `peak`, `rpeak`, `blo`/`bhi` (5th/95th percentile of rms-weighted brightness); `height`, `rms_height` (normalised, ^0.6), `bright` (stretched). `secs` = seconds covered |
| `aurotate.lua` | Pages (collection · **tape** · regions · settings; only tape is built), routing of keys/encs (to the popup when one is open), 15 fps metro gated by `Tape.dirty` (also runs `Annot.tick`: K3 hold, parking, debounced saves), K3 with no tape opens `fileselect`. Startup: `params:default()` with `Tape.hold_open`, then the last tape. `params.action_write` flushes the document. Phase 4 globals: `notes_test()`, `dbg.Annot`, `dbg.Popup`, `dbg.Keys`; `dbg_status()` prints a NOTES line. REPL globals: `dbg_status()` (now with redraw ms and heap), `dbg_reset()`, `dbg_shot(name)` (→ `dust/data/aurotate/<name>.png`, 640×384: the 128×64 screen ×4 at offset 64,64), `dbg.Tape`, `dbg.View`, `transport_test`, `clicks_test` |
| `lib/export.lua` | Phase 5 (md only so far). `Export.markdown(doc, {now, id})` → string, `Export.write(doc, data_dir, id, Store.write_file)` → path. `escape_note`/`unescape_note` for the 5b round trip, `tc`, `hashtag`, `items` (merged order). Pure Lua apart from the mkdir. Triggered by `Annot.export()`: PARAMS > TAPE > `aur_export` (via `Tape.on_export`; group is 23 now) or `export_notes()` in the REPL; header message `EXPORTED NOTES.MD` |
| `lib/ui/regions.lua` | Phase 5: the regions page (§4.3). The list is `Export.items` filtered by tag, with depths from `Export.parent`, rebuilt only when `Annot.rev` (bumped by `Model.changed` and on tape switch) or the filter changes. Redraw 2.1 ms avg at 1× while following (shield). `dbg_page('regions')` in the REPL |
| `lib/sound.lua` | Phase 6. Pure: the `snd` fields (`FIELDS`, `DEFAULT`, `MIN`, `MAX`, `STEP`), `get`, `combine` (§3 rules), `segments(doc)`, `insert_send` (dry 0 + a send at 1), `format` for the UI |
| `lib/region_sound.lua` | Phase 6. Engine glue: `RS.push` sends the segments when they differ from what the engine has (typing a note doesn't resend); `RS.tick` (UI metro) keeps PARAMS > SOUND > *region here* (`aur_cur_*`, not saved in PSETs) mirroring `Model.innermost` at the playhead, and their actions edit it. `send_ok(which)` (engine found the bus, and the fx v2 core, if loaded, has an effect in that send), `warning(r)` (`SILENT`, `GAIN OFF`). Group SOUND (9): `aur_snd` on/off, `aur_snd_glide` |
| `lib/sc/AurOut.sc` | Phase 6. The output stage (§2.4 as built), segments and re-centring (§3 as built), fx bus lookup |
| `test/sound.lua`, `tools/sound_check.py` | Phase 6. `sound_test()` records a sine (sine440.wav) through five test regions (removed afterwards), a loop over a boundary, jumps and FF 8×, with reverb and monitor off for the run; the script checks levels per region and lists second-difference spikes |
| `test/model_test.lua` | Phase 6: + sound (76 checks in all). Phase 5: + export (61 checks in all). Phase 4: model + store (44 checks: ordering, queries, edge clamps, round trip incl. quotes/newlines/UTF-8, `.bak`, corrupt → `.bak`, newer → read-only and untouched, malformed items dropped, no file for an empty tape, palette, ids). `lua5.3 test/model_test.lua` off the device, `notes_test()` on it |
| `test/transport.lua` | Phase 1 sections (idle, 1×, seeks, FF 2–64×, REW, scrub, loops, parking) plus `analysis` (drops the cache, plays 1× through a fresh analysis) and `cue` (FF/REW 8–256×, far seeks with focus); option `proxy_mb`. Not in the default run. Lines now include `mem_avail_mb`, `covers`, `proxy_max`, `p1`, `p2` (proxy state at the end of the phase) |
| `tools/aurpeaks.c`, `tools/analyze.sh` | The analysis pass (§2.3). Phase 8: `analyze.sh <cache dir> <aurpeaks> <file>...` (a reel's parts, concatenated by sox) |
| `lib/bext.lua`, `lib/wallclock.lua` | Phase 8. BWF bext reader (RIFF/RF64 headers only) and `Bext.origin`; dates/times from an origin (`parse`, `clean`, `shift`, `at`, `time`, `stamp`, `date_label`). Pure |
| `lib/reel.lua` | Phase 8. `.reel` files: `parse`, `text`, `load(path, info)` (parts with start frames, format check), `continues` (bext time_ref), `candidates(path, list, info, bext)`, `new_path`. Pure (file info and listings passed in) |
| `lib/collection.lua` | Phase 8. The index (`collection.lua` in the data dir): `load` (bootstraps from `Store.all_docs`), `update`, `from_doc`, `rename`, `remove`, `sorted`, debounced `tick`/`flush`; `strip(peaks, n)` reads only the coarsest peaks level |
| `lib/shelf.lua` | Phase 8. Glue for the collection: `missing`, `candidates`, `join` (writes the reel, carries notes with `Model.append`, swaps the index entries, reopens if a part was open), `find_moved` (`find` under dust/audio by name + size), `relink` (`Store.move` + renames the analysis cache), `forget`, `split_hint` |
| `lib/ui/collection.lua`, `lib/ui/tape_popup.lua` | Phase 8. The collection page and its tape popup (§4.2). The popup reuses `Popup.frame_box/title/GEOM` |
| `lib/download.lua` | Phase 9. The queue (one job at a time in a clock coroutine), shell steps as detached jobs through norns-deps' runner (polled every 0.25 s, curl's `-#` percent as progress, cancel kills the process group), `fetch` (curl into a hidden temp folder next to the destination), `finish` (sniff, sox/ffmpeg to FLAC 48 k, unique name, sidecar, tape document with `source` + first note, collection entry), the Freesound flow (metadata → refresh if expired → original, or the hq-ogg preview without a login or after a 401), `downloads.txt`, the login exchange. Loads norns-deps lazily (`D.deps()`); curl/ffmpeg are checked when needed |
| `lib/freesound.lua` | Phase 9. `freesound.lua` (mode 600) load/save, state (`no key` / `key only` / `waiting for code` / `logged in`), the authorize link + `freesound_login.txt`, request builders → curl config text, `take_token` (expiry − 60 s, rotated refresh token saved at once), `clean_code` (accepts a pasted redirect URL). No network |
| `lib/source.lua`, `lib/json.lua`, `lib/pkce.lua` | Phase 9. Pure: requests (`freesound:n`, digits, sound links, http/https), file names (Content-Disposition incl. `filename*`, URL path, `safe`, `unique`), headers of the last response, `sniff`, licenses (CC URL → name → short), `from_freesound`, credit line, sidecar, first note, `clean` (for `Model.validate`); a JSON decoder (`Json.null`); SHA-256 + base64url + PKCE |
| `lib/deps.lua`, `lib/deps/` | Phase 9. Vendored norns-deps (`7a03590` + the dash `kill` fix below) |
| `lib/ui/add_popup.lua` | Phase 9. The collection's *+ add a tape*: file, url, freesound, queue, login, api key, client id |
| `tools/freesound_mock.py` | Phase 9. A mock of the API v2 parts we use (sound instance, download → redirect, authorize, access_token with PKCE check and refresh rotation, `/revoke`) plus plain files (redirect, Content-Disposition, 404, HTML, a slow file for cancel) |
| `test/reel.lua`, `tools/reel_check.py` | Phase 8. `reel_test()` records the split sine (§9.2) across its part boundaries; the script finds every boundary crossing in the position log and checks the second difference there (a misread jumps the sine's phase) |

**Phase 2 result** (shield, Pi 3B+, 64 s ring, fx rack + mods; `field_L.flac`,
1 h 56 min mono FLAC):

| | P2 only (default 128 MB budget) | P1 + P2 (300 MB) |
|---|---|---|
| analysis, cold, tape playing at 1× | 53 s; 0 xruns, 0 misses; jack CPU 32 % (20 % without) | — |
| cache | p1 83 MB, p2 10 MB, peaks 1.5 MB | |
| proxy load (RAM) | P2 21 MB in 0.2–0.6 s | P1 167 MB in 4.2 s; MemAvailable 377 → 225 MB |
| FF 8 / 16 / 32 / 64× | full res streams (0.8–6.1 MB/s), scsynth 20.3–23.9 % | 8×: streams; ≥ 16×: P1, **0 reads**, 20.3–20.8 % |
| FF 128 / 256×, REW 256× | P2, 0 reads, 21.0–21.8 % | same |
| far seeks ×15 | proxy plays at once (`proxy_max` 1.0), full res after 46 ms avg / 140 ms max; 0 misses | 52 / 159 ms; 0 misses |

The phase 1 run (`transport_test()`, P2 loaded) still passes every check with
0 misses and 0 xruns in all phases. Hands-on (cue, focus, seeks): works well.

Fixed after the hands-on test:
- K1+E2 twice before the next position poll seeked from the stale position
  (+60 +60 = +63 s): `Tape.jump` now sets `st.pos` at once.
- A stray E2 tick just before/after K1 entered scrub, which takes over from
  play and coasts to a stop (it looked like "two seeks stop the tape"). E2
  ticks within 0.4 s of a K1+E2 seek (or of releasing K1 after one) are now
  ignored. Phase 3 redoes the controls (E1 zoom, K1+E1 screen); keep the grace.
- A `rate` command that arrived while a file was still opening was lost
  (phase 1 bug): `open` resets the rate when the command arrives, `load`
  applies whatever rate is current.

**Open after phase 2:**
- **By ear, in detail** (the overall feel is approved): P1 vs P2 cue, lifter
  0/50/100 %, aliasing from P2 above 64× (a P3 ÷512 would fix it).
- **Base load rose ~4.5 %:** idle scsynth is 20.6 % (phase 1: 15.0–15.9 %).
  Likely the always-running proxy PlayBufs, LPFs and the stereo cue chain;
  not isolated. If it matters, gate the cue chain (or the proxies) with
  `Pause`-style sub-synths, or measure with the fx rack off first.
- Proxies come in only when the analysis ends; the peaks file grows during it
  but nothing draws it yet (phase 3).
- In the test report, `p1`/`p2` show the proxy state when a phase *ends*
  (e.g. `analysing_play1x` shows p2=1, but `proxy_max=0.0` there is right).

**Transport design (all in the synth, sample-accurate):**
- Rate: `Lag` glide (spin up/down, param). Jog: `Integrator` with friction
  `exp(-blockdur / stopTime)`; nudges arrive as a **running total** that the
  synth differentiates, so several nudges in one control block add up (a
  `t_` trigger keeps only the last). Entering jog seeds the integrator with the
  current speed, so the tape coasts out of play. Leaving jog glides from the jog
  speed (`Lag` time is 0 while jogging).
- Jumps: `EnvGen [1, 0, 0, 1]` (fade, 4-block hold, fade) with the jump
  trigger (`TDelay`) in the middle of the hold. The engine reports the gain
  at every jump/wrap (`jump_gain` in the report; 0.0 throughout).
- Loops: entered only by **crossing** an edge in the direction of travel
  (`LocalIn` feedback of the previous two block positions), so a seek past the
  loop escapes it. Fade out by position before the seam, stay silent in an
  overshoot window, `Sweep` fade-in after the wrap.
- Positions given to the server are multiples of 64 frames, exact in float32
  up to 2^30 frames (6.2 h at 48 kHz), so file and ring offsets agree.
- Feeder: chunks along the path of travel, following the loop when inside it;
  a slot claimed by a higher-priority chunk is never evicted for a lower one.
  After a jump it keeps the old chunk until the jump has happened and ignores
  stale position reports. A seek just before a chunk boundary reads both
  chunks in one request (otherwise the next chunk arrives ~15 ms late).
- Ends: the engine parks at the file ends (also while jogging); Lua resets the
  speed param from the position poll.

**Phase 1 result** (shield, Pi 3B+, 64 s ring, fx rack + mods loaded; full
run on `field_L.flac`, speed/loop/edge sections on `test3h.wav`):

| | field_L.flac (1 h 56 min, mono FLAC) | test3h.wav (3 h stereo WAV) |
|---|---|---|
| checks (loops stay inside, escape, parking, scrub→play) | all PASS | all PASS |
| dropouts (misses) | 0 | 0 |
| seek, chunk resident | 8–10 ms (the fade) | — |
| seek, far | avg 43 ms, max 151 ms | — |
| FF 64× disk rate | 6.1 MB/s | 12.0 MB/s |
| hands-on (K2, E2 scrub, E3 shuttle, K3 loops, by ear) | works well (user, 2026-11-19) | |
| clicks (`clicks_test`, 440 Hz sine) | none at seeks, loop seams (fwd/rev/4×), spin up/down; two slope kinks (≤ 6× a clean sine's max d2) at scrub takeover / reversal | |

**Open after phase 1** (status after phase 2 in *italics*):
- **Sporadic xruns:** *none in ~45 phases of the phase 2 runs, including a
  fresh analysis during playback.* 3 in one phase of one run (reverse 10 s loop, no disk
  reads, CPU peak 22 %) and 2 in another run (200 s loop at 16×); 0 in the
  other ~100 phases. Not CPU-bound. Check whether they correlate with
  something outside the engine (matron, SD card, the fx rack) before phase 2
  adds load.
- One far seek in each full run takes ~150 ms (vs 43 ms avg). Probably a read
  in flight for the old position plus a paired read; measure per seek.
- The core 3.x beta prints `clock.lua:62: bad argument #1 to 'resume'` on
  script clear/load (before our `init`); not aurotate's.
- `_norns.restart()` once wedged the whole stack (sclang stuck in "server
  already booting", matron stuck at "setting up jack clients"). Recovery:
  `sudo systemctl restart norns-jack`, then `norns-main norns-sclang`.

**Phase 3 result** (shield, Pi 3B+, `field_L.flac`, P2 loaded; times are
Lua-side `redraw()`, which includes the screen calls):

| | redraw avg / max | fps |
|---|---|---|
| 1×, 1/16 s/px (8 s view) | 5.6 / 19 ms | 15 |
| 1×, 1/128 s/px (1 s view) | 5.5 / 6.4 ms | 15 |
| FF 64×, 2 s/px (4 min view) | 8.5 / 23 ms | 15 |
| analysis running, whole tape (level 0, strided, reloaded every 3 s) | 14.7 / 29 ms | 15 |

Lua heap 3.9 MB after a full GC with `field_L` open (the peaks string is
1.5 MB); 6–7 MB between collections. No xruns in these runs; scsynth as in
phase 2. A stopped tape no longer redraws (polls mark dirty only on change).

Decisions made while building it:
- Waveform: the peak column is dim (0.4 × level) with the rms as a brighter
  core; level = 3 + 12 × brightness × (0.4 + 0.6 × loudness), because room
  noise is spectrally "bright" and otherwise drew silence as a level-15 line.
  Heights are normalised to the tape's loudest bin with a ^0.6 curve.
- The strip uses rms heights (a 1 min column of speech always peaks near full
  scale; the rms tells talk from quiet).
- K1+E2 moves one strip pixel (1/128 of the tape) per tick, like a scrollbar,
  instead of ±1 min. The seek grace from phase 2 is kept.
- The other three pages are placeholders, so the dots and K1+E1 work now.

**Open after phase 3:**
- **First start after boot, once (2026-11-20):** the shield booted straight
  into aurotate; opening `field_L` drew the waveform but play gave no sound.
  A script reload then hung on "loading..." for about a minute, played a
  moment from the start, and came back to "choose a tape". The second load
  worked, and so did a later reboot straight into aurotate. Not reproduced;
  the journal isn't persistent (`journalctl --list-boots` shows only the
  current boot), so no logs. Suspects: the script starting before sclang /
  the engine is fully ready at boot, or a stuck NRT queue (proxy load +
  ring reads) on the first open. If it happens again: before rebooting, grab
  `journalctl -u norns-sclang -u norns-main --no-pager | tail -200` and
  `dbg_status()`. Consider `Storage=persistent` in journald.conf on the shield.
- The strip of a 2 h interview is fairly uniform: true to the material; the
  activity suggestions (§6.4) may be the better overview for speech.
- Redraw cost is mostly screen calls; if phase 4's region bands push it
  past ~15 ms, cache the strip in an image buffer (`screen.draw_to`) and only
  blit it.
- Ruler has no labels; time-of-day/offset labels at major ticks would need a
  smaller font than the 8 px one.

**Phase 4 result** (shield, Pi 3B+, 260616):

| | |
|---|---|
| restart | script reload and a full reboot: the last tape reopens at its saved position with its notes (after the reboot, test30m at 135 s, although PSET 1 named field_L) |
| PSET | two PSETs naming two tapes: read 1 / 2 / 1 switches tape, notes and position each time |
| gestures (REPL-driven `key`/`enc`/`keyboard.*`) | K3 tap/hold/out, K1+K3 popup and cancel, K1+K2 loop on/off (stays inside 130–140 s while playing), Esc resume with 2 s rewind, F6/F7, F8, F9 in/out, popup in-edge nudge +1.0 s with audition, delete with confirm, textentry label (open, cancel, back to the popup), editor cursor keys over soft wraps |
| redraw, 1× (field_L / test30m, a few notes) | 7–9 ms avg, 15 fps; with the editor open and typing for 60 s: 8.9 ms avg, 0 xruns |
| redraw, stress (test3h, 400 marks + 150 overlapping regions) | +4–9 ms over the same view without notes (12–15 ms avg at 8 s view and whole tape) |

Decisions made while building it (see also §8):
- Typing with nothing under the playhead makes a mark there and writes its
  note: the common transcription move is "stop, type what was said".
- Region out is taken at the K3 press; a mark at the K3 press (not release).
- In the editor, Enter closes (Shift+Enter is a new line); Esc stays
  play/stop so you can type and transport without leaving the editor.
- Tag palette defaults: interview, story, song, ritual, place, name, todo,
  private (`private` is meant for §4.7's "notes marked private").

**Open after phase 4:**
- **Hands-on on the device** (2026-11-20): "very good for a first version".
  Wanted next for the keyboard (in `docs/IDEAS.md`): Up/Down to jump between
  marks, Left/Right to cue with Shift/Ctrl for speed, Space for play/stop.
  These collide with the editor's cursor keys and typing; decide how before
  building.
- **Xruns while analysing a 3 h stereo WAV** (phase 2 issue, found now):
  one analysis job of `test3h.wav` gave ~50 xruns a minute ("SuperCollider
  was not finished"), during 1× play and idle alike; field_L (mono FLAC)
  gave none in phase 2. Earlier the same session several overlapping jobs
  ran (script reloads during an analysis) and left a cache with both `done`
  and `fail`; `analyze.sh` now takes a `flock` per cache dir, so a second
  job exits. Look at the single-job case: CPU (sox + tee + aurpeaks at
  nice 10), SD bandwidth or IRQs; try `ionice -c 3`, a smaller pipe buffer,
  or throttling (`pv -L`).
- Popup and editor have no K1+E1 page change (E1 still zooms behind them).
- The tom-thumb font lacks some punctuation (– …); ASCII and Latin-1 letters
  are fine.

**Phase 5 so far: Markdown export, regions list, reader** (2026-11-20,
shield): 61/61 checks on and off the device; PARAMS trigger on test3h writes
the file (UTF-8, escaped `#` line, marks inside a region say so) and the
header confirms it. Regions page driven from the REPL (screenshots): follow,
E2, tag filter, K3 jump, K1+K2 loop on/off from list and reader, reader
scroll, reader → item popup → back, keyboard Down/Enter; redraw 2.1 ms avg.
Hands-on still to do. Still to do in phase 5: Audacity / VTT / CSV, excerpts.
- REPL note: `nrepl.py` sends each line as its own chunk, so locals don't
  survive a newline; put a multi-step setup on one line.
Notes are written verbatim, so single line breaks (Shift+Enter) show as
one paragraph in rendered Markdown; the source keeps them. If that matters,
end lines with `\` on export and strip it on import.

**Phase 6 result** (2026-11-20, shield, Pi 3B+, 260616; fx v2 rack loaded):

| | |
|---|---|
| `sound_test()` levels (relative to the neutral stretch) | −12.0 dB (gain −12), −153 dB (dry 0), L 0.0 / R −153 dB (pan L), L +6.0 dB (nested gain +6 inside pan L), tone +1 −1.0 dB at 440 Hz, back to 0.0 dB after |
| boundary timing | mid-crossings of 60, 68, 70, 71 s within 1 ms of each other relative to 64 s; 10–90 % glide 12–15 ms at 50 ms (`Lag` is a 60 dB time) |
| clicks (second difference, × a clean sine's max) | boundaries, loop 62–66 s (wrap from dry 0 to −12 dB), 7 jumps between differently set places: ≤ 8× (the phase 1 slope kinks were ≤ 6×; a gain step would be ~200×). The 27–61× spots are the FF 8× cue (a 3.5 kHz sine) and the end of the recording |
| CPU (scsynth avg) | idle 18.9 %, 1× 20.8 %, idle with region sound off 19.0 %; 0 xruns |
| without the fx mod | not run with the mod disabled; the engine resolves `\FxSetup.asClass` to nil and writes the sends to a private bus (code path, logged `(no fx mod)`) |
| UI (screenshots) | popup sound rows with `(empty)` and `SILENT` (fx loaded, send a empty), checkered band edges (bottom: sound; top: send-as-insert), ♪ on the regions page, `aur_cur_*` follow the playhead and edit the region (gain −12 → −6 from the param resent the segment) |
| transport regression | `transport_test(nil, {loops = true, edges = true})` on field_L: every check PASS, 0 misses, 0 xruns, `jump_gain` 0.0; jack CPU 19.3–22.7 % avg |

Decisions made while building it:
- Only regions with sound make segments, so a document full of plain notes
  costs the engine nothing; the segment list is resent only when it differs.
- The popup's sound rows come after in / out; K3 on one resets it. Gain
  turns down to −40 dB, then one more tick is off.
- *region here* params are `set_save(false)`: they follow the playhead, and
  a PSET must not write values into whatever region is under it at load.
- The first run of `sound_test` had the system reverb (on, on the shield) in
  the recording, which filled the silences; the test now turns reverb and
  the input monitor off for the run and restores them.

**Open after phase 6:**
- **Hands-on by ear**, including send-as-insert with an effect in send a
  (with the send's tap level at 0), and the glide time.
- Run once with the fx mod disabled (SYSTEM > MODS) to see the fallback.
- Pan is a balance on the stereo voice; for mono tapes that is a pan with
  unity in the middle. A real stereo pan (width) is not there.
- Tone is a fixed tilt (±9 dB shelves at 250 Hz / 2.5 kHz); if it needs a
  different character, it is two numbers in `AurOut.addDefs`.

**Phase 8 result** (2026-11-20, shield, Pi 3B+, 260616):

| | |
|---|---|
| `reel_test()` (sine440 split into 3 mono WAV parts at frames 14412345 and 25933122, not chunk-aligned) | 13 boundary crossings (1×, reverse, 2×, a seek 50 ms before the boundary, a 2 s loop over it, at both boundaries): all PASS, max second difference 1.25–1.32× a clean sine at 1× and 4.28× at 2× (= 2², clean); max anywhere in the run 4.3× (a misread jumps the phase: ~100×+) |
| `transport_test` on a stereo FLAC reel (test30m split at 911.37 s into 2 FLAC parts) | basic + loops + edges: every check PASS, 0 misses, `jump_gain` 0.0; 1 xrun (loop20s_8x; the sporadic kind from phase 1). jack CPU 21.1–24.3 % avg (field_L single file: 19.3–22.7 %); far seeks 52.8 ms avg / 76.7 max. `idle_loaded` 36 % was its first analysis running |
| analysis of a reel | 20 min mono reel (3 parts) in ~8 s; P1 + P2 loaded over the whole reel |
| split hint and join (UI handlers from the REPL) | candidates: parts 2 and 3 `ok` by bext, an unrelated `REC0002.WAV` (same format) not; join from the popup (K3 twice) while part 1 was open: reel written, opened in its place, notes from parts 1 and 2 at 100 s and 310.257 s (part 2's 10 s + 300.257) |
| relink | moved the reel's folder: found by name + size, notes moved, analysis cache renamed (no new pass); and back again |
| start time | bext (14:00:00, time_ref) shows in the header with *clock* = time of day; a hand-set start from the popup (mtime guess, E3 +1 min) saved in the document; cleared back to none |
| export | `recorded:` line, the reel's parts, `(14:01:40)` in headings, `date time` in the metadata |
| redraw, collection page, playing | 3.8 ms avg, 11.6 max |
| tests | `lua5.3 test/model_test.lua` and `notes_test()`: 110/110 (bext from synthetic WAVs incl. a JUNK chunk, wall clock across midnight and month ends, reel parse/load/format mismatch/candidates, `Model.append`, the index bootstrap/sort/rename, `Store.move`, the strip reader, export with an origin) |

Decisions made while building it: see §8 (reel location, join is
user-confirmed, parts keep their notes and caches, the index lists opened
tapes, hand-set start wins). The tape popup's start row is called *start*
(not *recorded*), shown to the minute; its source (FROM FILE / BY HAND) is
in the popup title.

**Phase 9 result** (2026-11-20, shield, Pi 3B+, 260616; `tools/freesound_mock.py`
on the desktop over the LAN, so no real Freesound account was used):

| | |
|---|---|
| `lua5.3 test/model_test.lua`, `notes_test()` | 169 / 169 (phase 8: 110): JSON, SHA-256 / PKCE (RFC 7636 B), requests, names, headers, sniff, licenses, a sound-instance fixture → source, credit, sidecar, first note, validate, `set_source`, export, collection author/license, the token store (mode 600, pending 10 min, expiry, refresh rotation, same key keeps the login) |
| URL: WAV, mp3, redirect, Content-Disposition | WAV kept as is; mp3 → FLAC 48 kHz (ffmpeg); final URL after the redirect in the sidecar; `"Field Take 1.WAV"` → `Field_Take_1.wav`; a second copy → `tone-2.wav` |
| URL: HTML page, 404 | `not audio (html)`, `not found (404)`; nothing left behind |
| Freesound, key only | metadata + `preview-hq-ogg` → FLAC 48 kHz stereo, document with `source` and the first note (description with the HTML stripped, tags, credit), sidecar; an unknown id: `no sound 999` |
| login | the link in `freesound_login.txt`; a wrong code refused (`bad code or verifier`); the code pasted as the whole redirect URL accepted; the mock checked `S256(verifier)` against the challenge; the file is removed after |
| original, refresh, revoke | original aif → FLAC; with `expires` in the past: refreshed first, the new refresh token in `freesound.lua` at once; revoked: 401 → tokens cleared, `log in again`, falls back to the preview |
| cancel | a slow 77 MB download cancelled at 2 %: curl gone, no temp folder |
| queue file | the good line fetched, the bad one rewritten as `# not understood: …` |
| UI (screenshots) | add popup, download rows (arrow, %, queued, failed with its reason), the tape popup's source row and credit view; a downloaded tape opens, analyses (1 s for 12 s) and shows its first note |

Fixed while testing:
- **Cancel didn't kill anything:** `kill -TERM -- -<pgid>` is an error in
  dash (`/bin/sh` on the device; `--` isn't accepted), so only the outer
  shell died and curl kept writing into the deleted temp file. Now
  `kill -TERM -<pgid>`, in the vendored runner, in `../norns-deps` (not
  committed there yet), and in `lib/analysis.lua`, which had the same bug
  since phase 2 (stopping an analysis left sox / aurpeaks running).

**Open after phase 9:**
- **A real Freesound account**: everything above ran against the mock. Check
  the real authorize page (does it show the code with the registered
  redirect URI?), whether the token request wants `client_secret` with PKCE,
  the 24 h expiry, and a real original (wav/flac/mp3) and preview.
- **Beta quirk:** on this 260616 build an `os.execute` from inside a clock
  coroutine leaves a stale event, and the *next* script load prints
  `clock.lua:62: bad argument #1 to 'resume' (thread expected)` (harmless;
  the script loads). Downloads run their shell steps from the worker
  coroutine, so it shows after any download. A bare
  `clock.run(function() os.execute('true') end)` reproduces it; from a metro
  it doesn't. Not seen on stable; if it matters, launch jobs from a metro.
- The same sound downloaded twice is a second tape (`-2`); a preview isn't
  replaced when the original comes later.
- No search, no packs (§6.9 settled). No `credits.md` over the collection yet.
- textentry on the device for a long URL: only tried with the REPL; a USB
  keyboard is the realistic way.

**Open after phase 8:**
- **Hands-on on the device**: the collection page and popup, join on real
  recorder files (Zoom / Sound Devices / Tascam naming and bext), the wall
  clock in daily use.
- The parts' own documents and analysis caches stay after a join (a part
  opened on its own still shows its old notes; caches cost ~85 MB per 2 h).
  Offer to clean them up, or mark the part documents as joined.
- No bext from FLAC: a FLAC made from a BWF loses the chunk (sox). The import
  step (§2.3b) could carry it into the tape document, or read a Vorbis
  comment (`DATE`, `TIME_REFERENCE`) where a tool wrote one.
- A reel whose parts were edited (size, mtime) gets a new analysis; a part
  missing makes the whole reel missing (relink finds the reel file only, not
  single parts).
- The collection doesn't scan `dust/audio` for new files; *add a tape* opens
  the file browser.
- No wall-clock labels on the ruler (needs a smaller font, §9.1 phase 3).

### 9.1b Phase 7 (region voices + MIDI triggers): deferred (2026-11-20)
Skipped for now; phase 8 comes first. When it is picked up, start from the
revised AurVoice plan and its open questions in §2.4, and §2.5 (budgets).
`rate` (§3, product) is the field still missing from `lib/sound.lua`.

### 9.2 Test assets on the shield (keep; ~2.3 GB)
`we@10.0.0.138:~/dust/audio/aurotate-spike/`:
- `test3h.wav`: 3 h stereo, 16-bit 48 k. L = log sine sweep 100→4000 Hz
  (frequency = position, so a jump is audible), R = pink noise, 80 % tremolo
  with a 50 s period, so the waveform has shape.
- `test30m.flac`: the first 30 min, FLAC level 5.
- `test3h.peaks`: `aurpeaks` output, 20 ms bins (format in the C header).
- `p2_750_default.wav`, `p2_750_quick.wav` (750 Hz mono) and `p1_6k_quick.wav`
  (6 kHz mono): proxy candidates; compare the two P2 qualities by ear.
- `bench.sh`, `mon.sh`, `bench.log`, `mon.log`: timing scripts and results.

- `field_L.flac`: a real fieldwork interview (1 h 56 min, 48 k mono FLAC,
  converted from a 32 kHz m4a). Speech, room tone, quiet stretches. Private
  research material: keep on the device, don't publish or commit.
- `sine440.wav`: 20 min mono 440 Hz at −6 dB, for click checks.
- `sinesplit/`: sine440 split into `REC0001.WAV`, `REC0001_0001.WAV`,
  `REC0001_0002.WAV` (cuts at frames 14412345 and 25933122) with bext
  chunks (2025-08-03 14:00:00, continuous time_ref), `REC0002.WAV` (30 s,
  same format, not continuous), and `REC0001.reel` (the join). For
  `reel_test()`; `reel.wav` is its last recording. The reel's document has
  two test marks (part one, part two).
- `flacsplit/`: test30m.flac (stereo) split at frame 43745792 into
  `T30_A.flac`, `T30_B.flac`, with `T30.reel` written by hand.
- `clicks.wav`: the last `clicks_test` recording.
- Analysis cache for `field_L.flac` in `dust/data/aurotate/cache/field_L-d8063cae/`
  (p1 83 MB, p2 10 MB, peaks). Test reports from phase 2 in
  `dust/data/aurotate/transport_{report,lua}_{phase1,cue_p2,cue_p1}.txt` and
  the latest full run in `transport_{report,lua}.txt`.

### 9.3 CPU testing plan
**Phase 1 baseline** (scsynth avg / peak %, from the engine-side report; the
fx rack and mods are loaded, which is most of the base load):

| idle (loaded, stopped) | 1× | seeks | FF 16× | FF 64× (mono / stereo) | REW | scrub | loops |
|---|---|---|---|---|---|---|---|
| 15.0–15.9 / 21 | 15.6 / 23 | 16.8 / 26 | 16.6 / 24 | 19.8 / 27 · 21.3 / 28 | 16 / 24 | 16.7 / 26 | 15–16.5 / 23–26 |

**Phase 2** (scsynth avg %, `field_L.flac`):

| idle | 1× | far seeks | FF 16× | FF 64× | FF 128× | FF 256× | REW 256× | analysis running, 1× |
|---|---|---|---|---|---|---|---|---|
| 20.6 | 20.0 | 21.3–21.5 | 21.3 (P2 only, streams) · 20.4 (P1) | 23.9 (P2 only, streams) · 20.8 (P1) | 21.0 | 21.4–21.8 | 20.8–21.2 | 31.6 (jack) |

With a proxy covering the speed, FF/REW costs the same as 1×: the ring stops
streaming. The voice's base cost rose ~4.5 % (see §9.1).

The tape voice itself costs ~0.5 % at 1× and ~5 % at 64× (disk + cubic
interpolation) in phase 1. Jack CPU (`_norns.audio_get_cpu_load`) tracks scsynth within
1 %. Isolated peaks of 37–61 % appeared during FF 8× in 3 of 5 runs, without
xruns.

Earlier notes: top's single samples were noisy, with peaks
during 32–64× FF. Rather than more spike testing, measure as features land.
CPU depends mostly on what is not built yet: proxies, four region voices,
per-voice inserts, fx rack.
- Add CPU to the `phase` reports: scsynth's own average/peak from the
  engine-side `cpu_avg`/`cpu_peak` polls (already exposed by crone), plus
  `_norns.audio_get_cpu_load()`. Sample them in the phase harness, not with
  top.
- Record a baseline in every phase from 1 on: idle / 1× / 64× / jog /
  (later) four region voices + 2 inserts + fx rack sends.
- The Pi 3 is the budget device. Target ≤ 50 % scsynth average with
  everything on, so that matron, UI and fx have headroom.

### 9.4 Dev loop
- Deploy: `rsync -a --delete --exclude .git --exclude docs ./ we@10.0.0.138:dust/code/aurotate/`.
- REPL: `noseda/scripts/nrepl.py --host 10.0.0.138` (needs
  `websocket-client`; the venv from the spike was in a session scratchpad,
  so make a new one).
- SC class changes: `_norns.restart()` from the REPL. The websocket drops;
  wait until `journalctl -u norns-sclang` shows `engines: [...]`, then
  load the script and **grep the sclang journal for errors**. The REPL says
  `<ok>` even when the SynthDef failed.
- Lua-only changes: `norns.script.load("code/aurotate/aurotate.lua")`.
- Model/store tests: `lua5.3 test/model_test.lua` locally (no norns
  needed), `notes_test()` on the device (scratch dir under
  `dust/data/aurotate/model_test/`, removed when all pass).
- Tape documents: `dust/data/aurotate/tapes/`. Test notes go into the real
  tape's document; delete it afterwards (field_L's is private research).
- `reboot` doesn't save the "last script" state (SLEEP does), so after a
  reboot load the script from the REPL.
- Phase 2 tests: `transport_test(nil, {analysis = true, cue = true})` (~5 min),
  `transport_test(nil, {cue = true, proxy_mb = 300})` for P1 on a long file.
  The analysis cache is `dust/data/aurotate/cache/<name>-<hash>/`; a failed
  pass leaves its reason in `fail` there (and `build.log` for aurpeaks).
- sclang Events: a key that is an Object method (`next`, `rate`, `path`,
  `size`…) never reaches the dictionary; `p.next` called `Object:next`.
- UI checks: `dbg_shot('name')`, then
  `scp we@10.0.0.138:dust/data/aurotate/name.png .` and crop (64, 64, 576, 320).
  Force the focus look with `dbg.Tape.focusing = function() return true end`
  and `dbg.Tape.st.proxy_share = 1` in the same REPL chunk as `dbg_shot`.
- Downloads: `python3 -I tools/freesound_mock.py <dir> <desktop ip>` with
  test files in `<dir>` (see the script's header), then on the device
  `dbg.Download.FS.cfg.base = 'http://<ip>:8765'` and the mock's key and
  client id; `download(…)`, `downloads()`, `freesound_login()`,
  `freesound_code('GOODCODE')`. Afterwards remove `freesound.lua`,
  `dust/audio/aurotate/`, the test tapes' documents and caches, and their
  collection entries.
- Reels: `reel_test()` (~1 min), then `scp` `dust/audio/aurotate-spike/reel.wav`
  and `dust/data/aurotate/reel_events.txt` and run `tools/reel_check.py`
  (numpy, scipy). `transport_test(path, …)` takes a `.reel` path too.
- Tests: `transport_test()` (~8 min) or a subset, e.g.
  `transport_test(nil, {loops = true, edges = true})`; sections `basic`,
  `speed`, `scrub`, `loops`, `edges`. Wait for `dust/data/aurotate/transport_done`.
  Engine-side misses are logged in the sclang journal (`AurTape miss: …`)
  with the chunk/slot state, which is how the phase 1 feeder bugs were found.
- Binary params are 0/1 (not 1/2 like options).
- Script locals aren't visible in the REPL; keep a global `dbg_status()`.
- The device runs a 3.x beta (260616); matron and crone are the
  `norns-main` service.

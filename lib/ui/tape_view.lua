-- tape view: the zoomable tape around a fixed playhead (4TRK model), with the
-- whole tape in a strip below (docs/PLAN.md §4.1)
--
--  y  0–8   header: page dots · name · state · time
--     10–13 ruler
--     14    loop bar
--     15–17 flags: marks, and regions at their start (filled: has a note)
--     16–50 waveform (playhead at x = 64); regions are bands with the
--           waveform cut out of them (a negative), marks 1 px lines
--     54    marks on the whole tape (dots)
--     54–63 whole tape: waveform, regions, loop, bracket for the part shown above

local Peaks = include 'lib/peaks'
local Draw = include 'lib/ui/draw'

local V = {}

local W = 128
local PH_X = 64
local RULER_Y = 10
local LOOP_Y = 14
local WAVE_Y, WAVE_H = 33, 17   -- centre, half height
local STRIP_Y, STRIP_H = 59, 3  -- centre, half height; bracket from 54 to 63
local ZOOMS = { 1/128, 1/64, 1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, 5, 10, 30, 60, 120, 300 } -- s/px
local TICKS = { 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600 }
local MAJOR = { [0.1] = 1, [0.25] = 1, [0.5] = 5, [1] = 5, [2] = 10, [5] = 30, [10] = 60,
  [15] = 60, [30] = 300, [60] = 300, [120] = 600, [300] = 1800, [600] = 3600, [900] = 3600,
  [1800] = 3600, [3600] = 3 * 3600 }
local FOCUS_R = 28 -- px either side of the playhead drawn dithered while focusing

V.zoom = 6 -- index into the zooms for the current tape; the last one is the whole tape

local frame = 0
local msg, msg_until = nil, 0
local last_misses = 0

-- scratch arrays, reused every frame
local amp, rms, bright = {}, {}, {}
local h_out, l_out, h_in, l_in, skip = {}, {}, {}, {}, {}
local cols = { peaks = nil, spp = nil, t0 = nil }
local band, sband = {}, {} -- per column: region band level (0 none), view and strip
local BAND = { 8, 11, 13 }    -- by depth of overlap
local SBAND = { 5, 7, 9 }
local PENDING = 3             -- the selection while a region is being made
local ov = { peaks = nil, dur = nil, amp = {}, rms = {}, bright = {}, h = {}, lv = {} }

---- zoom

-- s/px per zoom index for a tape `dur` long; the last entry (0) is "whole tape"
local function zooms(dur)
  local z = {}
  for _, s in ipairs(ZOOMS) do
    if s * W < dur then z[#z + 1] = s end
  end
  z[#z + 1] = 0
  return z
end

-- the view: s/px, time at x = 0, playhead x
function V.view(st)
  local z = zooms(st.dur)
  V.zoom = util.clamp(V.zoom, 1, #z)
  local spp = z[V.zoom]
  if spp == 0 then -- whole tape: the playhead travels
    spp = math.max(st.dur, 1e-3) / W
    return spp, 0, util.clamp(math.floor(st.pos / spp), 0, W - 1), true
  end
  -- columns on a fixed grid of the tape (k·spp), so they don't shimmer as it
  -- scrolls; the tape moves in whole pixels
  local k = math.floor(st.pos / spp)
  return spp, (k - PH_X) * spp, PH_X, false
end

local function fmt_span(s)
  if s < 59.5 then return string.format('%g s', math.floor(s * 10 + 0.5) / 10) end
  local m = math.floor(s / 60 + 0.5)
  if m < 60 then return m .. ' min' end
  return string.format('%dh%02d', m // 60, m % 60)
end

function V.message(text, secs)
  msg, msg_until = text, util.time() + (secs or 1)
end

-- true once a message has just expired (the caller redraws)
function V.tick()
  if msg and util.time() >= msg_until then
    msg = nil
    return true
  end
  return false
end

function V.zoom_turn(st, d)
  if not st.path then return end
  V.zoom = util.clamp(V.zoom + d, 1, #zooms(st.dur))
  local spp = V.view(st)
  V.message(spp * W >= st.dur and 'WHOLE' or fmt_span(spp * W), 1)
end

---- drawing

local function state_label(Tape, st)
  if msg then return msg, 15 end
  if not st.path then return nil end
  if st.misses > last_misses then
    last_misses = st.misses
    V.message('MISS', 1.5)
    return 'MISS', 15
  end
  if st.jogging then return 'SCRUB', 15 end
  if Tape.focusing() then return 'FOCUS', 15 end
  local r = params:get('aur_shuttle')
  if r == 0 then return 'STOP', 6 end
  if r == 1 then return 'PLAY', 15 end
  if r > 1 then return string.format('FF x%g', r), 15 end
  if r < 0 then return string.format('REW x%g', -r), 15 end
  return string.format('x%g', r), 15
end
V.state_label = state_label -- the regions page shows the same state

local function draw_ruler(spp, t0, dur)
  local tick = TICKS[#TICKS]
  for _, t in ipairs(TICKS) do
    if t / spp >= 8 then tick = t break end
  end
  local every = math.max(1, math.floor((MAJOR[tick] or tick * 5) / tick + 0.5))
  local first = math.ceil(math.max(0, t0) / tick)
  local last = math.floor(math.min(dur, t0 + W * spp) / tick)
  for _, major in ipairs({ false, true }) do
    local any = false
    for i = first, last do
      if (i % every == 0) == major then
        local x = math.floor((i * tick - t0) / spp)
        screen.rect(x, RULER_Y, 1, major and 4 or 2)
        any = true
      end
    end
    if any then
      screen.level(major and 6 or 2)
      screen.fill()
    end
  end
end

local function draw_loop(st, spp, t0, ph_x)
  local function x_of(t) return math.floor((t - t0) / spp) end
  if params:get('aur_loop') == 1 then
    local a, b = params:get('aur_loop_in'), params:get('aur_loop_out')
    if a > b then a, b = b, a end
    local x0, x1 = math.max(0, x_of(a)), math.min(W - 1, x_of(b))
    if x1 >= 0 and x0 < W then
      screen.level(10)
      screen.rect(x0, LOOP_Y, math.max(1, x1 - x0 + 1), 1)
      screen.fill()
      screen.level(3)
      for _, x in ipairs({ x_of(a), x_of(b) }) do
        if x >= 0 and x < W then screen.rect(x, WAVE_Y - WAVE_H, 1, 2 * WAVE_H + 1) end
      end
      screen.fill()
    end
  end
  if st.pending_in then
    local x = x_of(st.pending_in)
    local x0, x1 = math.min(x, ph_x), math.max(x, ph_x)
    Draw.dotted(math.max(0, x0), math.min(W - 1, x1), LOOP_Y, 6)
    if x >= 0 and x < W then
      screen.level(8)
      screen.rect(x, LOOP_Y, 1, 2 * WAVE_H + 3)
      screen.fill()
    end
  end
end

-- columns covered by [a, b) (at least one)
local function x_range(a, b, t0, spp)
  local x0 = math.floor((a - t0) / spp)
  local x1 = math.ceil((b - t0) / spp) - 1
  if x1 < x0 then x1 = x0 end
  return math.max(0, x0), math.min(W - 1, x1)
end

-- band levels per column for the regions (and the growing selection)
local function fill_bands(doc, st, out, levels, t0, spp)
  for i = 1, W do out[i] = 0 end
  local t1 = t0 + W * spp
  if doc then
    for _, r in ipairs(doc.regions) do
      if r.t0 >= t1 then break end
      if r.t1 > t0 then
        local x0, x1 = x_range(r.t0, r.t1, t0, spp)
        for x = x0 + 1, x1 + 1 do out[x] = out[x] + 1 end
      end
    end
    for i = 1, W do
      local d = out[i]
      if d > 0 then out[i] = levels[math.min(d, #levels)] end
    end
  end
  if st.pending_in then
    local a, b = math.min(st.pending_in, st.pos), math.max(st.pending_in, st.pos)
    if b > t0 and a < t1 then
      local x0, x1 = x_range(a, b, t0, spp)
      for x = x0 + 1, x1 + 1 do
        if out[x] == 0 then out[x] = PENDING end
      end
    end
  end
end

-- a level-0 line through the band columns at y (cuts the baseline out);
-- one rect per run of band columns
local function cut_line(out, y)
  local any, i = false, 1
  while i <= W do
    if out[i] > 0 then
      local j = i
      while j < W and out[j + 1] > 0 do j = j + 1 end
      screen.rect(i - 1, y, j - i + 1, 1)
      any = true
      i = j + 1
    else
      i = i + 1
    end
  end
  if any then
    screen.level(0)
    screen.fill()
  end
end

-- flag at the top of x: a filled box with a note, an outline without
-- (batched: Draw.flush fills it)
local function flag(x, filled, level)
  if filled then
    Draw.add(level, x, 15, 4, 3)
  else
    Draw.add(level, x, 15, 4, 1)
    Draw.add(level, x, 17, 4, 1)
    Draw.add(level, x + 3, 16, 1, 1)
  end
end

-- per column: 0 none, 1 flag, 2 flag with a note, +4 the item "here"
local mcol, rcol = {}, {}

local function flag_level(v) return v >= 4 and 15 or 10 end

-- marks and region flags, one per column however many share it (a whole
-- tape of 400 marks draws 128 columns, not 400 lines)
local function draw_marks(doc, t0, spp, here)
  if not doc then return end
  local t1 = t0 + W * spp
  for i = 1, W do mcol[i], rcol[i] = 0, 0 end
  local function put(col, x, item)
    local v = (item.note ~= '' and 2 or 1) + (item == here and 4 or 0)
    local o = col[x + 1]
    col[x + 1] = math.max(o % 4, v % 4) + ((o >= 4 or v >= 4) and 4 or 0)
  end
  for _, r in ipairs(doc.regions) do
    if r.t0 >= t1 then break end
    if r.t0 >= t0 then put(rcol, math.floor((r.t0 - t0) / spp), r) end
  end
  for _, m in ipairs(doc.marks) do
    if m.t >= t1 then break end
    if m.t >= t0 then put(mcol, math.floor((m.t - t0) / spp), m) end
  end
  local bot = WAVE_Y + WAVE_H
  for x = 0, W - 1 do
    local v = mcol[x + 1]
    if v > 0 then
      if band[x + 1] > 0 then
        -- inside a band: notches cut out at its top and bottom, so dense
        -- marks don't erase the band
        Draw.add(0, x, 18, 1, 2)
        Draw.add(0, x, bot - 2, 1, 3)
      else
        Draw.add(v >= 4 and 12 or 7, x, 18, 1, bot - 17)
      end
    end
  end
  Draw.flush() -- the lines first: the flags go over them
  for x = 0, W - 1 do
    local v = math.max(mcol[x + 1], rcol[x + 1])
    if v > 0 then flag(x, v % 4 == 2, flag_level(v)) end
  end
  Draw.flush()
end

local function draw_wave(Tape, st, spp, t0, ph_x)
  local p = st.peaks
  local x_from = math.max(0, math.ceil(-t0 / spp))
  local x_to = math.min(W - 1, math.ceil((st.dur - t0) / spp) - 1)
  if x_to < x_from then return end
  local x_peaks = p and math.min(x_to, math.ceil((p.secs - t0) / spp) - 1) or x_from - 1
  if x_peaks < x_to then -- not analysed (yet): a dotted tape
    Draw.dotted(math.max(x_from, x_peaks + 1), x_to, WAVE_Y, 2)
  end
  if x_peaks < x_from then return end
  if cols.peaks ~= p or cols.spp ~= spp or cols.t0 ~= t0 then
    cols.peaks, cols.spp, cols.t0 = p, spp, t0
    Peaks.columns(p, t0, t0 + W * spp, W, amp, rms, bright)
  end
  -- focus: near the playhead every other column is left out (and the rest
  -- dimmed); the dithered patch shrinks as the full resolution takes over
  local r = Tape.focusing() and FOCUS_R * math.min(1, st.proxy_share * 1.5) or 0
  local n = 0
  for x = x_from, x_peaks do
    n = n + 1
    -- brighter sound draws brighter; near-silence stays dim however noisy
    local hr = Peaks.height(p, rms[x + 1])
    local b = Peaks.bright(p, bright[x + 1]) * (0.4 + 0.6 * math.min(1, 2 * hr))
    local l = 3 + math.floor(b * 12 + 0.5)
    local ho = math.floor(Peaks.height(p, amp[x + 1]) * WAVE_H + 0.5)
    local hi = math.floor(hr * WAVE_H + 0.5)
    local near = math.abs(x - ph_x) < r
    skip[n] = near and (x + frame) % 2 == 0
    if near then l = math.max(2, l // 2) end
    h_out[n], l_out[n] = ho, math.max(1, math.floor(l * 0.4))
    h_in[n], l_in[n] = hi == 0 and -1 or math.min(hi, ho), l
    if ho == 0 then h_out[n] = -1 end -- silence: the baseline below shows
    if band[x + 1] > 0 then l_out[n], l_in[n] = 0, 0 end -- cut out of the region
  end
  screen.level(1)
  screen.rect(x_from, WAVE_Y, x_peaks - x_from + 1, 1)
  screen.fill()
  cut_line(band, WAVE_Y)
  Draw.columns(x_from, WAVE_Y, n, h_out, l_out, skip)
  Draw.columns(x_from, WAVE_Y, n, h_in, l_in, skip)
end

local function draw_strip(st, spp, t0, fit, doc)
  local p = st.peaks
  local sx = W / math.max(st.dur, 1e-3)
  local function x_of(t) return util.clamp(math.floor(t * sx), 0, W - 1) end
  fill_bands(doc, st, sband, SBAND, 0, 1 / sx)
  Draw.runs(0, STRIP_Y - STRIP_H, 2 * STRIP_H + 1, W, sband)
  if params:get('aur_loop') == 1 then
    local a, b = params:get('aur_loop_in'), params:get('aur_loop_out')
    if a > b then a, b = b, a end
    screen.level(2)
    screen.rect(x_of(a), STRIP_Y - STRIP_H, x_of(b) - x_of(a) + 1, 2 * STRIP_H + 1)
    screen.fill()
  end
  local x_peaks = p and math.min(W - 1, math.ceil(p.secs * sx) - 1) or -1
  if x_peaks < W - 1 then Draw.dotted(x_peaks + 1, W - 1, STRIP_Y, 2) end
  if p and x_peaks >= 0 then
    if ov.peaks ~= p or ov.dur ~= st.dur then
      ov.peaks, ov.dur = p, st.dur
      Peaks.columns(p, 0, st.dur, W, ov.amp, ov.rms, ov.bright)
      -- a column is ~1 min of a long tape, where the peaks are all near full:
      -- the rms tells talk from quiet better
      for i = 1, W do
        local hr = Peaks.rms_height(p, ov.rms[i])
        local h = math.floor(hr * STRIP_H + 0.5)
        ov.h[i] = h == 0 and -1 or h
        ov.lv[i] = 2 + math.floor(Peaks.bright(p, ov.bright[i]) * (0.4 + 0.6 * hr) * 9 + 0.5) -- ≤ 11: 15 is the playhead
      end
    end
    screen.level(1)
    screen.rect(0, STRIP_Y, x_peaks + 1, 1)
    screen.fill()
    cut_line(sband, STRIP_Y)
    -- inside a region the columns are cut out (levels copied, not cached)
    for i = 1, x_peaks + 1 do l_out[i] = sband[i] > 0 and 0 or ov.lv[i] end
    Draw.columns(0, STRIP_Y, x_peaks + 1, ov.h, l_out)
  end
  if doc and #doc.marks > 0 then
    -- one dot per column (a screen call per mark costs ~30 µs on a Pi 3)
    for i = 1, W do mcol[i] = 0 end
    for _, m in ipairs(doc.marks) do mcol[x_of(m.t) + 1] = 1 end
    Draw.runs(0, 54, 1, W, mcol, 12)
  end
  -- bracket: the part shown above
  if not fit then
    local x0 = math.floor(math.max(0, t0) * sx)
    local x1 = math.min(W - 1, math.floor(math.min(st.dur, t0 + W * spp) * sx))
    if x1 - x0 < 2 then x0, x1 = x0 - 1, x0 + 1 end
    screen.level(15)
    screen.rect(x0, 54, 1, 10)
    screen.rect(x1, 54, 1, 10)
    if x1 - x0 > 3 then
      screen.rect(x0 + 1, 54, 1, 1)
      screen.rect(x0 + 1, 63, 1, 1)
      screen.rect(x1 - 1, 54, 1, 1)
      screen.rect(x1 - 1, 63, 1, 1)
    end
    screen.fill()
  end
  screen.level(15)
  screen.rect(x_of(st.pos), STRIP_Y - STRIP_H - 1, 1, 2 * STRIP_H + 3)
  screen.fill()
end

-- draws the frame without screen.update (popups go over it). `doc` is the
-- tape document, `here` the mark or region under the playhead.
function V.redraw(Tape, page, pages, doc, here)
  local st = Tape.st
  frame = frame + 1
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  local state, slev = state_label(Tape, st)
  local name, nlev, nfont = st.name, 4, false
  if here then name, nlev, nfont = here.label ~= '' and here.label or here.id, 12, here.label ~= '' end
  Draw.header(page, pages, name, state, slev,
    st.path and Tape.hms(st.pos, true) or nil, nlev, nfont)
  if not st.path then
    screen.level(4)
    screen.move(64, 34)
    screen.text_center('K3: choose a tape')
    screen.move(64, 44)
    screen.text_center('(or PARAMS > TAPE)')
    return
  end
  local spp, t0, ph_x, fit = V.view(st)
  draw_ruler(spp, t0, st.dur)
  draw_loop(st, spp, t0, ph_x)
  fill_bands(doc, st, band, BAND, t0, spp)
  Draw.runs(0, WAVE_Y - WAVE_H, 2 * WAVE_H + 1, W, band)
  draw_wave(Tape, st, spp, t0, ph_x)
  draw_marks(doc, t0, spp, here)
  -- playhead (dim while the chunk under it loads)
  screen.level(st.ok > 0 and 15 or 5)
  screen.rect(ph_x, RULER_Y, 1, LOOP_Y - RULER_Y + 2 * WAVE_H + 3)
  screen.fill()
  draw_strip(st, spp, t0, fit, doc)
end

return V

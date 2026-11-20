-- tape view: the zoomable tape around a fixed playhead (4TRK model), with the
-- whole tape in a strip below (docs/PLAN.md §4.1)
--
--  y  0–8   header: page dots · name · state · time
--     10–13 ruler
--     14    loop bar
--     16–50 waveform (playhead at x = 64)
--     54–63 whole tape: waveform, loop, bracket for the part shown above

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
  end
  screen.level(1)
  screen.rect(x_from, WAVE_Y, x_peaks - x_from + 1, 1)
  screen.fill()
  Draw.columns(x_from, WAVE_Y, n, h_out, l_out, skip)
  Draw.columns(x_from, WAVE_Y, n, h_in, l_in, skip)
end

local function draw_strip(st, spp, t0, fit)
  local p = st.peaks
  local sx = W / math.max(st.dur, 1e-3)
  local function x_of(t) return util.clamp(math.floor(t * sx), 0, W - 1) end
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
    Draw.columns(0, STRIP_Y, x_peaks + 1, ov.h, ov.lv)
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

function V.redraw(Tape, page, pages)
  local st = Tape.st
  frame = frame + 1
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  local state, slev = state_label(Tape, st)
  Draw.header(page, pages, st.name, state, slev,
    st.path and Tape.hms(st.pos, true) or nil)
  if not st.path then
    screen.level(4)
    screen.move(64, 34)
    screen.text_center('K3: choose a tape')
    screen.move(64, 44)
    screen.text_center('(or PARAMS > TAPE)')
    screen.update()
    return
  end
  local spp, t0, ph_x, fit = V.view(st)
  draw_ruler(spp, t0, st.dur)
  draw_loop(st, spp, t0, ph_x)
  draw_wave(Tape, st, spp, t0, ph_x)
  -- playhead (dim while the chunk under it loads)
  screen.level(st.ok > 0 and 15 or 5)
  screen.rect(ph_x, RULER_Y, 1, LOOP_Y - RULER_Y + 2 * WAVE_H + 3)
  screen.fill()
  draw_strip(st, spp, t0, fit)
  screen.update()
end

return V

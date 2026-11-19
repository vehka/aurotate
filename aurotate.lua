-- aurotate
-- an audio-anthropology workbench:
-- hours-long recordings on tape
--
-- phase 2: analysis, proxies, cue
--
-- K2 play / stop
-- K3 loop in, out, off
-- K1+K3 cancel loop in
-- E2 scrub (inertia)
-- K1+E2 seek ±1 min
-- E3 speed (shuttle ±64, ±256
--    once analysed)
--
-- tape: PARAMS > TAPE

engine.name = 'Aurotate'

local Tape = include 'lib/tape'
local Peaks = include 'lib/peaks'

local st = Tape.st
local shift = false
-- E2 ticks just around a K1+E2 seek are taken as part of it, so a stray tick
-- doesn't drop into scrub (which takes over from play and coasts to a stop)
local SEEK_GRACE = 0.4
local last_seek = -1

local redraw_metro

function init()
  Tape.add_params()
  params:default()
  Tape.start_polls()
  redraw_metro = metro.init(function()
    if Tape.dirty then
      Tape.dirty = false
      redraw()
    end
  end, 1 / 15)
  redraw_metro:start()
end

function key(n, z)
  if n == 1 then
    shift = z == 1
    if z == 0 and util.time() - last_seek < SEEK_GRACE then last_seek = util.time() end
    return
  end
  if z == 0 then return end
  if n == 2 then
    Tape.toggle()
  elseif n == 3 then
    if shift then Tape.loop_cancel() else Tape.loop_key() end
  end
end

function enc(n, d)
  if n == 2 then
    if shift then
      last_seek = util.time()
      Tape.jump(st.pos + d * 60)
    elseif util.time() - last_seek > SEEK_GRACE then
      Tape.jog_turn(d)
    end
  elseif n == 3 then
    Tape.shuttle_turn(d)
  end
end

local function state_label()
  if not st.path then return 'NO TAPE' end
  if st.jogging then return 'SCRUB' end
  if Tape.focusing() then return 'FOCUS' end
  local r = params:get('aur_shuttle')
  if r == 0 then return 'STOP' end
  if r == 1 then return 'PLAY' end
  if r > 1 then return string.format('FF x%g', r) end
  if r < 0 then return string.format('REW x%g', -r) end
  return string.format('PLAY x%g', r)
end

local BAR_X, BAR_W, BAR_Y, BAR_H = 2, 124, 46, 7 -- whole-tape strip: centre, half height

-- whole-tape overview columns, recomputed when the peaks change
local overview = { peaks = nil }
local function overview_cols()
  if st.peaks ~= overview.peaks then
    overview.peaks = st.peaks
    if st.peaks then
      overview.amp, overview.rms, overview.bright = Peaks.columns(st.peaks, 0, st.dur, BAR_W)
    end
  end
  return st.peaks and overview
end

local function bar_x(t)
  if st.dur <= 0 then return BAR_X end
  return BAR_X + util.round(util.clamp(t / st.dur, 0, 1) * (BAR_W - 1))
end

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  -- header: name · state
  screen.level(4)
  screen.move(2, 8)
  screen.text(st.name and util.trim_string_to_width(st.name, 80) or 'PARAMS > TAPE')
  screen.level(15)
  screen.move(126, 8)
  screen.text_right(state_label())

  if not st.path then
    screen.update()
    return
  end

  -- time (dimmed while the chunk under the playhead loads)
  screen.font_size(16)
  screen.level(st.ok > 0 and 15 or 4)
  screen.move(2, 30)
  screen.text(Tape.hms(st.pos, true))
  screen.font_size(8)
  screen.level(4)
  screen.move(126, 30)
  screen.text_right('/ ' .. Tape.hms(st.dur))

  -- whole tape: loop band, waveform (brighter sound draws brighter),
  -- pending loop in, playhead
  local a, b = params:get('aur_loop_in'), params:get('aur_loop_out')
  if a > b then a, b = b, a end
  if params:get('aur_loop') == 1 then
    screen.level(3)
    screen.rect(bar_x(a), BAR_Y - BAR_H - 1, math.max(1, bar_x(b) - bar_x(a) + 1), BAR_H * 2 + 3)
    screen.fill()
  end
  local ov = overview_cols()
  if ov then
    for i = 1, BAR_W do
      local h = math.max(0, util.round(ov.amp[i] * BAR_H))
      screen.level(util.clamp(util.round(3 + ov.bright[i] * 12), 3, 15))
      screen.rect(BAR_X + i - 1, BAR_Y - h, 1, h * 2 + 1)
      screen.fill()
    end
  else
    screen.level(2)
    screen.rect(BAR_X, BAR_Y - 1, BAR_W, 3)
    screen.fill()
  end
  if st.pending_in then
    screen.level(10)
    screen.rect(bar_x(st.pending_in), BAR_Y - BAR_H - 2, 1, BAR_H * 2 + 5)
    screen.fill()
  end
  screen.level(0)
  screen.rect(bar_x(st.pos) - 1, BAR_Y - BAR_H - 3, 3, BAR_H * 2 + 7)
  screen.fill()
  screen.level(15)
  screen.rect(bar_x(st.pos), BAR_Y - BAR_H - 3, 1, BAR_H * 2 + 7)
  screen.fill()

  -- footer: speed, loop, dropouts
  screen.level(4)
  screen.move(2, 62)
  screen.text(string.format('%+.2fx', st.rate))
  screen.move(64, 62)
  if params:get('aur_loop') == 1 then
    screen.text_center('LOOP')
  elseif st.pending_in then
    screen.text_center('IN ' .. Tape.hms(st.pending_in))
  elseif Tape.analysis.state == 'running' then
    screen.text_center(string.format('analysing %d%%', math.floor(Tape.analysis.progress * 100)))
  elseif Tape.analysis.state == 'failed' then
    screen.text_center('no analysis')
  end
  if st.misses > 0 then
    screen.move(126, 62)
    screen.text_right('miss ' .. math.floor(st.misses))
  end
  screen.update()
end

-- for the REPL (script locals aren't visible there)
function dbg_status()
  local an = Tape.analysis
  print(string.format('POS %.2f/%.0f RATE %.3f SHUTTLE %g JOG %s OK %d MISS %d LOOP %d %.1f-%.1f XRUNS %d CPU %.1f'
    .. ' ANALYSIS %s %.0f%% PROXIES %d SHARE %.2f',
    st.pos, st.dur, st.rate, params:get('aur_shuttle'), tostring(st.jogging), st.ok, st.misses,
    params:get('aur_loop'), params:get('aur_loop_in'), params:get('aur_loop_out'),
    _norns.audio_get_xrun_count(), _norns.audio_get_cpu_load(),
    an.state, an.progress * 100, st.proxies, st.proxy_share))
end

-- automated transport run; see test/transport.lua
function transport_test(path, only)
  return include('test/transport').run(Tape, path, only)
end

function clicks_test(path)
  return include('test/transport').clicks(Tape, path)
end

function cleanup()
  if redraw_metro then redraw_metro:stop() end
  Tape.cleanup()
end

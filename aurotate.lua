-- aurotate
-- an audio-anthropology workbench:
-- hours-long recordings on tape
--
-- phase 1: transport
--
-- K2 play / stop
-- K3 loop in, out, off
-- K1+K3 cancel loop in
-- E2 scrub (inertia)
-- K1+E2 seek ±1 min
-- E3 speed (shuttle −64…64)
--
-- tape: PARAMS > TAPE

engine.name = 'Aurotate'

local Tape = include 'lib/tape'

local st = Tape.st
local shift = false
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
    if shift then Tape.jump(st.pos + d * 60) else Tape.jog_turn(d) end
  elseif n == 3 then
    Tape.shuttle_turn(d)
  end
end

local function state_label()
  if not st.path then return 'NO TAPE' end
  if st.jogging then return 'SCRUB' end
  local r = params:get('aur_shuttle')
  if r == 0 then return 'STOP' end
  if r == 1 then return 'PLAY' end
  if r > 1 then return string.format('FF x%g', r) end
  if r < 0 then return string.format('REW x%g', -r) end
  return string.format('PLAY x%g', r)
end

local BAR_X, BAR_W, BAR_Y = 2, 124, 44

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

  -- whole tape: loop band, pending loop in, playhead
  screen.level(2)
  screen.rect(BAR_X, BAR_Y, BAR_W, 4)
  screen.fill()
  local a, b = params:get('aur_loop_in'), params:get('aur_loop_out')
  if a > b then a, b = b, a end
  if params:get('aur_loop') == 1 then
    screen.level(8)
    screen.rect(bar_x(a), BAR_Y - 2, math.max(1, bar_x(b) - bar_x(a) + 1), 8)
    screen.fill()
  end
  if st.pending_in then
    screen.level(10)
    screen.rect(bar_x(st.pending_in), BAR_Y - 3, 1, 10)
    screen.fill()
  end
  screen.level(15)
  screen.rect(bar_x(st.pos), BAR_Y - 4, 1, 12)
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
  end
  if st.misses > 0 then
    screen.move(126, 62)
    screen.text_right('miss ' .. math.floor(st.misses))
  end
  screen.update()
end

-- for the REPL (script locals aren't visible there)
function dbg_status()
  print(string.format('POS %.2f/%.0f RATE %.3f SHUTTLE %g JOG %s OK %d MISS %d LOOP %d %.1f-%.1f XRUNS %d CPU %.1f',
    st.pos, st.dur, st.rate, params:get('aur_shuttle'), tostring(st.jogging), st.ok, st.misses,
    params:get('aur_loop'), params:get('aur_loop_in'), params:get('aur_loop_out'),
    _norns.audio_get_xrun_count(), _norns.audio_get_cpu_load()))
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

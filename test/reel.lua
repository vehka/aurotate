-- reel test (phase 8): plays a sine split into parts (a reel) across the part
-- boundaries and records the norns output with the system TAPE. A read that
-- is off by any amount at a boundary shows as a jump in the sine's phase,
-- which tools/reel_check.py finds from the recording and the event log:
--
--   dust/audio/aurotate-spike/reel.wav      the recording
--   dust/data/aurotate/reel_events.txt      "<rec time> <tape pos> <event>"
--
-- reel_test(path, bounds) from the REPL; the defaults are the test reel made
-- from sine440.wav (docs/PLAN.md §9.2): boundaries at 300.2571875 s and
-- 540.273375 s.

local T = {}

T.PATH = 'aurotate-spike/sinesplit/REC0001.reel'
T.BOUNDS = { 14412345 / 48000, 25933122 / 48000 }

function T.run(Tape, path, bounds)
  local st = Tape.st
  path = path or (_path.audio .. T.PATH)
  bounds = bounds or T.BOUNDS
  local data = norns.state.data
  local ev = io.open(data .. 'reel_events.txt', 'w')
  local t0
  local logging = true
  local function mark(s)
    ev:write(string.format('%.3f %.4f %s xruns %d\n', util.time() - t0, st.pos, s, _norns.audio_get_xrun_count()))
    ev:flush()
  end
  local function speed(r) params:set('aur_shuttle', r) end
  return clock.run(function()
    local mix = { reverb = params:get('reverb'), monitor_level = params:get('monitor_level') }
    params:set('reverb', 1)
    params:set('monitor_level', -math.huge)
    params:set('aur_loop', 0)
    speed(0)
    params:set('aur_file', path)
    clock.sleep(4)
    if not st.parts then
      print('reel_test: ' .. path .. ' is not an open reel')
      ev:close()
      return
    end
    local rec = _path.audio .. 'aurotate-spike/reel.wav'
    audio.tape_record_open(rec)
    clock.sleep(0.2)
    audio.tape_record_start()
    t0 = util.time()
    -- the position, 20 times a second, for mapping the recording to the tape
    clock.run(function()
      while logging do
        mark('pos')
        clock.sleep(0.05)
      end
    end)
    for k, b in ipairs(bounds) do
      mark('section ' .. k .. ' 1x through')
      Tape.jump(b - 3)
      clock.sleep(0.5)
      speed(1)
      clock.sleep(6)
      speed(0)
      clock.sleep(1)
      mark('section ' .. k .. ' reverse through')
      Tape.jump(b + 3)
      clock.sleep(0.5)
      speed(-1)
      clock.sleep(6)
      speed(0)
      clock.sleep(1)
      mark('section ' .. k .. ' seek to just before')
      Tape.jump(b - 0.05)
      clock.sleep(0.05)
      speed(1)
      clock.sleep(2)
      speed(0)
      clock.sleep(1)
      mark('section ' .. k .. ' 2x through')
      Tape.jump(b - 6)
      clock.sleep(0.5)
      speed(2)
      clock.sleep(5)
      speed(0)
      clock.sleep(1)
      mark('section ' .. k .. ' loop over it')
      Tape.loop(b - 1, b + 1)
      clock.sleep(0.3)
      speed(1)
      clock.sleep(5)
      params:set('aur_loop', 0)
      speed(0)
      clock.sleep(1)
    end
    mark('end')
    logging = false
    clock.sleep(0.5)
    audio.tape_record_stop()
    ev:close()
    params:set('reverb', mix.reverb)
    params:set('monitor_level', mix.monitor_level)
    print('reel_test: done; ' .. rec)
    local f = io.open(data .. 'reel_done', 'w')
    if f then f:close() end
  end)
end

return T

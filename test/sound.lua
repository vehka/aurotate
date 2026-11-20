-- region sound test (phase 6): plays a sine through regions with sound
-- settings and records the norns output with the system TAPE. The levels and
-- clicks are checked off the device (tools/sound_check.py) from the recording
-- and the event log:
--
--   dust/audio/aurotate-spike/sound.wav      the recording
--   dust/data/aurotate/sound_events.txt      "<rec time> <tape pos> <event>"
--   dust/data/aurotate/sound_segments.txt    the segments the engine got
--
-- The test regions go into the sine's tape document and are removed at the
-- end (with the document, if the test made it).
--
-- sound_test() from the REPL; `only` = { fx = true } adds a send-as-insert
-- region (needs an effect in fx send a).

local T = {}

-- tape times (s) and what is there; the check script has the same table
T.REGIONS = {
  { 60, 64, { gain = -12 } },
  { 64, 68, { dry = 0 } },
  { 68, 72, { pan = -1 } },
  { 70, 71, { gain = 6 } },       -- inside the pan region: both apply
  { 72, 76, { tone = 1 } },
}

function T.run(Tape, Annot, RS, path, only)
  only = only or {}
  local st = Tape.st
  local Model, Store = Annot.Model, Annot.Store
  path = path or (_path.audio .. 'aurotate-spike/sine440.wav')
  local data = norns.state.data
  local ev = io.open(data .. 'sound_events.txt', 'w')
  local t0
  local function mark(s)
    ev:write(string.format('%.3f %.3f %s xruns %d\n', util.time() - t0, st.pos, s, _norns.audio_get_xrun_count()))
    ev:flush()
  end
  return clock.run(function()
    -- the system reverb and the input monitor would fill the silences
    local mix = { reverb = params:get('reverb'), monitor_level = params:get('monitor_level') }
    params:set('reverb', 1)
    params:set('monitor_level', -math.huge)
    params:set('aur_loop', 0)
    params:set('aur_shuttle', 0)
    params:set('aur_file', path)
    clock.sleep(3)
    local doc = Annot.doc()
    local doc_file = Annot.doc_path()
    local had_file = util.file_exists(doc_file)
    local made = {}
    for _, d in ipairs(T.REGIONS) do
      local r = Model.add_region(doc, d[1], d[2], os.time())
      r.label = 'sound test'
      for f, v in pairs(d[3]) do Model.set_snd(doc, r, f, v) end
      made[#made + 1] = r
    end
    if only.fx then
      local r = Model.add_region(doc, 80, 84, os.time())
      r.label = 'sound test insert'
      Model.set_snd(doc, r, 'dry', 0)
      Model.set_snd(doc, r, 'send_a', 1)
      made[#made + 1] = r
    end
    clock.sleep(0.3) -- RS.tick pushes the segments
    local sf = io.open(data .. 'sound_segments.txt', 'w')
    for _, s in ipairs(RS.segments()) do
      local c = s[3]
      sf:write(string.format('%g %g dry %g a %g b %g gain %g pan %g tone %g\n',
        s[1], s[2], c.dry, c.send_a, c.send_b, c.gain, c.pan, c.tone))
    end
    sf:close()
    print('sound: ' .. #RS.segments() .. ' segments, fx ' .. st.fx)
    Tape.jump(57)
    clock.sleep(1.5)
    local rec = _path.audio .. 'aurotate-spike/sound.wav'
    audio.tape_record_open(rec)
    clock.sleep(0.2)
    audio.tape_record_start()
    t0 = util.time()
    mark('rec')
    params:set('aur_shuttle', 1)
    mark('play')
    -- through every region once, then a bit past
    while st.pos < (only.fx and 85 or 77.5) do
      clock.sleep(0.25)
      mark('pos')
    end
    -- a loop across the 64 s boundary: the wrap goes from silent (dry 0) back
    -- to -12 dB
    mark('loop 62-66')
    params:set('aur_loop_in', 62)
    params:set('aur_loop_out', 66)
    params:set('aur_loop', 1)
    clock.sleep(9)
    params:set('aur_loop', 0)
    -- jumps between differently set places
    for _, to in ipairs({ 50, 61, 66, 69, 70.5, 50, 73 }) do
      mark('jump ' .. to)
      Tape.jump(to)
      clock.sleep(1.2)
      mark('pos')
    end
    -- fast forward across all of them
    Tape.jump(50)
    clock.sleep(0.8)
    mark('ff 8')
    params:set('aur_shuttle', 8)
    clock.sleep(4)
    mark('region sound off')
    params:set('aur_shuttle', 1)
    Tape.jump(61)
    clock.sleep(1)
    params:set('aur_snd', 0)
    clock.sleep(1.5)
    mark('region sound on')
    params:set('aur_snd', 1)
    clock.sleep(1.5)
    mark('end')
    params:set('aur_shuttle', 0)
    clock.sleep(0.8)
    audio.tape_record_stop()
    ev:close()
    for k, v in pairs(mix) do params:set(k, v) end
    for _, r in ipairs(made) do Model.remove(doc, r) end
    if not had_file then
      Store.flush()
      os.remove(doc_file)
      os.remove(doc_file .. '.bak')
    end
    print('sound: recorded ' .. rec)
    local flag = io.open(data .. 'sound_done', 'w')
    if flag then flag:close() end
  end)
end

return T

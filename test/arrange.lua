-- arranger test (phase 10): plays test3h.wav through an arrangement and
-- records the norns output with the system TAPE. test3h's right channel is
-- pink noise, so the check (tools/arrange_check.py) finds where each span
-- starts in the recording by correlating it with the file, and from that
-- whether each row ended exactly at its end (and nowhere else). The left
-- channel (a slow sine sweep) shows clicks.
--
--   dust/audio/aurotate-spike/arrange.wav    the recording
--   dust/data/aurotate/arrange_spans.txt     "<rec time> <a> <b> <rate> <row>
--                                            <kind> <secs>" per span, when Lua
--                                            saw it start (kind: span, stop, wait)
--   dust/audio/aurotate-spike/arrange_ref.wav  test3h 0-100 s (the reference)
--
-- The test items and the arrangement go into test3h's document and are
-- removed afterwards (the old arrangement comes back).

local T = {}

-- the items (tape times) and the rows; the comment is what plays
T.ITEMS = {
  A = { 20, 22 }, B = { 30, 31.5 }, M1 = { 40 }, M2 = { 42 }, C = { 44, 45 },
  D = { 60, 60.03 }, E = { 70, 71 },
}
T.ROWS = {
  { k = 'play', item = 'A', rep = 2, rate = 1 },    -- 000 20-22 twice
  { k = 'play', item = 'B', rep = 1, rate = -1 },   -- 001 31.5 -> 30
  { k = 'play', item = 'M1', rep = 1, rate = 2 },   -- 002 40-42 at 2x
  { k = 'play', item = 'M2', rep = 1, rate = 1 },   -- 003 42-44 (continues 002)
  { k = 'play', item = 'C', rep = 1, rate = 0.5 },  -- 004 44-45 at 0.5x (continues 003)
  { k = 'loop', to = 1, n = 2 },                    -- 005 rows 001-004 twice
  { k = 'jump', to = 8 },                           -- 006
  { k = 'play', item = 'A', rep = 1, rate = 1 },    -- 007 skipped by the jump
  { k = 'rem', text = 'arrange test' },             -- 008
  { k = 'play', item = 'D', rep = 1, rate = 1 },    -- 009 30 ms, lengthened to 50 ms
  { k = 'play', item = 'E', rep = 1, rate = -0.5 }, -- 010 71 -> 70 at -0.5x
  { k = 'play', item = 'A', rep = 1, rate = 1 },    -- 011 20-22
  { k = 'stop', secs = 0.5 },                       -- 012 brake from 22 over 0.5 s
  { k = 'wait', secs = 0.5 },                       -- 013 0.5 s of silence
  { k = 'play', item = 'B', rep = 1, rate = 1 },    -- 014 30-31.5
  { k = 'halt' },                                   -- 015
  { k = 'play', item = 'A', rep = 1, rate = 1 },    -- 016 not reached
}

function T.run(Tape, Annot, Run, path)
  local st = Tape.st
  local Model, Store = Annot.Model, Annot.Store
  path = path or (_path.audio .. 'aurotate-spike/test3h.wav')
  local data = norns.state.data
  local spike = _path.audio .. 'aurotate-spike/'
  return clock.run(function()
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
    local old_arr = doc.arr
    -- other items in 10-75 s would change the mark spans
    for _, list in ipairs({ doc.marks, doc.regions }) do
      for _, it in ipairs(list) do
        local t = it.t or it.t0
        if t > 10 and t < 75 then print('arrange: warning: ' .. it.id .. ' at ' .. t .. ' s') end
      end
    end
    local made, ids = {}, {}
    for name, d in pairs(T.ITEMS) do
      local it = d[2] and Model.add_region(doc, d[1], d[2] + (d[2] - d[1] < 0.05 and 0.05 or 0), os.time())
        or Model.add_mark(doc, d[1], os.time())
      -- D is shorter than a region may be: set its end by hand
      if d[2] and d[2] - d[1] < 0.05 then it.t1 = d[2] end
      it.label = 'arr ' .. name
      made[#made + 1] = it
      ids[name] = it.id
    end
    doc.arr = { rows = {} }
    for i, r in ipairs(T.ROWS) do
      local row = {}
      for k, v in pairs(r) do row[k] = v end
      if row.item then row.id, row.item = ids[row.item], nil end
      doc.arr.rows[i] = row
    end
    Model.changed(doc)
    clock.sleep(0.5)
    local rec = spike .. 'arrange.wav'
    audio.tape_record_open(rec)
    clock.sleep(0.2)
    audio.tape_record_start()
    local t0 = util.time()
    local sf = io.open(data .. 'arrange_spans.txt', 'w')
    clock.sleep(0.5)
    local xr = _norns.audio_get_xrun_count()
    Run.start(1)
    local last = nil
    local n = 0
    while Run.on do
      local p = Run.playing
      if p and p ~= last then
        last = p
        n = n + 1
        sf:write(string.format('%.4f %.4f %.4f %g %s %s %g\n', util.time() - t0, p.a or 0, p.b or 0, p.rate or 0,
          tostring(p.row), p.kind or 'span', p.secs or 0))
        sf:flush()
      end
      clock.sleep(0.005)
    end
    clock.sleep(1)
    audio.tape_record_stop()
    sf:close()
    print(string.format('arrange: %d spans, err %s, pos %.3f, xruns %d', n, tostring(Run.err), st.pos,
      _norns.audio_get_xrun_count() - xr))
    -- leaving: a seek in arrangement mode keeps the speed; K2 stops
    Run.start(1)
    clock.sleep(0.5)
    Tape.jump(5)
    clock.sleep(0.3)
    print(string.format('arrange: after a seek: on %s shuttle %g rate %.2f', tostring(Run.on),
      params:get('aur_shuttle'), st.rate))
    Tape.stop()
    clock.sleep(1)
    print(string.format('arrange: stopped: rate %.2f', st.rate))
    for k, v in pairs(mix) do params:set(k, v) end
    for _, it in ipairs(made) do Model.remove(doc, it) end
    doc.arr = old_arr
    Model.changed(doc)
    Store.flush()
    if not had_file then
      os.remove(doc_file)
      os.remove(doc_file .. '.bak')
    end
    os.execute('sox ' .. Store.q(path) .. ' ' .. Store.q(spike .. 'arrange_ref.wav') .. ' trim 0 100')
    print('arrange: recorded ' .. rec)
    local flag = io.open(data .. 'arrange_done', 'w')
    if flag then flag:close() end
  end)
end

return T

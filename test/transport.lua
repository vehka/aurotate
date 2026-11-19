-- automated transport run (phase 1 acceptance + CPU baseline)
--
-- from the REPL, with aurotate running:
--   transport_test()                       -- default file
--   transport_test('/home/we/dust/audio/x.flac')
--   transport_test(nil, {loops = true, edges = true})
--     sections: basic, speed, scrub, loops, edges, analysis, cue
--   transport_test(nil, {analysis = true, cue = true, proxy_mb = 300})
--     analysis: drops the cache, plays at 1x while the file is analysed
--     cue: waits for the proxies, then FF/REW up to 256x and far seeks
--     proxy_mb: proxy memory for the run (e.g. enough for P1 on a long file)
--
-- results:
--   dust/data/aurotate/transport_report.txt  engine side, one line per phase:
--     reads, MB/s, dropouts (misses), seek times, scsynth cpu avg/peak
--   dust/data/aurotate/transport_lua.txt     matron side, per phase:
--     xruns, jack cpu avg/max, position checks (PASS/FAIL)

local T = {}

local DEFAULT = _path.audio .. 'aurotate-spike/field_L.flac'

local function mem_avail_mb()
  for line in io.lines('/proc/meminfo') do
    local v = line:match('^MemAvailable:%s+(%d+)')
    if v then return tonumber(v) // 1024 end
  end
  return -1
end

function T.run(Tape, path, only)
  local st = Tape.st
  path = path or DEFAULT
  local out = io.open(norns.state.data .. 'transport_lua.txt', 'a')
  local fails = 0

  local cur = nil       -- current phase
  local sampler = nil

  local function log(s)
    print(s)
    out:write(s .. '\n')
    out:flush()
  end

  local function close_phase()
    if not cur then return end
    local x = _norns.audio_get_xrun_count() -- resets on read
    local line = string.format('%s xruns=%d jack_cpu_avg=%.1f jack_cpu_max=%.1f pos_min=%.2f pos_max=%.2f'
      .. ' mem_avail_mb=%d proxies=%d',
      cur.name, x, cur.cpu_sum / math.max(1, cur.cpu_n), cur.cpu_max, cur.pmin, cur.pmax,
      mem_avail_mb(), st.proxies)
    if cur.check then
      local ok, why = cur.check(cur)
      line = line .. (ok and ' PASS' or (' FAIL ' .. (why or '')))
      if not ok then fails = fails + 1 end
    end
    if x > 0 then
      line = line .. ' XRUN'
    end
    log(line)
  end

  -- close the previous phase (engine + lua), start `name`
  local function phase(name, check)
    close_phase()
    engine.phase(name)
    _norns.audio_get_xrun_count()
    cur = { name = name, check = check, cpu_sum = 0, cpu_n = 0, cpu_max = 0,
      pmin = math.huge, pmax = -math.huge }
  end

  -- close the current phase before setting up the next one, so the setup
  -- (jumps, loop changes) doesn't count towards either
  local function rest()
    close_phase()
    cur = nil
    engine.phase('setup')
  end

  local function set_speed(r) params:set('aur_shuttle', r) end
  local function rnd() return 60 + math.random() * (st.dur - 120) end
  local function within(a, b, slack)
    slack = slack or 0.1
    return function(c)
      if c.pmin < a - slack or c.pmax > b + slack then
        return false, string.format('outside %.2f-%.2f', a, b)
      end
      return true
    end
  end

  sampler = clock.run(function()
    while true do
      if cur then
        local c = _norns.audio_get_cpu_load()
        cur.cpu_sum = cur.cpu_sum + c
        cur.cpu_n = cur.cpu_n + 1
        cur.cpu_max = math.max(cur.cpu_max, c)
        cur.pmin = math.min(cur.pmin, st.pos)
        cur.pmax = math.max(cur.pmax, st.pos)
      end
      clock.sleep(0.1)
    end
  end)

  return clock.run(function()
    log('--- ' .. os.date() .. ' ' .. path .. ' ring ' .. params:get('aur_ring') .. ' s')
    params:set('aur_loop', 0)
    params:set('aur_file', path)
    clock.sleep(3)
    log(string.format('duration %.1f s', st.dur))
    local function want(sec)
      if only == nil then return sec ~= 'analysis' and sec ~= 'cue' end
      return only[sec]
    end
    if only and only.proxy_mb then params:set('aur_proxy_mb', only.proxy_mb) end

    if want('analysis') then
    -- fresh analysis while the tape plays (does it cause xruns or misses?)
    rest()
    local A = include('lib/analysis')
    engine.proxy(1, st.path, '')
    engine.proxy(2, st.path, '')
    os.execute('rm -rf ' .. A.cache_dir(path))
    Tape.open(path, rnd())
    clock.sleep(2)
    phase('analysing_play1x')
    local t0 = util.time()
    set_speed(1)
    while Tape.analysis.state == 'running' and util.time() - t0 < 600 do clock.sleep(1) end
    log(string.format('analysis %s after %.1f s (%s)', Tape.analysis.state, util.time() - t0,
      tostring(Tape.analysis.info and Tape.analysis.info.secs)))
    phase('proxies_loading')
    t0 = util.time()
    while st.proxies < 2 and util.time() - t0 < 30 do clock.sleep(0.2) end
    clock.sleep(3)
    end

    if want('cue') then
    rest()
    local t0 = util.time()
    while (Tape.analysis.state == 'running' or st.proxies < 2) and util.time() - t0 < 600 do clock.sleep(1) end
    clock.sleep(5) -- P1 may still be loading
    log(string.format('proxies %d (budget %d MB)', st.proxies, params:get('aur_proxy_mb')))
    for _, r in ipairs { 8, 16, 32, 64, 128, 256, -64, -256 } do
      rest()
      Tape.jump(r > 0 and 60 or st.dur - 60)
      set_speed(1)
      clock.sleep(1.5)
      phase((r > 0 and 'ff' or 'rew') .. math.abs(r) .. '_cue')
      set_speed(r)
      clock.sleep(12)
    end
    rest()
    Tape.jump(rnd())
    set_speed(1)
    clock.sleep(2)
    phase('seek_far_focus')
    for _ = 1, 15 do
      Tape.jump(rnd())
      clock.sleep(3)
    end
    phase('play1x_proxies')
    clock.sleep(20)
    end

    if want('basic') then
    phase('idle_loaded')
    clock.sleep(10)

    phase('play1x')
    set_speed(1)
    clock.sleep(60)

    phase('seek_near')
    for _ = 1, 10 do
      Tape.jump(math.max(0, st.pos + (math.random() * 40 - 20)))
      clock.sleep(2)
    end

    phase('seek_far')
    for _ = 1, 15 do
      Tape.jump(rnd())
      clock.sleep(3)
    end
    end

    if want('speed') then
    for _, r in ipairs { 2, 4, 8, 16, 32, 64 } do
      rest()
      Tape.jump(rnd())
      set_speed(1)
      clock.sleep(1.5)
      phase('ff' .. r)
      set_speed(r)
      clock.sleep(15)
    end
    set_speed(1)

    for _, r in ipairs { -1, -4 } do
      rest()
      Tape.jump(rnd())
      clock.sleep(1.5)
      phase('rew' .. -r)
      set_speed(r)
      clock.sleep(15)
    end
    end

    if want('scrub') then
    -- scrub: bursts of encoder ticks, as a hand would turn E2
    rest()
    Tape.jump(rnd())
    set_speed(0)
    clock.sleep(1.5)
    phase('scrub')
    for _ = 1, 40 do
      local dir = math.random() < 0.5 and -1 or 1
      local ticks = math.random(1, 25)
      local gap = 0.005 + math.random() * 0.06
      for _ = 1, ticks do
        Tape.jog_turn(dir)
        clock.sleep(gap)
      end
      clock.sleep(math.random() * 0.8)
    end
    clock.sleep(1)
    phase('scrub_to_play', function() return not st.jogging and math.abs(st.rate - 1) < 0.05, 'not playing' end)
    Tape.play()
    clock.sleep(3)
    end

    if want('loops') then
    -- loops: (name, in offset, length, speed, seconds)
    local loops = {
      { 'loop10s_1x', 10, 1, 35 },
      { 'loop0.5s_1x', 0.5, 1, 10 },
      { 'loop20s_8x', 20, 8, 15 },
      { 'loop10s_rev', 10, -1, 25 },
      { 'loop200s_16x', 200, 16, 40 }, -- longer than the ring: streams through the wrap
    }
    for _, l in ipairs(loops) do
      local name, len, r, secs = l[1], l[2], l[3], l[4]
      local a = rnd()
      rest()
      set_speed(0)
      params:set('aur_loop', 0)
      params:set('aur_loop_in', a)
      params:set('aur_loop_out', a + len)
      Tape.jump(a + len / 2)
      clock.sleep(1.5)
      phase(name, within(a, a + len, 0.15 * math.abs(r)))
      params:set('aur_loop', 1)
      set_speed(r)
      clock.sleep(secs)
    end
    params:set('aur_loop', 0)

    -- seeking past the loop escapes it
    rest()
    local a = rnd()
    params:set('aur_loop_in', a)
    params:set('aur_loop_out', a + 5)
    params:set('aur_loop', 1)
    set_speed(1)
    clock.sleep(2)
    phase('loop_escape', function(c) return c.pmax > a + 20, 'stayed in loop' end)
    Tape.jump(a + 30)
    clock.sleep(4)
    params:set('aur_loop', 0)
    end

    if want('edges') then
    -- the ends park the tape
    rest()
    Tape.jump(st.dur - 3)
    set_speed(1)
    clock.sleep(1)
    phase('end_park', function()
      return params:get('aur_shuttle') == 0 and st.pos >= st.dur - 0.1, string.format('pos %.2f', st.pos)
    end)
    clock.sleep(5)

    rest()
    Tape.jump(3)
    set_speed(-2)
    clock.sleep(0.5)
    phase('start_park', function()
      return params:get('aur_shuttle') == 0 and st.pos <= 0.05, string.format('pos %.2f', st.pos)
    end)
    clock.sleep(4)
    end

    if want('basic') then
    rest()
    Tape.jump(rnd())
    set_speed(1)
    clock.sleep(1.5)
    phase('play1x_b')
    clock.sleep(30)

    phase('stopped')
    set_speed(0)
    clock.sleep(10)
    end

    phase('end')
    cur = nil
    clock.cancel(sampler)
    log(string.format('done: %d check failures; engine report in transport_report.txt', fails))
    out:close()
    local flag = io.open(norns.state.data .. 'transport_done', 'w')
    if flag then flag:close() end
  end)
end

-- click check: records the norns output with the system TAPE while seeking,
-- looping, spinning up/down and scrubbing a pure sine (test3h.wav, left).
-- event times relative to the start of the recording go to clicks_events.txt
function T.clicks(Tape, path)
  local st = Tape.st
  path = path or (_path.audio .. 'aurotate-spike/test3h.wav')
  local ev = io.open(norns.state.data .. 'clicks_events.txt', 'w')
  local t0
  local function mark(s)
    ev:write(string.format('%.3f %s\n', util.time() - t0, s))
    ev:flush()
  end
  local function speed(r) params:set('aur_shuttle', r) end
  local function loop(a, b, on)
    params:set('aur_loop_in', a)
    params:set('aur_loop_out', b)
    params:set('aur_loop', on and 1 or 0)
  end
  return clock.run(function()
    params:set('aur_loop', 0)
    params:set('aur_file', path)
    clock.sleep(3)
    Tape.jump(600)
    clock.sleep(1)
    local rec = _path.audio .. 'aurotate-spike/clicks.wav'
    audio.tape_record_open(rec)
    clock.sleep(0.2)
    audio.tape_record_start()
    t0 = util.time()
    mark('play')
    speed(1)
    clock.sleep(3)
    for i = 1, 8 do
      mark('seek')
      Tape.jump(600 + i * 37.3)
      clock.sleep(1)
    end
    mark('loop 0.5s 1x')
    loop(st.pos + 0.2, st.pos + 0.7, true)
    clock.sleep(4)
    mark('loop 2s rev')
    loop(st.pos - 1, st.pos + 1, true)
    speed(-1)
    clock.sleep(5)
    mark('loop 1s 4x')
    loop(st.pos - 0.5, st.pos + 0.5, true)
    speed(4)
    clock.sleep(3)
    loop(0, 0, false)
    speed(1)
    clock.sleep(1)
    mark('stop')
    speed(0)
    clock.sleep(1.5)
    mark('play')
    speed(1)
    clock.sleep(1.5)
    mark('scrub')
    for _ = 1, 6 do
      for _ = 1, math.random(3, 15) do
        Tape.jog_turn(math.random() < 0.5 and -1 or 1)
        clock.sleep(0.02)
      end
      clock.sleep(0.4)
    end
    clock.sleep(1)
    mark('end')
    speed(0)
    clock.sleep(1)
    audio.tape_record_stop()
    ev:close()
    print('clicks: recorded ' .. rec)
  end)
end

return T

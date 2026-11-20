-- tape: engine glue, transport and params for the tape voice

local cs = require 'controlspec'
local Analysis = include 'lib/analysis'
local Peaks = include 'lib/peaks'

local Tape = {}

-- read-only for the UI; written by polls and the transport
Tape.st = {
  pos = 0, rate = 0, ok = 1, misses = 0, dur = 0, path = nil,
  jogging = false, pending_in = nil,
  proxies = 0,     -- engine: bit 1 P1 loaded, bit 2 P2
  proxy_share = 0, -- engine: 0..1 of the sound from the proxies
  peaks = nil,     -- lib/peaks object once analysed
}
Tape.analysis = Analysis.st
local st = Tape.st

Tape.dirty = true

local polls = {}

-- shuttle positions for E3; 0 and 1 are detents
-- beyond ±64 only with the P2 proxy loaded (Tape.max_speed)
Tape.SHUTTLE = { -256, -128, -64, -32, -16, -8, -4, -2, -1.5, -1, -0.5, -0.25, 0,
  0.25, 0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 2, 4, 8, 16, 32, 64, 128, 256 }
local DETENT_TICKS = 3
local DETENT_RESET = 0.4
local detent = { acc = 0, last = 0 }

-- jog (scrub with inertia), ported from norns MultiTape (audio.multitape.jog_turn)
local JOG_SPEED_TIME = 0.1 -- seconds over which the turning speed is averaged
local JOG_MAX_BOOST = 200
local jog = { last = 0, speed = 0 }

local function mem_total_mb()
  local f = io.open('/proc/meminfo')
  if not f then return 0 end
  local s = f:read('*l') or ''
  f:close()
  return (tonumber(s:match('(%d+)')) or 0) / 1024
end

function Tape.hms(s, frac)
  s = math.max(0, s or 0)
  local whole = math.floor(s)
  local str = string.format('%d:%02d:%02d', whole // 3600, (whole % 3600) // 60, whole % 60)
  if frac then str = str .. string.format('.%d', math.floor((s - whole) * 10)) end
  return str
end

---- transport

function Tape.max_speed()
  return (st.proxies & 2) ~= 0 and 256 or 64
end

-- a proxy stands in for the full resolution near normal speed: the tape is
-- coming into focus after a far seek
function Tape.focusing()
  return st.path ~= nil and st.proxy_share > 0.05 and math.abs(st.rate) < 6
end

function Tape.playing()
  return params:get('aur_shuttle') ~= 0 and not st.jogging
end

-- leaves jog mode (the engine glides from the jog speed)
local function shuttle_action(r)
  local m = Tape.max_speed()
  if math.abs(r) > m then
    params:set('aur_shuttle', util.clamp(r, -m, m))
    return
  end
  st.jogging = false
  engine.rate(r, params:get('aur_glide'))
  Tape.dirty = true
end

function Tape.play() params:set('aur_shuttle', 1) end
function Tape.stop() params:set('aur_shuttle', 0) end
function Tape.toggle()
  if Tape.playing() then Tape.stop() else Tape.play() end
end

-- play / stop for transcription: resuming backs up `secs` first
function Tape.toggle_rewind(secs)
  if Tape.playing() then
    Tape.stop()
  else
    if secs and secs > 0 then Tape.jump(st.pos - secs) end
    Tape.play()
  end
end

local function nearest_step(r)
  local best, bi = math.huge, 1
  for i, v in ipairs(Tape.SHUTTLE) do
    local d = math.abs(v - r)
    if d < best then best, bi = d, i end
  end
  return bi
end

-- E3: step through the shuttle positions; leaving 0 or 1 takes a few ticks
function Tape.shuttle_turn(d)
  local cur = st.jogging and 0 or params:get('aur_shuttle')
  local t = util.time()
  if cur == 0 or cur == 1 then
    if t - detent.last > DETENT_RESET or (detent.acc > 0) ~= (d > 0) then detent.acc = 0 end
    detent.last = t
    detent.acc = detent.acc + d
    if math.abs(detent.acc) < DETENT_TICKS then return end
    d = detent.acc > 0 and 1 or -1
  end
  detent.acc = 0
  local i = util.clamp(nearest_step(cur) + d, 1, #Tape.SHUTTLE)
  if math.abs(Tape.SHUTTLE[i]) > Tape.max_speed() then return end
  params:set('aur_shuttle', Tape.SHUTTLE[i])
end

-- E2: one slow tick moves the tape by `nudge` ms; fast turning pushes harder
function Tape.jog_turn(d)
  local t = util.time()
  if not st.jogging then
    st.jogging = true
    jog.last = t - 1
    jog.speed = 0
    params:set('aur_shuttle', 0, true) -- silent: the engine keeps its speed and coasts
  end
  local dt = math.max(0, t - jog.last)
  jog.last = t
  -- turning speed in ticks per second, averaged so close ticks don't spike;
  -- a lone tick reads as 1 / JOG_SPEED_TIME, which counts as no extra speed
  jog.speed = jog.speed * math.exp(-dt / JOG_SPEED_TIME) + math.abs(d) / JOG_SPEED_TIME
  local excess = math.max(0, jog.speed - 1 / JOG_SPEED_TIME)
  local push = (params:get('aur_jog_nudge') / 1000) / params:get('aur_jog_stop')
  local boost = math.min(JOG_MAX_BOOST, 1 + params:get('aur_jog_accel') * (excess / 20) ^ 2)
  engine.jog_nudge(d * push * boost)
  Tape.dirty = true
end

function Tape.jump(sec)
  sec = util.clamp(sec, 0, math.max(0, st.dur))
  -- the engine takes the new position at once; set it here too, so a second
  -- seek before the next poll starts from it (not from the old position)
  st.pos = sec
  engine.jump(sec)
end

---- loop

local function send_loop()
  local a, b = params:get('aur_loop_in'), params:get('aur_loop_out')
  if a > b then a, b = b, a end
  engine.loop(params:get('aur_loop') == 1 and 1 or 0, a, b)
end

-- loop between a and b (a region, K1+K2)
function Tape.loop(a, b)
  params:set('aur_loop_in', a)
  params:set('aur_loop_out', b)
  params:set('aur_loop', 1)
end

---- analysis and proxies

-- proxy sizes in RAM (float32 mono) for the analysed tape
local function proxy_bytes(info, level)
  local r = info['p' .. level .. '_rate']
  return info.frames * r / info.rate * 4
end

-- send the proxies that fit the memory budget: P2 first (small), then P1
function Tape.send_proxies()
  local a = Analysis.st
  if not st.path or a.state ~= 'done' or not a.info or not a.info.frames then return end
  local budget = params:get('aur_proxy_mb') * 1e6
  local b2 = proxy_bytes(a.info, 2)
  local b1 = proxy_bytes(a.info, 1)
  local use2 = b2 <= budget
  local use1 = (use2 and b1 + b2 or b1) <= budget
  engine.proxy(2, st.path, use2 and a.dir .. 'p2.wav' or '')
  engine.proxy(1, st.path, use1 and a.dir .. 'p1.wav' or '')
end

-- while the pass runs, the waveform grows: reload the partial peaks file
-- (level 0 only) every few seconds
local PEAKS_RELOAD = 3
local peaks_loaded = 0
local function analysing(dir)
  local t = util.time()
  if t - peaks_loaded < PEAKS_RELOAD then return end
  peaks_loaded = t
  local p = Peaks.load(dir .. 'peaks.tmp')
  if p then
    st.peaks = p
    Tape.dirty = true
  end
end

local function analysed(dir)
  st.peaks = Peaks.load(dir .. 'peaks')
  Tape.send_proxies()
  Tape.dirty = true
end

---- files

-- Tape.on_open(path, dur) is called before the switch (st still holds the
-- old tape) and returns the start position when `start` is nil
Tape.on_open = nil
Tape.hold_open = false -- true: the aur_file action doesn't open (startup)

function Tape.open(path, start)
  if path == nil or path == '' or path:sub(-1) == '/' or not util.file_exists(path) then return false end
  local ch, samples, rate = audio.file_info(path)
  if not samples or samples <= 0 or not rate or rate <= 0 then
    print('aurotate: not a sound file: ' .. path)
    return false
  end
  local from_doc = Tape.on_open and Tape.on_open(path, samples / rate)
  start = start or from_doc or 0
  st.path = path
  st.name = path:match('[^/]*$'):gsub('%.%w+$', '')
  st.dur = samples / rate
  st.ch = ch
  st.pos = start
  st.pending_in = nil
  st.jogging = false
  st.peaks = nil
  st.proxies = 0
  params:set('aur_shuttle', 0, true)
  engine.open(path, start, params:get('aur_ring'))
  send_loop()
  peaks_loaded = 0
  Analysis.start(path, samples, analysed, analysing)
  Tape.dirty = true
  return true
end

---- params

local function time_spec()
  -- 0.1 s per encoder tick over a 24 h range
  return cs.new(0, 24 * 3600, 'lin', 0, 0, 's', 0.1 / (24 * 3600))
end

local function fmt_time(p) return Tape.hms(p:get(), true) end

function Tape.add_params()
  local pi3 = mem_total_mb() < 1500
  params:add_group('aur_tape', 'TAPE', 23)

  params:add_file('aur_file', 'tape', _path.audio)
  params:set_action('aur_file', function(path)
    if Tape.hold_open then return end -- startup decides (see init)
    if path ~= st.path then Tape.open(path) end
  end)

  params:add_trigger('aur_play', 'play / stop')
  params:set_action('aur_play', function() Tape.toggle() end)

  params:add_control('aur_shuttle', 'speed', cs.new(-256, 256, 'lin', 0, 0, 'x', 0.25 / 512))
  params:set_action('aur_shuttle', shuttle_action)
  params:set_save('aur_shuttle', false)

  params:add_control('aur_level', 'level', cs.new(-60, 6, 'lin', 0, 0, 'dB'))
  params:set_action('aur_level', function(db) engine.amp(db <= -60 and 0 or util.dbamp(db)) end)

  params:add_control('aur_glide', 'spin up / down', cs.new(0.02, 3, 'exp', 0, 0.4, 's'))

  params:add_separator('aur_sep_cue', 'cue + focus')
  params:add_control('aur_lifter', 'lifter (at speed)', cs.new(0, 100, 'lin', 1, 50, '%'))
  params:set_action('aur_lifter', function(x) engine.lifter(x / 100) end)
  params:add_control('aur_focus', 'focus time', cs.new(4, 1000, 'exp', 1, 150, 'ms'))
  params:set_action('aur_focus', function(ms) engine.focus(ms / 1000) end)

  params:add_separator('aur_sep_jog', 'scrub (E2)')
  params:add_control('aur_jog_nudge', 'scrub nudge', cs.new(0.5, 200, 'exp', 0, 10, 'ms'))
  params:add_control('aur_jog_accel', 'scrub acceleration', cs.new(0, 10, 'lin', 0, 3, ''))
  params:add_control('aur_jog_stop', 'scrub stop time', cs.new(0.05, 3, 'exp', 0, 0.5, 's'))
  params:set_action('aur_jog_stop', function(x) engine.jog_stop(x) end)

  params:add_separator('aur_sep_loop', 'loop (K1+K2)')
  params:add_binary('aur_loop', 'loop', 'toggle', 0)
  params:set_action('aur_loop', function(v)
    if v == 1 then
      local a, b = params:get('aur_loop_in'), params:get('aur_loop_out')
      if a > b then a, b = b, a end
      -- a loop is entered by crossing its edge; start inside it
      if st.pos < a or st.pos >= b then Tape.jump(a) end
    end
    send_loop()
    Tape.dirty = true
  end)
  params:add_control('aur_loop_in', 'loop in', time_spec(), fmt_time)
  params:set_action('aur_loop_in', send_loop)
  params:add_control('aur_loop_out', 'loop out', time_spec(), fmt_time)
  params:set_action('aur_loop_out', send_loop)

  params:add_separator('aur_sep_notes', 'transcription')
  params:add_control('aur_rewind', 'resume rewind (Esc)', cs.new(0, 10, 'lin', 0.5, 2, 's'))
  params:add_trigger('aur_export', 'export notes (md)')
  params:set_action('aur_export', function() if Tape.on_export then Tape.on_export() end end)

  params:add_separator('aur_sep_mem', 'memory')
  params:add_number('aur_ring', 'ring window', 16, 600, pi3 and 64 or 120, function(p) return p:get() .. ' s' end)
  params:set_action('aur_ring', function(s) if st.path then engine.ring(s) end end)
  params:add_control('aur_fade', 'seek / seam fade', cs.new(1, 50, 'exp', 0, 8, 'ms'))
  params:set_action('aur_fade', function(ms) engine.fade(ms / 1000) end)
  -- proxies held in RAM: P2 (3 h mono ≈ 32 MB) first, then P1 (1 h ≈ 86 MB)
  params:add_number('aur_proxy_mb', 'proxy memory', 0, 2048, pi3 and 128 or 600, function(p) return p:get() .. ' MB' end)
  params:set_action('aur_proxy_mb', function() Tape.send_proxies() end)
end

---- polls

function Tape.start_polls()
  local handlers = {
    aur_pos = function(v)
      st.pos = v
      -- the engine parks at the ends; reflect that in the speed param
      if not st.jogging then
        local r = params:get('aur_shuttle')
        if (r > 0 and v >= st.dur - 0.01) or (r < 0 and v <= 0) then
          params:set('aur_shuttle', 0, true)
        end
      end
    end,
    aur_rate = function(v) st.rate = v end,
    aur_ok = function(v) st.ok = v end,
    aur_misses = function(v) st.misses = v end,
    aur_proxies = function(v) st.proxies = math.floor(v + 0.5) end,
    aur_proxy_share = function(v) st.proxy_share = v end,
  }
  for name, fn in pairs(handlers) do
    local p = poll.set(name)
    local last = nil
    p.time = 1 / 20
    -- redraw only on a change, so a stopped tape doesn't keep the screen busy
    p.callback = function(v)
      fn(v)
      if v ~= last then
        last = v
        Tape.dirty = true
      end
    end
    p:start()
    polls[#polls + 1] = p
  end
end

function Tape.cleanup()
  for _, p in ipairs(polls) do p:stop() end
  polls = {}
  Analysis.stop()
end

return Tape

-- aurotate
-- an audio-anthropology workbench:
-- hours-long recordings on tape
--
-- phase 3: tape view
--
-- E1 zoom
-- K1+E1 page
-- E2 scrub (inertia)
-- K1+E2 move along the whole tape
-- E3 speed (shuttle ±64, ±256
--    once analysed)
-- K2 play / stop
-- K3 loop in, out, off
-- K1+K3 cancel loop in
--
-- tape: K3 or PARAMS > TAPE

engine.name = 'Aurotate'

local fileselect = require 'fileselect'
local Tape = include 'lib/tape'
local Draw = include 'lib/ui/draw'
local View = include 'lib/ui/tape_view'

local st = Tape.st
local shift = false
-- E2 ticks just around a K1+E2 seek are taken as part of it, so a stray tick
-- doesn't drop into scrub (which takes over from play and coasts to a stop)
local SEEK_GRACE = 0.4
local last_seek = -1
local selecting = false -- the file browser is open

local FPS = 15
local redraw_metro
local stats = { n = 0, sum = 0, max = 0 } -- redraw time, for dbg_status()

---- pages (K1+E1); only the tape view exists so far

local PAGES = { 'collection', 'tape', 'regions', 'settings' }
local page = 2

local function placeholder(title, phase)
  screen.clear()
  Draw.header(page, #PAGES, title:upper(), nil, nil, nil)
  screen.level(4)
  screen.move(64, 36)
  screen.text_center(phase and ('(phase ' .. phase .. ')') or '(not yet)')
  screen.update()
end

local function choose_tape()
  selecting = true
  fileselect.enter(_path.audio, function(path)
    selecting = false
    if path and path ~= 'cancel' then params:set('aur_file', path) end
    Tape.dirty = true
  end)
end

function init()
  Tape.add_params()
  params:default()
  Tape.start_polls()
  redraw_metro = metro.init(function()
    if selecting then return end
    if View.tick() then Tape.dirty = true end
    if Tape.dirty then
      Tape.dirty = false
      redraw()
    end
  end, 1 / FPS)
  redraw_metro:start()
end

function key(n, z)
  if n == 1 then
    shift = z == 1
    if z == 0 and util.time() - last_seek < SEEK_GRACE then last_seek = util.time() end
    return
  end
  if z == 0 or PAGES[page] ~= 'tape' then return end
  if n == 2 then
    Tape.toggle()
  elseif n == 3 then
    if not st.path then
      choose_tape()
    elseif shift then
      Tape.loop_cancel()
    else
      Tape.loop_key()
    end
  end
end

function enc(n, d)
  if n == 1 and shift then
    page = util.clamp(page + d, 1, #PAGES)
    Tape.dirty = true
    return
  end
  if PAGES[page] ~= 'tape' then return end
  if n == 1 then
    View.zoom_turn(st, d)
    Tape.dirty = true
  elseif n == 2 then
    if shift then
      -- like a scrollbar: one pixel of the whole-tape strip per tick
      last_seek = util.time()
      Tape.jump(st.pos + d * math.max(1, st.dur / Draw.W))
    elseif util.time() - last_seek > SEEK_GRACE then
      Tape.jog_turn(d)
    end
  elseif n == 3 then
    Tape.shuttle_turn(d)
  end
end

function redraw()
  local t = util.time()
  if PAGES[page] == 'tape' then
    View.redraw(Tape, page, #PAGES)
  elseif PAGES[page] == 'collection' then
    placeholder('collection', 8)
  elseif PAGES[page] == 'regions' then
    placeholder('regions', 5)
  else
    placeholder('settings')
  end
  t = util.time() - t
  stats.n, stats.sum, stats.max = stats.n + 1, stats.sum + t, math.max(stats.max, t)
end

-- for the REPL (script locals aren't visible there)
function dbg_status()
  local an = Tape.analysis
  print(string.format('REDRAW n %d avg %.2f ms max %.2f ms HEAP %.0f KB ZOOM %d',
    stats.n, stats.sum / math.max(1, stats.n) * 1000, stats.max * 1000, collectgarbage('count'), View.zoom))
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

-- REPL handles: dbg.Tape, dbg.View; dbg_shot(name) redraws and saves the
-- screen to dust/data/aurotate/<name>.png
dbg = { Tape = Tape, View = View }
function dbg_shot(name)
  redraw()
  screen.export_screenshot(name or 'screen')
end

-- clear the redraw stats (dbg_status shows them)
function dbg_reset()
  stats.n, stats.sum, stats.max = 0, 0, 0
end

function cleanup()
  if redraw_metro then redraw_metro:stop() end
  Tape.cleanup()
end

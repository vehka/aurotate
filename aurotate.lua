-- aurotate
-- an audio-anthropology workbench:
-- hours-long recordings on tape
--
-- phase 6: per-region sound
--
-- E1 zoom
-- K1+E1 page
-- E2 scrub (inertia)
-- K1+E2 move along the whole tape
-- E3 speed (shuttle ±64, ±256
--    once analysed)
-- K2 play / stop
-- K3 tap: mark
-- K3 hold: region in; K3: out
-- K1+K3 note popup (or cancel in)
-- K1+K2 loop the region (or off)
-- USB keyboard: type a note
--
-- region sound: K1+K3 popup rows
-- (dry, sends, gain, pan, tone),
-- or PARAMS > SOUND > region here
--
-- regions page (K1+E1):
-- E2 select, E3 tag filter
-- K3 jump there, K1+K3 read
-- K1+K2 loop the region
--
-- tape: K3 or PARAMS > TAPE

engine.name = 'Aurotate'

local fileselect = require 'fileselect'
local Tape = include 'lib/tape'
local Draw = include 'lib/ui/draw'
local View = include 'lib/ui/tape_view'
local Annot = include 'lib/annot'
local Popup = include 'lib/ui/popup'
local Keys = include 'lib/keys'
local Regions = include 'lib/ui/regions'
local RS = include 'lib/region_sound'

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

---- pages (K1+E1); tape and regions exist so far

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
  Annot.init(Tape, View)
  Popup.init(Tape, Annot)
  Regions.init(Tape, Annot, View)
  RS.init(Tape, Annot)
  Popup.sound(RS)
  Keys.init(Tape, Annot, Popup, Regions, function() return not selecting and PAGES[page] or nil end)
  Tape.on_open = function(path, dur)
    Popup.reset()
    return Annot.switch(path, dur)
  end
  Tape.on_export = function() Annot.export() end
  Tape.add_params()
  RS.add_params()
  -- the PSET holds only the tape's path (aur_file); its notes live in the
  -- tape document, saved on their own. Writing a PSET is a good moment to
  -- make sure they are on disk.
  params.action_write = function() Annot.flush() end
  -- startup resumes the tape open last (where it was left), whatever tape
  -- the startup PSET names; loading a PSET later switches tapes
  Tape.hold_open = true
  params:default()
  Tape.hold_open = false
  local last = Annot.last_tape()
  if last and util.file_exists(last) then params:set('aur_file', last, true) end
  Tape.open(params:get('aur_file'))
  Tape.start_polls()
  RS.push(true)
  redraw_metro = metro.init(function()
    Annot.tick()
    RS.tick()
    if selecting or Popup.modal then return end
    if View.tick() then Tape.dirty = true end
    if Popup.tick() then Tape.dirty = true end
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
  if PAGES[page] ~= 'tape' and PAGES[page] ~= 'regions' then return end
  if Popup.active() then
    Popup.key(n, z, shift)
    return
  end
  if PAGES[page] == 'regions' then
    if z == 1 and n == 2 then
      if shift then Regions.loop() else Tape.toggle() end
    elseif z == 1 and n == 3 then
      if shift then Popup.open_reader(Regions.selected()) else Regions.jump() end
    end
    Tape.dirty = true
    return
  end
  if n == 3 then
    if not st.path then
      if z == 1 then choose_tape() end
    elseif shift then
      if z == 1 and not Annot.cancel() then
        local item = Annot.here()
        if item then Popup.open_item(item) else View.message('NOTHING HERE', 1) end
      end
    else
      Annot.k3(z)
    end
  elseif n == 2 and z == 1 then
    if shift then Annot.loop_here() else Tape.toggle() end
  end
  Tape.dirty = true
end

function enc(n, d)
  if n == 1 and shift then
    local was = page
    page = util.clamp(page + d, 1, #PAGES)
    if page ~= was then
      Popup.reset() -- a popup belongs to the page it was opened on
      if PAGES[page] == 'regions' then Regions.enter() end
    end
    Tape.dirty = true
    return
  end
  if PAGES[page] == 'regions' then
    if Popup.active() then
      if n ~= 1 then Popup.enc(n, d, shift) end
    elseif n == 2 then
      Regions.move(d)
    elseif n == 3 then
      Regions.filter_turn(d)
    end
    return
  end
  if PAGES[page] ~= 'tape' then return end
  if Popup.active() and n ~= 1 then
    Popup.enc(n, d, shift)
    return
  end
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
    View.redraw(Tape, page, #PAGES, Annot.doc(), Annot.here())
    Popup.redraw()
    screen.update()
  elseif PAGES[page] == 'collection' then
    placeholder('collection', 8)
  elseif PAGES[page] == 'regions' then
    Regions.redraw(page, #PAGES)
    Popup.redraw()
    screen.update()
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
  local doc, here = Annot.doc(), Annot.here()
  print(string.format('NOTES %s marks %d regions %d HERE %s PENDING %s POPUP %s',
    doc and Annot.doc_path() or '-', doc and #doc.marks or 0, doc and #doc.regions or 0,
    here and here.id or '-', tostring(st.pending_in), tostring(Popup.kind())))
  local cur = RS.current()
  print(string.format('SOUND on %d segments %d FX %d HERE %s',
    params:get('aur_snd'), #RS.segments(), st.fx, cur and cur.id or '-'))
end

-- automated transport run; see test/transport.lua
function transport_test(path, only)
  return include('test/transport').run(Tape, path, only)
end

-- model + store tests in a scratch dir (also runs off the device:
-- lua5.3 test/model_test.lua)
function notes_test()
  return include('test/model_test').run(norns.state.data .. 'model_test/')
end

-- write dust/data/aurotate/exports/<tape>/notes.md (also PARAMS > TAPE)
function export_notes()
  return Annot.export()
end

-- region sound: records a sine through test regions (test/sound.lua);
-- check with tools/sound_check.py
function sound_test(path, only)
  return include('test/sound').run(Tape, Annot, RS, path, only)
end

function clicks_test(path)
  return include('test/transport').clicks(Tape, path)
end

-- REPL handles: dbg.Tape, dbg.View; dbg_shot(name) redraws and saves the
-- screen to dust/data/aurotate/<name>.png
dbg = { Tape = Tape, View = View, Annot = Annot, Popup = Popup, Keys = Keys, Regions = Regions, RS = RS }
-- REPL: dbg_page('regions') shows a page
function dbg_page(name)
  for i, p in ipairs(PAGES) do
    if p == name then page = i end
  end
  if PAGES[page] == 'regions' then Regions.enter() end
  Tape.dirty = true
end
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
  Annot.cleanup()
  Tape.cleanup()
end

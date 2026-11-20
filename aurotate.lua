-- aurotate
-- an audio-anthropology workbench:
-- hours-long recordings on tape
--
-- phase 10: the arranger
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
-- collection page (K1+E1 left):
-- E2 select, E3 sort, K3 open
-- K1+K3 tape: start time, join
-- split files, relink, forget,
-- source (downloads)
-- last row: add a tape (file,
-- URL, Freesound id, queue file
-- downloads.txt, Freesound login)
--
-- arranger page (K1+E1 right):
-- E1 column, E2 row, E3 value
-- (ITEM left of the first item:
-- WAIT, STOP (brake), REM,
-- LOOP, HALT, JUMP)
-- K2 play from the row / stop
-- K3 cue the item / edit a REM
-- K1+K3 insert, K1+K2 delete
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
local Shelf = include 'lib/shelf'
local Coll = include 'lib/ui/collection'
local TapePopup = include 'lib/ui/tape_popup'
local Download = include 'lib/download'
local AddPopup = include 'lib/ui/add_popup'
local Run = include 'lib/arranger'
local ArrPage = include 'lib/ui/arranger'

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

---- pages (K1+E1); settings live in PARAMS

local PAGES = { 'collection', 'tape', 'regions', 'arranger' }
local page = 2

local function choose_tape()
  selecting = true
  fileselect.enter(_path.audio, function(path)
    selecting = false
    if path and path ~= 'cancel' then params:set('aur_file', path) end
    Tape.dirty = true
  end)
end

local function goto_page(name)
  for i, p in ipairs(PAGES) do
    if p == name then page = i end
  end
  Popup.reset()
  TapePopup.reset()
  AddPopup.reset()
  if PAGES[page] == 'regions' then Regions.enter() end
  if PAGES[page] == 'collection' then Coll.enter() end
  if PAGES[page] == 'arranger' then ArrPage.enter() end
  Tape.dirty = true
end

function init()
  Annot.init(Tape, View)
  Shelf.init(Tape, Annot)
  Download.init({ data_dir = norns.state.data, audio_dir = _path.audio .. 'aurotate/',
    Store = Annot.Store, Model = Annot.Model, Collection = Annot.Collection })
  Download.on_done = function(job)
    View.message('DOWNLOADED' .. (job.preview and ' (PREVIEW)' or ''), 3)
    Coll.select_path(job.path)
    Tape.dirty = true
  end
  Download.on_fail = function(job)
    View.message(('DOWNLOAD: ' .. tostring(job.err)):upper(), 3)
    Tape.dirty = true
  end
  Coll.init(Tape, Annot, Shelf, View, Download)
  AddPopup.init(Tape, Popup, Download)
  AddPopup.on_file = function() choose_tape() end
  AddPopup.on_message = function(msg, secs)
    View.message(msg, secs)
    Tape.dirty = true
  end
  TapePopup.init(Tape, Annot, Shelf, Popup)
  TapePopup.on_done = function(msg, path)
    View.message(msg, 2)
    if path then Coll.select_path(path) else Coll.changed() end
    Tape.dirty = true
  end
  Popup.init(Tape, Annot)
  Regions.init(Tape, Annot, View)
  RS.init(Tape, Annot)
  Run.init(Tape, Annot, View)
  ArrPage.init(Tape, Annot, View, Run)
  Popup.sound(RS)
  Keys.init(Tape, Annot, Popup, Regions, function() return not selecting and PAGES[page] or nil end)
  Keys.arranger = ArrPage
  Tape.on_open = function(path, dur)
    Popup.reset()
    return Annot.switch(path, dur)
  end
  Keys.collection = {
    move = function(d) Coll.move(d) end,
    open = function()
      local r = Coll.open()
      if r == 'add' then AddPopup.open() elseif r then goto_page('tape') end
    end,
    busy = function() return TapePopup.active() or TapePopup.modal or Popup.modal or AddPopup.active()
      or AddPopup.modal end,
  }
  Tape.on_opened = function()
    Annot.opened()
    Coll.changed()
    -- a recorder split file: say that it can be joined
    local n = Shelf.split_hint(Tape.st.path)
    if n then View.message('PART OF ' .. n .. ': JOIN IN COLLECTION', 4) end
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
  Run.start_poll()
  RS.push(true)
  redraw_metro = metro.init(function()
    Annot.tick()
    RS.tick()
    if Download.tick() then Tape.dirty = true end
    if selecting or Popup.modal or TapePopup.modal or AddPopup.modal or ArrPage.modal or Download.installing then
      return
    end
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
  if PAGES[page] == 'collection' then
    if TapePopup.active() then
      TapePopup.key(n, z, shift)
    elseif AddPopup.active() then
      AddPopup.key(n, z)
    elseif z == 1 and n == 2 then
      Tape.toggle()
    elseif z == 1 and n == 3 then
      local e = Coll.selected()
      if shift and e then
        TapePopup.open(e)
      else
        local r = Coll.open()
        if r == 'add' then AddPopup.open() elseif r then goto_page('tape') end
      end
    end
    Tape.dirty = true
    return
  end
  if PAGES[page] == 'arranger' then
    if z == 1 and n == 2 then
      if shift then ArrPage.delete() else ArrPage.play() end
    elseif z == 1 and n == 3 then
      if shift then ArrPage.insert() else ArrPage.k3() end
    end
    Tape.dirty = true
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
      TapePopup.close()
      AddPopup.close()
      if PAGES[page] == 'regions' then Regions.enter() end
      if PAGES[page] == 'collection' then Coll.enter() end
      if PAGES[page] == 'arranger' then ArrPage.enter() end
    end
    Tape.dirty = true
    return
  end
  if PAGES[page] == 'arranger' then
    if n == 1 then
      ArrPage.col_turn(d)
    elseif n == 2 then
      ArrPage.move(d)
    else
      ArrPage.value_turn(d)
    end
    return
  end
  if PAGES[page] == 'collection' then
    if TapePopup.active() then
      if n ~= 1 then TapePopup.enc(n, d, shift) end
    elseif AddPopup.active() then
      if n ~= 1 then AddPopup.enc(n, d) end
    elseif n == 2 then
      Coll.move(d)
    elseif n == 3 then
      Coll.sort_turn(d)
    end
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
    Coll.redraw(page, #PAGES)
    TapePopup.redraw()
    AddPopup.redraw()
    screen.update()
  elseif PAGES[page] == 'regions' then
    Regions.redraw(page, #PAGES)
    Popup.redraw()
    screen.update()
  else
    ArrPage.redraw(page, #PAGES)
    screen.update()
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
  local p = Run.playing
  print(string.format('ARR on %s rows %d playing %s queued %s',
    tostring(Run.on), doc and doc.arr and #doc.arr.rows or 0,
    p and (p.kind and (p.kind .. ' ' .. p.secs)
      or string.format('%s %.3f-%.3f x%g %d/%d', tostring(p.row), p.a, p.b, p.rate, p.pass, p.rep)) or '-',
    Run.queued and (Run.queued.kind or string.format('%.3f-%.3f x%g', Run.queued.a, Run.queued.b,
      Run.queued.rate)) or '-'))
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

-- reels: records a sine split into parts across the part boundaries
-- (test/reel.lua); check with tools/reel_check.py
function reel_test(path, bounds)
  return include('test/reel').run(Tape, path, bounds)
end

-- arranger: records test3h through an arrangement (test/arrange.lua);
-- check with tools/arrange_check.py
function arrange_test(path)
  return include('test/arrange').run(Tape, Annot, Run, path)
end

function clicks_test(path)
  return include('test/transport').clicks(Tape, path)
end

-- downloads (lib/download.lua): download('https://…'),
-- download('freesound:12345'); downloads() lists the queue
function download(line)
  local job, err = Download.request(line, 'repl')
  if not job then print('aurotate: not queued: ' .. tostring(err)) end
  return job
end
function downloads()
  for i, j in ipairs(Download.jobs) do
    print(i, j.line, j.state, j.progress and string.format('%.0f%%', j.progress * 100) or '', j.err or '')
  end
  print('freesound: ' .. Download.FS.state(os.time()) .. ', queue file: ' .. Download.queue_count())
end
-- the Freesound login: freesound_login() prints the link (and writes
-- freesound_login.txt), freesound_code('…') finishes it
function freesound_login()
  local url, err = Download.login_start()
  if not url then print('aurotate: ' .. tostring(err)) end
end
function freesound_code(code)
  Download.login_code(code, function(ok, msg) print('aurotate: freesound login: ' .. tostring(msg)) end)
end

-- REPL handles: dbg.Tape, dbg.View; dbg_shot(name) redraws and saves the
-- screen to dust/data/aurotate/<name>.png
dbg = { Tape = Tape, View = View, Annot = Annot, Popup = Popup, Keys = Keys, Regions = Regions, RS = RS,
  Shelf = Shelf, Coll = Coll, TapePopup = TapePopup, Download = Download, AddPopup = AddPopup,
  Run = Run, ArrPage = ArrPage }
-- REPL: dbg_page('regions') shows a page
function dbg_page(name)
  goto_page(name)
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
  Run.cleanup()
  Download.cleanup()
  Annot.cleanup()
  Tape.cleanup()
end

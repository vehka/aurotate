-- annot: marks and regions on the open tape — the K3 gestures, "what is
-- here", looping a region, and the document's life with the tape
--
-- K3 tap: a mark where K3 went down. K3 held (HOLD): region in, at the press;
-- the selection grows from there until the next K3 press, which is region
-- out. K1+K3 cancels a pending in.

local Model = include 'lib/model'
local Store = include 'lib/store'
local Export = include 'lib/export'
local Collection = include 'lib/collection'

local Annot = {}
Annot.Model, Annot.Store, Annot.Export, Annot.Collection = Model, Store, Export, Collection
Annot.rev = 0 -- counts edits, so lists know when to rebuild

Annot.HOLD = 0.4       -- s: a longer K3 press starts a region
Annot.HERE_PX = 3      -- a mark this close to the playhead (px) is "here"
Annot.HERE_MIN = 0.25  -- s: ...or this close, whatever the zoom

local Tape, View
local k3 = { down = nil, pos = nil, held = false }
local PARK_EVERY = 5 -- s
local parked = 0

function Annot.init(tape, view)
  Tape, View = tape, view
  Store.init(norns.state.data, util.time)
  Collection.init(norns.state.data, Store)
  Collection.load(function() return Store.all_docs(util.scandir) end)
  Model.changed = function()
    Annot.rev = Annot.rev + 1
    Store.touch()
  end
end

function Annot.doc() return Store.doc() end
function Annot.last_tape() return Store.last() end
function Annot.flush() Store.flush() end
function Annot.doc_path() return Store.doc() and Store.path_of(Store.doc().tape.path) end

-- called by Tape.open before it switches: close the old document (with the
-- position it was left at), open the new one. Returns the start position.
function Annot.switch(path, dur)
  local st = Tape.st
  Annot.leave()
  k3.down, k3.held = nil, false
  local f = io.open(path, 'r')
  local size = f and f:seek('end') or nil
  if f then f:close() end
  local doc, msg = Store.open(path, dur, size)
  -- the bext chunk knows when the recording started, unless someone set it
  -- by hand (not saved by itself: it comes from the file again next time)
  local o = doc.tape.origin
  if st.bext and (not o or o.source == 'bext') then doc.tape.origin = st.bext end
  if not st.bext and o and o.source == 'bext' then doc.tape.origin = nil end
  st.origin = doc.tape.origin
  Annot.rev = Annot.rev + 1
  if msg then View.message(msg, 3) end
  local start = doc.tape.last_pos or 0
  if start >= dur - 1 then start = 0 end
  return start
end

-- the open tape is left (another opens, the script stops): its position
-- and counts go to the document and the collection
function Annot.leave()
  local st = Tape.st
  local doc = Store.doc()
  if not doc then return end
  if st.path then Store.set_pos(st.pos) end
  Collection.from_doc(doc)
  Store.close()
end

-- Tape.open has switched: the collection learns about the tape
function Annot.opened()
  local st = Tape.st
  local doc = Store.doc()
  if not st.path then return end
  local e = Collection.update(st.path, { opened = os.time(), dur = st.dur, cache = Tape.analysis.dir,
    parts = st.parts and #st.parts or nil })
  if not st.parts then e.parts = nil end
  if doc then Collection.from_doc(doc) end
end

-- set (or with nil, clear) when the open tape's recording started; a
-- cleared one falls back to the bext chunk
function Annot.set_origin(origin)
  local doc = Store.doc()
  if not doc then return end
  Model.set_origin(doc, origin or Tape.st.bext)
  Tape.st.origin = doc.tape.origin
  Collection.from_doc(doc)
  Tape.dirty = true
end

-- seconds per pixel of the tape view, for "here"
local function tol()
  local spp = View.view(Tape.st)
  return math.max(Annot.HERE_MIN, Annot.HERE_PX * spp)
end

-- the mark or region under the playhead
function Annot.here()
  local doc = Store.doc()
  if not doc then return nil end
  return Model.at(doc, Tape.st.pos, tol())
end

function Annot.label(item)
  if not item then return '' end
  if item.label ~= '' then return item.label end
  return item.id
end

function Annot.add_mark(t)
  local doc = Store.doc()
  if not doc then return end
  local m = Model.add_mark(doc, t, os.time())
  View.message('MARK ' .. m.id, 1)
  Tape.dirty = true
  return m
end

-- start (or with one pending, finish) a region at t
function Annot.region_key(t)
  local st = Tape.st
  if not Store.doc() then return end
  if st.pending_in == nil then
    st.pending_in = t
    View.message('IN', 1)
  else
    local a = st.pending_in
    st.pending_in = nil
    local r = Model.add_region(Store.doc(), a, t, os.time())
    View.message(r and ('REGION ' .. r.id) or 'TOO SHORT', 1)
  end
  Tape.dirty = true
end

function Annot.cancel()
  if Tape.st.pending_in then
    Tape.st.pending_in = nil
    View.message('CANCEL', 1)
    Tape.dirty = true
    return true
  end
  return false
end

---- K3

function Annot.k3(z)
  local st = Tape.st
  if not Store.doc() then return end
  if z == 1 then
    if st.pending_in then
      Annot.region_key(st.pos) -- out, at the press
      k3.down = nil
    else
      k3.down, k3.pos, k3.held = util.time(), st.pos, false
    end
  elseif k3.down then
    if not k3.held then Annot.add_mark(k3.pos) end
    k3.down = nil
  end
end

-- from the UI timer: a K3 held long enough becomes region in
function Annot.tick()
  if k3.down and not k3.held and util.time() - k3.down >= Annot.HOLD then
    k3.held = true
    Annot.region_key(k3.pos)
  end
  local t = util.time()
  if t - parked >= PARK_EVERY then
    parked = t
    Annot.park()
  end
  Store.tick()
  Collection.tick()
end

---- loop the region here (K1+K2)

function Annot.loop_here()
  if params:get('aur_loop') == 1 then
    params:set('aur_loop', 0)
    View.message('LOOP OFF', 1)
    return
  end
  local doc = Store.doc()
  local r = doc and Model.innermost(doc, Tape.st.pos)
  if not r then
    View.message('NO REGION', 1)
    return
  end
  Annot.loop_item(r)
end

-- loop region r (the regions page, the reader); when it is the loop already:
-- loop off
function Annot.loop_item(r)
  local on = params:get('aur_loop') == 1
  if on and math.abs(params:get('aur_loop_in') - r.t0) < 0.01 and math.abs(params:get('aur_loop_out') - r.t1) < 0.01 then
    params:set('aur_loop', 0)
    View.message('LOOP OFF', 1)
    return
  end
  Tape.loop(r.t0, r.t1)
  -- a loop is entered by crossing an edge: start inside it (the loop param
  -- does this only when it turns on)
  local pos = Tape.st.pos
  if on and (pos < r.t0 or pos >= r.t1) then Tape.jump(r.t0) end
  View.message('LOOP ' .. Annot.label(r):upper(), 1)
end

-- save the position while the tape is stopped, so a power cut doesn't lose
-- the place (cleanup saves it too)
function Annot.park()
  if Tape.st.path and not Tape.playing() then Store.set_pos(Tape.st.pos) end
end

---- export (PARAMS > TAPE > export notes; export_notes() in the REPL)

-- write dust/data/aurotate/exports/<tape id>/notes.md. Returns its path.
function Annot.export()
  local doc = Store.doc()
  if not doc then
    View.message('NO TAPE', 1)
    return nil
  end
  local path, err = Export.write(doc, norns.state.data, Store.id(doc.tape.path), Store.write_file, nil,
    Tape.st.parts)
  if path then
    View.message('EXPORTED NOTES.MD', 2)
    print('aurotate: exported ' .. path)
  else
    View.message('EXPORT FAILED', 3)
    print('aurotate: export failed: ' .. tostring(err))
  end
  Tape.dirty = true
  return path
end

function Annot.cleanup()
  Annot.leave()
  Collection.flush()
end

return Annot

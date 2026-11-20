-- annot: marks and regions on the open tape — the K3 gestures, "what is
-- here", looping a region, and the document's life with the tape
--
-- K3 tap: a mark where K3 went down. K3 held (HOLD): region in, at the press;
-- the selection grows from there until the next K3 press, which is region
-- out. K1+K3 cancels a pending in.

local Model = include 'lib/model'
local Store = include 'lib/store'

local Annot = {}
Annot.Model, Annot.Store = Model, Store

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
  Model.changed = function() Store.touch() end
end

function Annot.doc() return Store.doc() end
function Annot.last_tape() return Store.last() end
function Annot.flush() Store.flush() end
function Annot.doc_path() return Store.doc() and Store.path_of(Store.doc().tape.path) end

-- called by Tape.open before it switches: close the old document (with the
-- position it was left at), open the new one. Returns the start position.
function Annot.switch(path, dur)
  local st = Tape.st
  if Store.doc() then Store.close(st.path and st.pos or nil) end
  k3.down, k3.held = nil, false
  local f = io.open(path, 'r')
  local size = f and f:seek('end') or nil
  if f then f:close() end
  local doc, msg = Store.open(path, dur, size)
  if msg then View.message(msg, 3) end
  local start = doc.tape.last_pos or 0
  if start >= dur - 1 then start = 0 end
  return start
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
  Tape.loop(r.t0, r.t1)
  View.message('LOOP ' .. Annot.label(r):upper(), 1)
end

-- save the position while the tape is stopped, so a power cut doesn't lose
-- the place (cleanup saves it too)
function Annot.park()
  if Tape.st.path and not Tape.playing() then Store.set_pos(Tape.st.pos) end
end

function Annot.cleanup()
  if Store.doc() then Store.close(Tape.st.path and Tape.st.pos or nil) end
end

return Annot

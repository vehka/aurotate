-- arranger: plays the tape through the open document's arrangement
-- (docs/PLAN.md §4.4). The sequencer is lib/arrange.lua; the engine plays one
-- span and holds the next, switching at the span's end in the same control
-- block (exact, gapless row ends). Each switch comes back as the aur_arr
-- poll, and the span after that is sent then.
--
-- Any manual transport move (play / stop, speed, scrub, a seek, a loop)
-- leaves arrangement mode; the tape keeps its place (Tape.on_manual).

local Arr = include 'lib/arrange'

local A = {}

local Tape, Annot, View
local s = nil         -- the sequencer state (Arr.start)
local gen = 0         -- each start is a generation; older switches are ignored
local wraps = 0       -- switches seen since the start
A.on = false
A.playing = nil       -- the span playing (Arr.step's table: a, b, rate, row, pass, rep)
A.queued = nil        -- the span the engine holds next (nil: stop after this one)
A.after = nil         -- the one after that (the engine prefetches it)
A.err = nil

local poll_ = nil

function A.init(tape, annot, view)
  Tape, Annot, View = tape, annot, view
  Tape.on_manual = function() A.leave() end
  Tape.arr_label = A.label
end

-- the engine's kind codes: 0 a span, 1 STOP, 2 WAIT
local KIND = { stop = 1, wait = 2 }
local function args(sp)
  if sp.kind then return 0, 0, 0, KIND[sp.kind], sp.secs end
  return sp.a, sp.b, sp.rate, 0, 0
end

local function send_next()
  local q, h = A.queued, A.after
  if q then
    local a, b, r, k, d = args(q)
    engine.arr_next(a, b, r, k, d)
  end
  -- only spans need their first chunks read ahead
  if h and not h.kind then engine.arr_hint(h.a, h.b, h.rate) end
end

-- the speed param while a span plays (a brake ends stopped)
local function show_speed(sp)
  params:set('aur_shuttle', sp.kind and 0 or sp.rate, true)
end

-- play from row i (1-based)
function A.start(i)
  local doc = Annot.doc()
  if not doc or not Tape.st.path then return false end
  local rows = doc.arr and doc.arr.rows or {}
  s = Arr.start(rows, doc, i)
  local first = Arr.step(s)
  if not first then
    View.message(s.err or 'NOTHING TO PLAY', 2)
    s = nil
    return false
  end
  A.leave()
  -- no K1+K2 loop while arranging (the engine ignores it too)
  if params:get('aur_loop') == 1 then params:set('aur_loop', 0) end
  gen = (gen + 1) % 1000
  wraps = 0
  A.on, A.err = true, nil
  A.playing = first
  A.queued = Arr.step(s)
  A.after = A.queued and Arr.step(s)
  Tape.st.jogging = false
  local a, b, r, k, d = args(first)
  engine.arr_span(a, b, r, gen, k, d)
  send_next()
  -- the speed param shows the speed (silently: its action would leave)
  show_speed(first)
  Tape.dirty = true
  return true
end

-- the arrangement is done (a HALT, the end of the list, or a guard)
local function finish()
  A.on = false
  A.playing, A.queued, A.after = nil, nil, nil
  A.err = s and s.err
  engine.arr_off()
  params:set('aur_shuttle', 0, true)
  engine.rate(0, 0)
  View.message(A.err or 'ARR END', 2)
  s = nil
  Tape.dirty = true
end

-- leave arrangement mode (a manual move): the engine keeps the tape where it
-- is, at its speed, until the move that called this changes it
function A.leave()
  if not A.on then return end
  A.on = false
  A.playing, A.queued, A.after = nil, nil, nil
  s = nil
  engine.arr_off()
  Tape.dirty = true
end

-- K2 on the arranger page
function A.stop()
  if not A.on then return end
  A.leave()
  params:set('aur_shuttle', 0, true)
  engine.rate(0, params:get('aur_glide'))
end

-- the engine switched spans (count since the start, of generation g)
local function wrapped(v)
  v = math.floor(v + 0.5)
  local g, c = v // 10000, v % 10000
  if not A.on or g ~= gen then return end
  while wraps < c do
    wraps = wraps + 1
    A.playing = A.queued
    if not A.playing then
      finish()
      return
    end
    A.queued = A.after
    A.after = A.queued and Arr.step(s)
    if wraps == c then send_next() end
  end
  show_speed(A.playing)
  Tape.dirty = true
end

function A.start_poll()
  poll_ = poll.set('aur_arr')
  poll_.callback = wrapped
  poll_:start()
end

-- rows were inserted (delta 1) or deleted (-1) at index i while playing
function A.shifted(i, delta)
  if not A.on then return end
  Arr.shift(s, i, delta)
  local function f(sp)
    if not sp or not sp.row then return end
    if delta > 0 then
      if sp.row >= i then sp.row = sp.row + 1 end
    elseif sp.row == i then
      sp.row = nil
    elseif sp.row > i then
      sp.row = sp.row - 1
    end
  end
  f(A.playing)
  f(A.queued)
  f(A.after)
end

-- the header state: ARR 012 2/4
function A.label()
  if not A.on or not A.playing then return nil end
  local p = A.playing
  local row = p.row and string.format('%03d', p.row - 1) or '---'
  if p.kind then return 'ARR ' .. row .. ' ' .. p.kind:upper() end
  if p.rep > 1 then return string.format('ARR %s %d/%d', row, p.pass, p.rep) end
  return 'ARR ' .. row
end

-- the passes of LOOP row i so far, while playing (for the page)
function A.loop_pass(i) return A.on and Arr.loop_pass(s, i) or nil end

function A.cleanup()
  if poll_ then poll_:stop() end
  poll_ = nil
end

return A

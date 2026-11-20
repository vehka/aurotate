-- arrange: the arranger's rows and sequencer (docs/PLAN.md §4.4). Pure Lua,
-- no norns calls, tested off the device (test/model_test.lua).
--
-- An arrangement is a list of rows in the tape document (`doc.arr.rows`):
--   { k = 'play', id = 'r3', rep = 2, rate = -2 }  a region (t0 → t1) or a
--        mark (to the next mark or region start), rep times, at rate
--        (negative: backwards, end → start)
--   { k = 'loop', to = 4, n = 0 }   back to row `to`, n passes of the section
--                                   in all (0 = forever)
--   { k = 'jump', to = 0 }          continue at row `to`
--   { k = 'stop', secs = 1 }        brake: the tape rolls on from where the
--                                   row before ended and spins down to a
--                                   stop over secs
--   { k = 'wait', secs = 1 }        silence for secs
--   { k = 'halt' }                  stop (the end of the list is one too)
--   { k = 'rem', text = '…' }       a remark; no time, no effect
-- Row numbers (`to`) are 0-based, as the page shows them (000…255); Lua
-- indices into `rows` are 1-based.
--
-- Arr.start(rows, doc, i) and Arr.step(s) → the next span { a, b, rate, row,
-- pass, rep } after resolving command rows and REP, or nil = halt (s.err says
-- why when it isn't a plain halt). A STOP or WAIT row gives a timed span
-- { kind = 'stop' | 'wait', secs, row, pass = 1, rep = 1 } (no a, b, rate).

local Arr = {}

Arr.MAX_ROWS = 256
Arr.MAX_REP = 64
Arr.MAX_N = 99
Arr.MIN_SPAN = 0.05 -- s of playing time; shorter spans are lengthened
-- SPD steps (the shuttle's, without 0 and the proxy-only ±128/256)
Arr.RATES = { -64, -32, -16, -8, -4, -2, -1.5, -1, -0.5, -0.25,
  0.25, 0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 2, 4, 8, 16, 32, 64 }
-- the commands in the ITEM column, left of the first item (E3 anti-clockwise
-- from the first item: WAIT, STOP, REM, LOOP, HALT, JUMP)
Arr.COMMANDS = { 'jump', 'halt', 'loop', 'rem', 'stop', 'wait' }
-- STOP / WAIT times (s)
Arr.SECS = { 0.05, 0.1, 0.2, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 8, 10, 15, 20, 30, 60 }

local function is_region(id) return type(id) == 'string' and id:sub(1, 1) == 'r' end

function Arr.find(doc, id)
  if type(id) ~= 'string' then return nil end
  for _, item in ipairs(is_region(id) and doc.regions or doc.marks) do
    if item.id == id then return item end
  end
end

-- the tape span an item plays: a region's t0 → t1; a mark from its time to
-- the next mark or region start after it (else the end of the tape)
function Arr.item_span(doc, item)
  if item.t0 then return item.t0, item.t1 end
  local t = item.t
  local b = doc.tape.dur or t
  for _, m in ipairs(doc.marks) do
    if m.t > t then
      b = math.min(b, m.t)
      break
    end
  end
  for _, r in ipairs(doc.regions) do
    if r.t0 > t then
      b = math.min(b, r.t0)
      break
    end
  end
  return t, b
end

-- a span long enough to play at least MIN_SPAN at `rate`, inside the tape
local function fit(a, b, rate, dur)
  local need = Arr.MIN_SPAN * math.abs(rate)
  if b - a < need then
    b = a + need
    if dur and b > dur then
      b = dur
      a = math.max(0, b - need)
    end
  end
  return a, b
end

-- 1-based index of the row `to` (0-based) points at, clamped
local function target(rows, to)
  return math.max(1, math.min(#rows, (to or 0) + 1))
end

function Arr.start(rows, doc, i)
  return { rows = rows or {}, doc = doc, row = i or 1, left = 0, cur = nil, loops = {}, err = nil }
end

-- the next span, or nil when the arrangement halts
function Arr.step(s)
  local rows, doc = s.rows, s.doc
  -- more passes of the play row that played last
  if s.left > 0 and s.cur then
    local row = rows[s.cur]
    local item = row and row.k == 'play' and Arr.find(doc, row.id)
    if item then
      s.left = s.left - 1
      local a, b = Arr.item_span(doc, item)
      a, b = fit(a, b, row.rate, doc.tape.dur)
      return { a = a, b = b, rate = row.rate, row = s.cur, pass = row.rep - s.left, rep = row.rep }
    end
    s.left = 0
  end
  local guard = 0
  while true do
    local row = rows[s.row]
    if not row then
      s.cur = nil
      return nil
    end
    guard = guard + 1
    if guard > Arr.MAX_ROWS then
      s.err = 'NO PLAY ROW'
      s.cur = nil
      return nil
    end
    local k = row.k
    if k == 'play' then
      local item = Arr.find(doc, row.id)
      if item then
        s.cur = s.row
        s.left = row.rep - 1
        s.row = s.row + 1
        local a, b = Arr.item_span(doc, item)
        a, b = fit(a, b, row.rate, doc.tape.dur)
        return { a = a, b = b, rate = row.rate, row = s.cur, pass = 1, rep = row.rep }
      end
      s.row = s.row + 1 -- the item was deleted: skipped
    elseif k == 'stop' or k == 'wait' then
      s.cur = s.row
      s.left = 0
      s.row = s.row + 1
      return { kind = k, secs = row.secs, row = s.cur, pass = 1, rep = 1 }
    elseif k == 'halt' then
      s.cur = nil
      return nil
    elseif k == 'jump' then
      s.row = target(rows, row.to)
    elseif k == 'loop' then
      local done = s.loops[s.row] or 1 -- passes of the section so far
      if row.n == 0 or done < row.n then
        local to = target(rows, row.to)
        -- going back over an inner loop restarts its count
        for j = to, s.row - 1 do s.loops[j] = nil end
        s.loops[s.row] = done + 1
        s.row = to
      else
        s.loops[s.row] = nil
        s.row = s.row + 1
      end
    else -- rem
      s.row = s.row + 1
    end
  end
end

-- the passes of LOOP row i so far (for the page), or nil
function Arr.loop_pass(s, i) return s and s.loops[i] end

---- editing (the model calls these and marks the document changed)

-- a LOOP's default target: the row after the nearest earlier LOOP, else 000
function Arr.default_loop_target(rows, i)
  for j = i - 1, 1, -1 do
    if rows[j].k == 'loop' then return j end -- row j + 1 in 1-based = j in 0-based
  end
  return 0
end

-- a row of kind k at index i (defaults); `id` for a play row
function Arr.new_row(rows, i, k, id)
  if k == 'play' then return { k = 'play', id = id, rep = 1, rate = 1 } end
  if k == 'loop' then return { k = 'loop', to = Arr.default_loop_target(rows, i), n = 0 } end
  if k == 'jump' then return { k = 'jump', to = 0 } end
  if k == 'rem' then return { k = 'rem', text = '' } end
  if k == 'stop' or k == 'wait' then return { k = k, secs = 1 } end
  return { k = 'halt' }
end

function Arr.copy(row)
  local c = {}
  for k, v in pairs(row) do c[k] = v end
  return c
end

-- insert `row` at index i (1-based); targets at or after it move with
-- their rows. false when the list is full.
function Arr.insert(rows, i, row)
  if #rows >= Arr.MAX_ROWS then return false end
  i = math.max(1, math.min(#rows + 1, i))
  for _, r in ipairs(rows) do
    if r.to and r.to + 1 >= i then r.to = r.to + 1 end
  end
  table.insert(rows, i, row)
  return true
end

-- delete row i; targets after it move up, a target at it points at the row
-- that takes its place
function Arr.delete(rows, i)
  if not rows[i] then return false end
  table.remove(rows, i)
  for _, r in ipairs(rows) do
    if r.to then
      if r.to + 1 > i then r.to = r.to - 1 end
      r.to = math.max(0, math.min(math.max(0, #rows - 1), r.to))
    end
  end
  return true
end

-- keep a running sequencer's row indices on their rows after an insert
-- (delta 1) or delete (delta -1) at index i
function Arr.shift(s, i, delta)
  if not s then return end
  local function f(x)
    if not x then return x end
    if delta > 0 then return x >= i and x + 1 or x end
    if x == i then return nil end
    return x > i and x - 1 or x
  end
  s.row = f(s.row) or i
  local cur = f(s.cur)
  if not cur then s.left = 0 end
  s.cur = cur
  local loops = {}
  for j, v in pairs(s.loops) do
    local nj = f(j)
    if nj then loops[nj] = v end
  end
  s.loops = loops
end

---- validation (Model.validate)

local function num(x) return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge end
local function int(x, lo, hi, def)
  if not num(x) then return def end
  return math.max(lo, math.min(hi, math.floor(x + 0.5)))
end

local function nearest(list, r)
  local best, bd = list[1], math.huge
  for _, v in ipairs(list) do
    local d = math.abs(v - r)
    if d < bd then best, bd = v, d end
  end
  return best
end

-- a clean copy of a loaded arrangement (or nil for none) and how many rows
-- were dropped. Rows pointing at missing items are kept (shown `?`).
function Arr.clean(arr)
  if type(arr) ~= 'table' or type(arr.rows) ~= 'table' then return nil, 0 end
  local rows, dropped = {}, 0
  for _, r in ipairs(arr.rows) do
    local c
    if type(r) == 'table' then
      if r.k == 'play' and type(r.id) == 'string' and r.id:match('^[mr]%d+$') then
        c = { k = 'play', id = r.id, rep = int(r.rep, 1, Arr.MAX_REP, 1),
          rate = num(r.rate) and r.rate ~= 0 and nearest(Arr.RATES, r.rate) or 1 }
      elseif r.k == 'stop' or r.k == 'wait' then
        c = { k = r.k, secs = num(r.secs) and nearest(Arr.SECS, r.secs) or 1 }
      elseif r.k == 'loop' then
        c = { k = 'loop', to = int(r.to, 0, Arr.MAX_ROWS - 1, 0), n = int(r.n, 0, Arr.MAX_N, 0) }
      elseif r.k == 'jump' then
        c = { k = 'jump', to = int(r.to, 0, Arr.MAX_ROWS - 1, 0) }
      elseif r.k == 'halt' then
        c = { k = 'halt' }
      elseif r.k == 'rem' then
        c = { k = 'rem', text = type(r.text) == 'string' and r.text or '' }
      end
    end
    if c and #rows < Arr.MAX_ROWS then rows[#rows + 1] = c else dropped = dropped + 1 end
  end
  for _, r in ipairs(rows) do
    if r.to then r.to = math.min(r.to, math.max(0, #rows - 1)) end
  end
  return { rows = rows }, dropped
end

return Arr

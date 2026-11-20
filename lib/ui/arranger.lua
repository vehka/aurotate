-- arranger page: the fourth page, the tape's arrangement as rows
-- (docs/PLAN.md §4.4)
--
--   E1       column (ITEM · REP · SPD; on commands: target, count, text)
--   E2       select row
--   E3       change the focused value; on ITEM, anti-clockwise past the first
--            item: WAIT, STOP, REM, LOOP, HALT, JUMP
--   K2       play the arrangement from the selected row / stop
--   K3       on ITEM: move the tape to the item; on a REM: edit its text
--   K1+K3    insert a row below (a copy; in an empty list, the item here)
--   K1+K2    delete the row (twice to confirm)
--
-- Row: `012 ■ arrival story  x2  -2x`. The playing row has a bar at the
-- left and its passes left after REP.

local textentry = require 'textentry'
local Draw = include 'lib/ui/draw'
local Arr = include 'lib/arrange'

local U = {}

local ROWS = 7
local ROW_H = 7
local TOP = 10
local CONFIRM = 2 -- s to press delete again

local Tape, Annot, View, Run, Model, Export
U.sel = 1
U.top = 1
U.col = 1
U.modal = false -- textentry is open
local confirm_at = -1

-- items in tape order (the ITEM choices after the commands), per document rev
local cache = { doc = nil, rev = -1, items = {}, index = {} }

function U.init(tape, annot, view, run)
  Tape, Annot, View, Run = tape, annot, view, run
  Model, Export = annot.Model, annot.Export
end

local function doc() return Annot.doc() end

local function rows()
  local d = doc()
  return d and d.arr and d.arr.rows or {}
end

local function items()
  local d = doc()
  if not d then return {} end
  if cache.doc ~= d or cache.rev ~= Annot.rev then
    cache.doc, cache.rev = d, Annot.rev
    cache.items = Export.items(d)
    cache.index = {}
    for i, it in ipairs(cache.items) do cache.index[it.id] = i end
  end
  return cache.items
end

-- columns a row kind has
local NCOLS = { play = 3, loop = 3, jump = 2, rem = 2, halt = 1, stop = 2, wait = 2 }

local function clamp_sel()
  local n = #rows()
  U.sel = util.clamp(U.sel, 1, math.max(1, n))
  if U.sel < U.top then U.top = U.sel end
  if U.sel > U.top + ROWS - 1 then U.top = U.sel - ROWS + 1 end
  U.top = util.clamp(U.top, 1, math.max(1, n - ROWS + 1))
end

function U.selected() return rows()[U.sel], U.sel end

local function col_of(row) return math.min(U.col, row and NCOLS[row.k] or 1) end

function U.move(d)
  U.sel = U.sel + d
  clamp_sel()
  confirm_at = -1
  Tape.dirty = true
end

function U.col_turn(d)
  local row = U.selected()
  U.col = util.clamp(col_of(row) + d, 1, row and NCOLS[row.k] or 1)
  Tape.dirty = true
end

local function list_step(list, r, d)
  local best, bi = math.huge, 1
  for i, v in ipairs(list) do
    if math.abs(v - r) < best then best, bi = math.abs(v - r), i end
  end
  return list[util.clamp(bi + d, 1, #list)]
end

-- E3
function U.value_turn(d)
  local row, i = U.selected()
  local dc = doc()
  if not row or not dc then return end
  local c = col_of(row)
  if c == 1 then
    -- one list: the commands, then the items
    local list = items()
    local cur
    if row.k == 'play' then
      cur = #Arr.COMMANDS + (cache.index[row.id] or 0)
    else
      for k, name in ipairs(Arr.COMMANDS) do
        if name == row.k then cur = k end
      end
    end
    local nxt = util.clamp(cur + d, 1, #Arr.COMMANDS + #list)
    if nxt == cur then return end
    if nxt <= #Arr.COMMANDS then
      Model.arr_replace(dc, i, Arr.new_row(rows(), i, Arr.COMMANDS[nxt]))
    else
      local id = list[nxt - #Arr.COMMANDS].id
      if row.k == 'play' then
        Model.arr_set(dc, i, 'id', id)
      else
        Model.arr_replace(dc, i, Arr.new_row(rows(), i, 'play', id))
      end
    end
  elseif row.k == 'play' then
    if c == 2 then
      Model.arr_set(dc, i, 'rep', util.clamp(row.rep + d, 1, Arr.MAX_REP))
    else
      Model.arr_set(dc, i, 'rate', list_step(Arr.RATES, row.rate, d))
    end
  elseif row.k == 'stop' or row.k == 'wait' then
    Model.arr_set(dc, i, 'secs', list_step(Arr.SECS, row.secs, d))
  elseif row.k == 'loop' or row.k == 'jump' then
    if c == 2 then
      Model.arr_set(dc, i, 'to', util.clamp(row.to + d, 0, #rows() - 1))
    else
      Model.arr_set(dc, i, 'n', util.clamp(row.n + d, 0, Arr.MAX_N))
    end
  end
  Tape.dirty = true
end

local function edit_rem(i)
  local row = rows()[i]
  if not row or row.k ~= 'rem' then return end
  U.modal = true
  textentry.enter(function(txt)
    U.modal = false
    local dc = doc()
    if txt and dc and rows()[i] == row then Model.arr_set(dc, i, 'text', txt) end
    Tape.dirty = true
  end, row.text, 'remark')
end

-- K3 / Enter
function U.k3()
  local row, i = U.selected()
  if not row then return end
  if row.k == 'rem' then
    edit_rem(i)
  elseif row.k == 'play' and col_of(row) == 1 then
    local item = Arr.find(doc(), row.id)
    if not item then
      View.message('ITEM DELETED', 1)
      return
    end
    local a, b = Arr.item_span(doc(), item)
    Tape.jump(row.rate < 0 and math.max(a, b - 0.05) or a)
    View.message('CUE ' .. Annot.label(item):upper(), 1)
  end
  Tape.dirty = true
end

-- the item a new row in an empty list plays: the one here, else the last
-- one started before the playhead, else the first
local function item_here()
  local here = Annot.here()
  if here then return here end
  local list, pos, best = items(), Tape.st.pos, nil
  for _, it in ipairs(list) do
    if Model.start(it) <= pos then best = it else break end
  end
  return best or list[1]
end

-- K1+K3: a copy of the selected row below it
function U.insert()
  local dc = doc()
  if not dc then return end
  local list = rows()
  local row, i
  if #list == 0 then
    local it = item_here()
    if not it then
      View.message('NO MARKS YET', 1)
      return
    end
    row, i = Arr.new_row(list, 1, 'play', it.id), 1
  else
    row, i = Arr.copy(list[U.sel]), U.sel + 1
  end
  if not Model.arr_insert(dc, i, row) then
    View.message('FULL (' .. Arr.MAX_ROWS .. ')', 1)
    return
  end
  Run.shifted(i, 1)
  U.sel = i
  clamp_sel()
  Tape.dirty = true
end

-- K1+K2: delete, after a second press
function U.delete()
  local dc = doc()
  local row, i = U.selected()
  if not dc or not row then return end
  local t = util.time()
  if t - confirm_at > CONFIRM then
    confirm_at = t
    View.message('DELETE? AGAIN', CONFIRM)
    Tape.dirty = true
    return
  end
  confirm_at = -1
  Model.arr_delete(dc, i)
  Run.shifted(i, -1)
  clamp_sel()
  View.message('DELETED', 1)
  Tape.dirty = true
end

-- K2
function U.play()
  if Run.on then Run.stop() else Run.start(U.sel) end
  Tape.dirty = true
end

function U.enter()
  confirm_at = -1
  clamp_sel()
end

---- drawing

local function rate_text(r)
  local s = string.format('%g', math.abs(r))
  if s:sub(1, 2) == '0.' then s = s:sub(2) end
  return (r < 0 and '-' or '') .. s .. 'x'
end

local function first_line(s) return s:match('^%s*([^\n]*)') end

-- cells of a row: { x, w, text, level, glyph? } per column; right-aligned
-- when `right`
local function cells(row, k)
  local out = {}
  if row.k == 'play' then
    local item = Arr.find(doc(), row.id)
    local label
    if not item then
      label = '? ' .. row.id
    elseif item.label ~= '' then
      label = item.label
    elseif item.note:match('%S') then
      label = first_line(item.note)
    else
      label = item.id
    end
    out[1] = { x = 16, w = 72, text = label, glyph = item and (item.t0 and 'region' or 'mark') or nil,
      missing = item == nil }
    local rep = 'x' .. row.rep
    local p = Run.on and Run.playing
    if p and p.row == k and p.rep > 1 then rep = rep .. ' ' .. (p.rep - p.pass) end
    out[2] = { x = 89, w = 18, text = rep }
    out[3] = { x = 107, w = 19, text = rate_text(row.rate), right = true }
  elseif row.k == 'loop' then
    out[1] = { x = 16, w = 20, text = 'LOOP' }
    out[2] = { x = 37, w = 18, text = string.format('>%03d', row.to) }
    local n = row.n == 0 and 'INF' or ('x' .. row.n)
    local pass = Run.loop_pass(k)
    if pass then n = n .. ' ' .. pass end
    out[3] = { x = 56, w = 30, text = n }
  elseif row.k == 'jump' then
    out[1] = { x = 16, w = 20, text = 'JUMP' }
    out[2] = { x = 37, w = 18, text = string.format('>%03d', row.to) }
  elseif row.k == 'halt' then
    out[1] = { x = 16, w = 20, text = 'HALT' }
  elseif row.k == 'stop' or row.k == 'wait' then
    out[1] = { x = 16, w = 20, text = row.k:upper() }
    out[2] = { x = 37, w = 24, text = string.format('%gs', row.secs) }
  else
    out[1] = { x = 16, w = 16, text = 'REM' }
    out[2] = { x = 33, w = 95, text = row.text ~= '' and first_line(row.text) or '...', dim = row.text == '' }
  end
  return out
end

function U.redraw(page, pages)
  local st = Tape.st
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  local list = rows()
  clamp_sel()
  local state, slev = View.state_label(Tape, st)
  Draw.header(page, pages, 'ARR ' .. #list, state, slev, st.path and Tape.clock(st.pos, true) or nil)
  if not st.path or not doc() then
    screen.level(4)
    screen.move(64, 36)
    screen.text_center('no tape')
    return
  end
  if #list == 0 then
    screen.level(4)
    screen.move(64, 34)
    screen.text_center('no rows yet')
    screen.move(64, 44)
    screen.text_center('K1+K3: add a row')
    return
  end
  screen.font_face(25)
  screen.font_size(6)
  local playing = Run.on and Run.playing and Run.playing.row
  for r = 0, ROWS - 1 do
    local k = U.top + r
    local row = list[k]
    if not row then break end
    local y = TOP + r * ROW_H
    local sel = k == U.sel
    if sel then
      screen.level(2)
      screen.rect(0, y, 127, ROW_H)
      screen.fill()
    end
    if playing == k then
      screen.level(15)
      screen.rect(0, y + 1, 1, ROW_H - 2)
      screen.fill()
    end
    screen.level(sel and 15 or 4)
    screen.move(3, y + 6)
    screen.text(string.format('%03d', k - 1))
    local cs = cells(row, k)
    local focus = sel and col_of(row) or nil
    for c, cell in ipairs(cs) do
      local inv = focus == c
      local tx = cell.x + 1
      if inv then
        screen.level(sel and 12 or 0)
        screen.rect(cell.x, y, cell.w, ROW_H)
        screen.fill()
      end
      if cell.glyph then
        screen.level(inv and 0 or (sel and 15 or 9))
        if cell.glyph == 'region' then screen.rect(tx, y + 2, 3, 3) else screen.rect(tx + 1, y + 1, 1, 5) end
        screen.fill()
        tx = tx + 5
      end
      local lev
      if inv then
        lev = 0
      elseif cell.missing or cell.dim then
        lev = 3
      elseif row.k ~= 'play' and c == 1 then
        lev = sel and 15 or 8
      else
        lev = sel and 15 or (c == 1 and 11 or 6)
      end
      screen.level(lev)
      local text = util.trim_string_to_width(cell.text, cell.x + cell.w - tx - 1)
      if cell.right then
        screen.move(cell.x + cell.w - 1, y + 6)
        screen.text_right(text)
      else
        screen.move(tx, y + 6)
        screen.text(text)
      end
    end
  end
  if #list > ROWS then
    local h = math.max(3, math.floor(ROWS * ROW_H * ROWS / #list))
    local y0 = TOP + math.floor((ROWS * ROW_H - h) * (U.top - 1) / (#list - ROWS))
    screen.level(4)
    screen.rect(127, y0, 1, h)
    screen.fill()
  end
  screen.font_face(1)
  screen.font_size(8)
end

return U

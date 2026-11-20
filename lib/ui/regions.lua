-- regions: the third page, every mark and region on the tape as a list
-- (docs/PLAN.md §4.3)
--
--   E2       select (stops following the playhead)
--   E3       filter by tag (all, then each tag in the document)
--   K2       play / stop
--   K3       jump the tape there (and follow the playhead again)
--   K1+K2    loop the selected region (again: loop off)
--   K1+K3    reader popup: the whole note, scrollable
--
-- Rows are in tape order (as in notes.md), indented by how many regions hold
-- them. The list follows the playhead (the selection is the last item that
-- started before it) until E2 picks something else; K3 or re-entering the
-- page goes back to following. A bar at the left edge marks what is under
-- the playhead: bright for "here" (what the tape page would open), dim for
-- the other regions it is in.

local Draw = include 'lib/ui/draw'

local R = {}

local ROWS = 7
local ROW_H = 7
local TOP = 10 -- y of the first row

local Tape, Annot, View, Model, Export
R.sel = 1
R.top = 1
R.follow = true
R.filter = nil -- a tag, or nil for all

-- the shown list, rebuilt when the document changes
local cache = { doc = nil, rev = -1, filter = false, items = {}, depth = {} }

function R.init(tape, annot, view)
  Tape, Annot, View = tape, annot, view
  Model, Export = annot.Model, annot.Export
end

local function items()
  local doc = Annot.doc()
  if not doc then
    cache.doc, cache.items = nil, {}
    return cache.items
  end
  if cache.doc == doc and cache.rev == Annot.rev and cache.filter == R.filter then return cache.items end
  local all = Export.items(doc)
  local depth, by = {}, {}
  for _, item in ipairs(all) do
    local p = Export.parent(doc, item)
    -- parents come first in tape order, so their depth is known
    depth[item] = p and ((depth[p] or 0) + 1) or 0
  end
  -- the filter's tag may be gone (untagged, deleted)
  if R.filter then
    local found = false
    for _, tag in ipairs(Model.tags(doc)) do
      if tag == R.filter then found = true end
    end
    if not found then R.filter = nil end
  end
  if R.filter then
    for _, item in ipairs(all) do
      if Model.has_tag(item, R.filter) then by[#by + 1] = item end
    end
  else
    by = all
  end
  cache.doc, cache.rev, cache.filter, cache.items, cache.depth = doc, Annot.rev, R.filter, by, depth
  return by
end

-- the item the playhead has reached: the last one that started before it
local function current(list)
  local pos = Tape.st.pos
  local here = Annot.here()
  local best = nil
  for i, item in ipairs(list) do
    if item == here then return i end
    if Model.start(item) <= pos + 0.001 then best = i else break end
  end
  return best or 1
end

local function clamp_sel(list)
  R.sel = util.clamp(R.sel, 1, math.max(1, #list))
  if R.sel < R.top then R.top = R.sel end
  if R.sel > R.top + ROWS - 1 then R.top = R.sel - ROWS + 1 end
  R.top = util.clamp(R.top, 1, math.max(1, #list - ROWS + 1))
end

function R.selected()
  local list = items()
  return list[R.sel]
end

-- coming to the page: follow the playhead
function R.enter()
  R.follow = true
end

function R.move(d)
  local list = items()
  if #list == 0 then return end
  R.follow = false
  R.sel = util.clamp(R.sel + d, 1, #list)
  clamp_sel(list)
  Tape.dirty = true
end

function R.filter_turn(d)
  local doc = Annot.doc()
  if not doc then return end
  local tags = Model.tags(doc)
  local i = 0 -- 0 = all
  for k, tag in ipairs(tags) do
    if tag == R.filter then i = k end
  end
  i = (i + d) % (#tags + 1)
  local keep = R.selected()
  R.filter = i > 0 and tags[i] or nil
  -- keep the selection on the same item when it is still shown
  local list = items()
  R.sel = 1
  for k, item in ipairs(list) do
    if item == keep then R.sel = k end
  end
  if keep and list[R.sel] ~= keep then R.follow = true end
  Tape.dirty = true
end

function R.jump()
  local item = R.selected()
  if not item then return end
  Tape.jump(Model.start(item))
  R.follow = true
  Tape.dirty = true
end

function R.loop()
  local item = R.selected()
  if Model.is_region(item) then
    Annot.loop_item(item)
  elseif params:get('aur_loop') == 1 then
    params:set('aur_loop', 0)
    View.message('LOOP OFF', 1)
  else
    View.message('NOT A REGION', 1)
  end
  Tape.dirty = true
end

---- drawing

local function first_line(s) return s:match('^%s*([^\n]*)') end

function R.redraw(page, pages)
  local st = Tape.st
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  local list = items()
  if R.follow and #list > 0 then R.sel = current(list) end
  clamp_sel(list)
  local state, slev = View.state_label(Tape, st)
  local name = (R.filter and ('#' .. R.filter) or 'ALL') .. ' ' .. #list
  Draw.header(page, pages, name, state, slev, st.path and Tape.hms(st.pos, true) or nil, 8, R.filter ~= nil)
  local doc = Annot.doc()
  if not st.path or not doc then
    screen.level(4)
    screen.move(64, 36)
    screen.text_center('no tape')
    return
  end
  if #list == 0 then
    screen.level(4)
    screen.move(64, 34)
    if R.filter then
      screen.text_center('nothing tagged')
      screen.move(64, 44)
      screen.text_center('E3: other tags')
    else
      screen.text_center('no marks yet')
      screen.move(64, 44)
      screen.text_center('K3 on the tape page')
    end
    return
  end
  local long = (doc.tape.dur or 0) >= 3600
  local here = Annot.here()
  local pos = st.pos
  screen.font_face(25)
  screen.font_size(6)
  for i = 0, ROWS - 1 do
    local k = R.top + i
    local item = list[k]
    if not item then break end
    local y = TOP + i * ROW_H
    local sel = k == R.sel
    if sel then
      screen.level(2)
      screen.rect(0, y, 127, ROW_H)
      screen.fill()
    end
    -- under the playhead
    local inside = item == here or (Model.is_region(item) and item.t0 <= pos and pos < item.t1)
    if inside then
      screen.level(item == here and 15 or 5)
      screen.rect(0, y + 1, 1, ROW_H - 2)
      screen.fill()
    end
    local x = 3 + math.min(cache.depth[item] or 0, 4) * 3
    if Model.is_region(item) then
      screen.level(sel and 15 or 9)
      screen.rect(x, y + 2, 3, 3)
    else
      screen.level(sel and 15 or 7)
      screen.rect(x + 1, y + 1, 1, 5)
    end
    screen.fill()
    x = x + 6
    local tc = Export.tc(Model.start(item), long)
    screen.level(sel and 15 or 5)
    screen.move(x, y + 6)
    screen.text(tc)
    x = x + screen.text_extents(tc) + 4
    local text, lev
    if item.label ~= '' then
      text, lev = item.label, sel and 15 or 11
    elseif item.note:match('%S') then
      text, lev = first_line(item.note), sel and 12 or 6
    else
      text, lev = item.id, 3
    end
    -- a region with sound settings: a small note glyph before the note dot
    local right = 122
    if item.snd then
      right = 116
      screen.level(sel and 15 or 8)
      screen.rect(119, y + 1, 1, 5)
      screen.rect(117, y + 4, 2, 2)
      screen.fill()
    end
    screen.level(lev)
    screen.move(x, y + 6)
    screen.text(util.trim_string_to_width(text, right - x))
    -- a note to read (beyond what the row shows)
    if item.note:match('%S') then
      screen.level(sel and 15 or 6)
      screen.rect(123, y + 2, 2, 3)
      screen.fill()
    end
  end
  if #list > ROWS then
    local h = math.max(3, math.floor(ROWS * ROW_H * ROWS / #list))
    local y0 = TOP + math.floor((ROWS * ROW_H - h) * (R.top - 1) / (#list - ROWS))
    screen.level(4)
    screen.rect(127, y0, 1, h)
    screen.fill()
  end
  screen.font_face(1)
  screen.font_size(8)
end

return R

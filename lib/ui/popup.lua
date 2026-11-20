-- popup: layers over the tape view (docs/PLAN.md §4): 112×52 px, a 1 px bright
-- frame, the screen behind dimmed
--
-- Three kinds:
--   item    the mark or region under the playhead: label, note, tags, times,
--           delete. E2 row, E3 value, K3 edit, K2 close.
--   editor  a note, word-wrapped, with a cursor. Typed on a USB keyboard
--           (lib/keys.lua sends the keys here); on the device K3 opens
--           textentry with the whole note. K2 close.
--   reader  a mark or region to read (the regions page): label, tags and the
--           whole note, word-wrapped. E2 line, E3 page, K3 edit (the item
--           popup), K1+K2 loop the region, K2 close.

local textentry = require 'textentry'
-- the same Model and Store instances as lib/annot (include runs a file anew
-- each time, so a second include would be a second, empty store)
local Model, Store

local P = {}

local X, Y, W, H = 8, 6, 112, 52
local TX, TW = X + 4, W - 8     -- text area
local ROWS_Y = Y + 18           -- first row baseline
local ROW_H = 8
local NROWS = 4                 -- rows below the title
local LINES = 6                 -- editor lines below the title
local LINE_H = 6
local LINES_Y = Y + 18          -- first editor baseline

-- what people write (labels, notes, tags) is drawn in tom-thumb: the norns
-- font has no ä, ö, å
local function ui_font() screen.font_face(1) screen.font_size(8) end
local function text_font() screen.font_face(25) screen.font_size(6) end
P.text_font = text_font

local Tape, Annot
local layer = nil -- nil | { kind = 'item' | 'editor', ... }
P.modal = false   -- textentry is open

function P.init(tape, annot)
  Tape, Annot = tape, annot
  Model, Store = annot.Model, annot.Store
end

function P.active() return layer ~= nil end
function P.kind() return layer and layer.kind end
function P.item() return layer and layer.item end
function P.layer() return layer end

function P.close()
  -- back to the popup it came from (editor → item → reader)
  layer = layer and layer.back or nil
  Tape.dirty = true
end

---- text

local function utf8_prev(s, c) -- byte position before the char ending at c
  if c <= 0 then return 0 end
  c = c - 1
  while c > 0 do
    local b = s:byte(c + 1)
    if b < 0x80 or b >= 0xC0 then break end
    c = c - 1
  end
  return c
end

local function utf8_next(s, c)
  if c >= #s then return #s end
  c = c + 1
  while c < #s do
    local b = s:byte(c + 1)
    if b < 0x80 or b >= 0xC0 then break end
    c = c + 1
  end
  return c
end

local function width(s) return s == '' and 0 or screen.text_extents(s) end -- in the current font

-- word wrap into lines { i0, i1 } (bytes, inclusive; a newline is in no line)
local wrap_cache = { text = nil, lines = nil }
local function wrap(text)
  if wrap_cache.text == text then return wrap_cache.lines end
  local lines = {}
  local p = 1
  while true do
    local nl = text:find('\n', p, true)
    local e = nl and nl - 1 or #text
    -- one paragraph: bytes p..e
    local i0 = p
    local q = p
    local last_fit = nil -- end of the last word that fits on this line
    while q <= e do
      local ws, we = text:find('%S+%s*', q)
      if not ws or ws > e then break end
      we = math.min(we, e)
      if width(text:sub(i0, we):gsub('%s+$', '')) <= TW then
        last_fit = we
        q = we + 1
      elseif last_fit then
        lines[#lines + 1] = { i0, last_fit }
        i0, last_fit = last_fit + 1, nil
        q = i0
      else
        -- one word wider than the line: break it by characters
        local c = i0 - 1
        while c < we and width(text:sub(i0, utf8_next(text, c))) <= TW do c = utf8_next(text, c) end
        if c < i0 then c = utf8_next(text, i0 - 1) end
        lines[#lines + 1] = { i0, c }
        i0 = c + 1
        q = i0
      end
    end
    lines[#lines + 1] = { i0, e }
    if not nl then break end
    p = nl + 1
  end
  wrap_cache.text, wrap_cache.lines = text, lines
  return lines
end

-- the last cursor position on line l: before the space a soft wrap broke
-- at (a cursor after it shows at the start of the next line)
local function line_end(text, lines, l)
  local ln, nx = lines[l], lines[l + 1]
  if nx and nx[1] == ln[2] + 1 and ln[2] >= ln[1] then return utf8_prev(text, ln[2]) end
  return ln[2]
end

-- the line holding cursor c (after c bytes): the last line starting at or before it
local function cursor_line(lines, c)
  local l = 1
  for i, ln in ipairs(lines) do
    if ln[1] - 1 <= c then l = i else break end
  end
  return l
end

---- drawing

local function frame_box()
  -- dim what is behind: multiply by a dark grey
  screen.blend_mode('multiply')
  screen.level(4)
  screen.rect(0, 0, 128, 64)
  screen.fill()
  screen.blend_mode('over')
  screen.level(0)
  screen.rect(X, Y, W, H)
  screen.fill()
  screen.level(15)
  screen.rect(X + 0.5, Y + 0.5, W - 1, H - 1)
  screen.stroke()
end

local function title(left, right)
  screen.level(15)
  screen.move(TX, Y + 9)
  screen.text(left)
  if right then
    screen.level(6)
    screen.move(X + W - 4, Y + 9)
    screen.text_right(right)
  end
  screen.level(3)
  screen.move(X + 2, Y + 11.5)
  screen.line(X + W - 2, Y + 11.5)
  screen.stroke()
end

local function hms(s)
  return Tape.hms(s, true)
end

local function item_rows(item)
  local rows = { 'label', 'note', 'tags' }
  if Model.is_region(item) then
    rows[#rows + 1] = 'in'
    rows[#rows + 1] = 'out'
  else
    rows[#rows + 1] = 'time'
  end
  rows[#rows + 1] = 'delete'
  return rows
end

local function first_line(s)
  s = s:match('^[^\n]*')
  return s
end

local function row_value(l, name)
  local item = l.item
  if name == 'label' then return item.label ~= '' and item.label or '-' end
  if name == 'note' then return item.note ~= '' and first_line(item.note) or '-' end
  if name == 'tags' then
    if l.rows[l.row] == 'tags' and #l.palette > 0 then
      local tag = l.palette[l.tag_i]
      return (Model.has_tag(item, tag) and '[x] ' or '[ ] ') .. tag
    end
    return #item.tags > 0 and table.concat(item.tags, ' ') or '-'
  end
  if name == 'in' then return hms(item.t0) end
  if name == 'out' then return hms(item.t1) end
  if name == 'time' then return hms(item.t) end
  if name == 'delete' then return l.confirm and 'K3 again' or '' end
  return ''
end

local function fmt_len(s)
  if s < 60 then return string.format('%.1f s', s) end
  if s < 3600 then return string.format('%d:%02d', s // 60, math.floor(s % 60)) end
  return string.format('%d:%02d:%02d', s // 3600, (s % 3600) // 60, math.floor(s % 60))
end

local function draw_item(l)
  local item = l.item
  local right = Model.is_region(item) and fmt_len(item.t1 - item.t0) or hms(item.t)
  title((Model.is_region(item) and 'REGION ' or 'MARK ') .. item.id, right)
  local top = util.clamp(l.row - NROWS + 1, 1, math.max(1, l.row))
  top = math.min(top, math.max(1, #l.rows - NROWS + 1))
  if l.row < top then top = l.row end
  l.top = top
  for i = 0, NROWS - 1 do
    local r = top + i
    local name = l.rows[r]
    if not name then break end
    local y = ROWS_Y + i * ROW_H
    local sel = r == l.row
    ui_font()
    screen.level(sel and 15 or 4)
    screen.move(TX, y)
    screen.text(name)
    local v = row_value(l, name)
    if name == 'label' or name == 'note' or name == 'tags' then text_font() end
    screen.level(sel and 15 or 8)
    screen.move(TX + 28, y)
    screen.text(util.trim_string_to_width(v, TW - 30))
  end
  -- scroll hint
  if #l.rows > NROWS then
    screen.level(4)
    local h = math.max(3, math.floor((H - 16) * NROWS / #l.rows))
    local y0 = Y + 14 + math.floor((H - 16 - h) * (top - 1) / (#l.rows - NROWS))
    screen.rect(X + W - 3, y0, 1, h)
    screen.fill()
  end
end

local function blink_phase() return math.floor(util.time() * 2) % 2 end

local function draw_editor(l)
  local item = l.item
  local text = item[l.field]
  title(item.id .. ' ' .. l.field:upper())
  text_font()
  local lines = wrap(text)
  l.cursor = util.clamp(l.cursor, 0, #text)
  local cl = cursor_line(lines, l.cursor)
  -- keep the cursor's line in view
  if cl < l.scroll then l.scroll = cl end
  if cl > l.scroll + LINES - 1 then l.scroll = cl - LINES + 1 end
  l.scroll = util.clamp(l.scroll, 1, math.max(1, #lines - LINES + 1))
  screen.level(12)
  for i = 0, LINES - 1 do
    local ln = lines[l.scroll + i]
    if not ln then break end
    local y = LINES_Y + i * LINE_H
    screen.move(TX, y)
    screen.text(text:sub(ln[1], ln[2]))
  end
  if text == '' then
    screen.level(4)
    screen.move(TX, LINES_Y)
    screen.text(l.hint or '')
  end
  -- cursor (blinks; solid while typing)
  if blink_phase() == 0 or util.time() - l.typed < 0.6 then
    local ln = lines[cl]
    local cx = TX + width(text:sub(ln[1], l.cursor))
    local cy = LINES_Y + (cl - l.scroll) * LINE_H
    if text == '' then cx = TX end
    screen.level(15)
    screen.rect(cx, cy - 5, 1, 6)
    screen.fill()
  end
  if #lines > LINES then
    screen.level(4)
    local h = math.max(3, math.floor((H - 14) * LINES / #lines))
    local y0 = Y + 13 + math.floor((H - 14 - h) * (l.scroll - 1) / (#lines - LINES))
    screen.rect(X + W - 3, y0, 1, h)
    screen.fill()
  end
end

-- the reader's text: label, tags, then the note; returns the text and the
-- byte ranges of the label and the tags (drawn at other levels)
local function reader_text(item)
  local parts, label_end, tags_from, tags_to = {}, 0, 0, -1
  if item.label ~= '' then
    parts[#parts + 1] = item.label:gsub('\n', ' ')
    label_end = #parts[1]
  end
  if #item.tags > 0 then
    local h = {}
    for i, tag in ipairs(item.tags) do h[i] = '#' .. tag end
    local s = table.concat(h, ' ')
    local before = #table.concat(parts, '\n')
    tags_from = before + (#parts > 0 and 2 or 1)
    tags_to = tags_from + #s - 1
    parts[#parts + 1] = s
  end
  if #parts > 0 then parts[#parts + 1] = '' end
  local note = item.note:gsub('%s+$', '')
  parts[#parts + 1] = note ~= '' and note or '(no note)'
  return table.concat(parts, '\n'), label_end, tags_from, tags_to, note == ''
end

local function draw_reader(l)
  local item = l.item
  local right = Model.is_region(item) and (hms(item.t0) .. ' ' .. fmt_len(item.t1 - item.t0)) or hms(item.t)
  title((Model.is_region(item) and 'R ' or 'M ') .. item.id, right)
  text_font()
  local text, label_end, tags_from, tags_to, empty = reader_text(item)
  local lines = wrap(text)
  l.nlines = #lines
  l.scroll = util.clamp(l.scroll, 1, math.max(1, #lines - LINES + 1))
  for i = 0, LINES - 1 do
    local ln = lines[l.scroll + i]
    if not ln then break end
    if ln[1] <= label_end then
      screen.level(15)
    elseif ln[1] >= tags_from and ln[1] <= tags_to + 1 then
      screen.level(6)
    elseif empty and ln[1] > math.max(label_end, tags_to) then
      screen.level(4)
    else
      screen.level(11)
    end
    screen.move(TX, LINES_Y + i * LINE_H)
    screen.text(text:sub(ln[1], ln[2]))
  end
  if #lines > LINES then
    screen.level(4)
    local h = math.max(3, math.floor((H - 14) * LINES / #lines))
    local y0 = Y + 13 + math.floor((H - 14 - h) * (l.scroll - 1) / (#lines - LINES))
    screen.rect(X + W - 3, y0, 1, h)
    screen.fill()
  end
end

function P.redraw()
  if not layer then return end
  screen.font_face(1)
  screen.font_size(8)
  frame_box()
  if layer.kind == 'item' then
    draw_item(layer)
  elseif layer.kind == 'reader' then
    draw_reader(layer)
  else
    draw_editor(layer)
  end
end

-- the editor's cursor blinks; returns true when a redraw is wanted
local last_phase = nil
function P.tick()
  if not layer then return false end
  if layer.jump_at and util.time() >= layer.jump_at then
    layer.jump_at = nil
    Tape.jump(layer.jump_to)
  end
  if layer.kind ~= 'editor' then return false end
  local ph = blink_phase()
  if ph ~= last_phase then
    last_phase = ph
    return true
  end
  return false
end

---- opening

function P.open_reader(item)
  if not item then return end
  layer = { kind = 'reader', item = item, scroll = 1, nlines = 0 }
  Tape.dirty = true
end

-- back: the popup to return to on close (the reader)
function P.open_item(item, back)
  local doc = Store.doc()
  if not doc or not item then return end
  local pal = Store.palette()
  local seen = {}
  for _, t in ipairs(pal) do seen[t] = true end
  for _, t in ipairs(Model.tags(doc)) do
    if not seen[t] then pal[#pal + 1] = t end
  end
  layer = { kind = 'item', item = item, rows = item_rows(item), row = 1, top = 1,
    palette = pal, tag_i = 1, confirm = false, back = back }
  Tape.dirty = true
end

function P.open_editor(item, field, back)
  if not item then return end
  layer = { kind = 'editor', item = item, field = field or 'note', cursor = #item[field or 'note'],
    scroll = 1, typed = 0, back = back, hint = 'type, or K3: text entry' }
  Tape.dirty = true
end

---- editing (the editor)

local function set_text(l, text, cursor)
  Model.set(Store.doc(), l.item, l.field, text)
  l.cursor = cursor
  l.typed = util.time()
  Tape.dirty = true
end

function P.insert(s)
  local l = layer
  if not l or l.kind ~= 'editor' then return end
  local text = l.item[l.field]
  set_text(l, text:sub(1, l.cursor) .. s .. text:sub(l.cursor + 1), l.cursor + #s)
end

function P.backspace()
  local l = layer
  if not l or l.kind ~= 'editor' or l.cursor == 0 then return end
  local text = l.item[l.field]
  local c = utf8_prev(text, l.cursor)
  set_text(l, text:sub(1, c) .. text:sub(l.cursor + 1), c)
end

function P.delete_char()
  local l = layer
  if not l or l.kind ~= 'editor' then return end
  local text = l.item[l.field]
  if l.cursor >= #text then return end
  set_text(l, text:sub(1, l.cursor) .. text:sub(utf8_next(text, l.cursor) + 1), l.cursor)
end

-- move the cursor: 'left' 'right' 'up' 'down' 'home' 'end'
function P.move(dir)
  local l = layer
  if not l or l.kind ~= 'editor' then return end
  local text = l.item[l.field]
  text_font()
  local lines = wrap(text)
  local cl = cursor_line(lines, l.cursor)
  local ln = lines[cl]
  if dir == 'left' then
    l.cursor = utf8_prev(text, l.cursor)
  elseif dir == 'right' then
    l.cursor = utf8_next(text, l.cursor)
  elseif dir == 'home' then
    l.cursor = ln[1] - 1
  elseif dir == 'end' then
    l.cursor = line_end(text, lines, cl)
  elseif dir == 'up' or dir == 'down' then
    local tl = cl + (dir == 'up' and -1 or 1)
    local target = lines[tl]
    if not target then
      l.cursor = dir == 'up' and 0 or #text
    else
      local x = width(text:sub(ln[1], l.cursor))
      local c, best = target[1] - 1, math.huge
      local p = target[1] - 1
      local last = line_end(text, lines, tl)
      while true do
        local d = math.abs(width(text:sub(target[1], p)) - x)
        if d < best then best, c = d, p end
        if p >= last then break end
        p = utf8_next(text, p)
      end
      l.cursor = c
    end
  end
  l.typed = util.time()
  Tape.dirty = true
end

local function edit_label(item, field, heading)
  P.modal = true
  textentry.enter(function(txt)
    P.modal = false
    if txt then Model.set(Store.doc(), item, field, txt) end
    Tape.dirty = true
  end, item[field], heading)
end

---- keys and encoders

function P.key(n, z, shift)
  local l = layer
  if not l or z == 0 then return end
  if l.kind == 'reader' then
    if n == 2 and shift then
      if Model.is_region(l.item) then Annot.loop_item(l.item) end
    elseif n == 2 then
      P.close()
    elseif n == 3 then
      P.open_item(l.item, l)
    end
    Tape.dirty = true
    return
  end
  if n == 2 then
    P.close()
    return
  end
  if n ~= 3 then return end
  if l.kind == 'editor' then
    edit_label(l.item, l.field, l.item.id .. ' ' .. l.field)
    return
  end
  local name = l.rows[l.row]
  if name ~= 'delete' then l.confirm = false end
  if name == 'label' then
    edit_label(l.item, 'label', l.item.id .. ' label')
  elseif name == 'note' then
    P.open_editor(l.item, 'note', l)
  elseif name == 'tags' then
    if #l.palette > 0 then Model.toggle_tag(Store.doc(), l.item, l.palette[l.tag_i]) end
  elseif name == 'in' or name == 'out' or name == 'time' then
    Tape.jump(name == 'out' and l.item.t1 or Model.start(l.item))
  elseif name == 'delete' then
    if l.confirm then
      Model.remove(Store.doc(), l.item)
      layer = nil
    else
      l.confirm = true
    end
  end
  Tape.dirty = true
end

function P.enc(n, d, shift)
  local l = layer
  if not l then return end
  if l.kind == 'reader' then
    local step = n == 3 and LINES - 1 or 1
    l.scroll = util.clamp(l.scroll + d * step, 1, math.max(1, l.nlines - LINES + 1))
    Tape.dirty = true
    return
  end
  if l.kind == 'editor' then
    if n == 2 then P.move(d > 0 and 'down' or 'up')
    elseif n == 3 then P.move(d > 0 and 'right' or 'left') end
    return
  end
  if n == 2 then
    l.row = util.clamp(l.row + d, 1, #l.rows)
    l.confirm = false
  elseif n == 3 then
    local name = l.rows[l.row]
    if name == 'tags' and #l.palette > 0 then
      l.tag_i = (l.tag_i - 1 + d) % #l.palette + 1
    elseif name == 'in' or name == 'out' or name == 'time' then
      -- 0.1 s a tick, 1 s with K1; audition the edge once the turning stops
      local field = name == 'in' and 't0' or name == 'out' and 't1' or 't'
      local step = shift and 1 or 0.1
      Model.move(Store.doc(), l.item, field, l.item[field] + d * step)
      l.jump_to = field == 't1' and math.max(l.item.t0, l.item.t1 - 2) or l.item[field]
      l.jump_at = util.time() + 0.3
    end
  end
  Tape.dirty = true
end

-- the document lost this item (deleted, another tape opened)
function P.reset()
  layer = nil
end

return P

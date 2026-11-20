-- tape popup: one tape of the collection (K1+K3 on the collection page)
--
--   file       the file (or reel) name
--   length     duration; a reel's number of parts
--   start      when the recording started (the wall clock): E3 ±1 min,
--              K1+E3 ±1 h, K3 type it (YYYY-MM-DD HH:MM:SS; empty: back to
--              the bext chunk). From bext when the file has one.
--   join       a single file: E3 how many of the next files in its folder
--              to join into a reel (ok = their bext says they continue it),
--              K3 twice: join
--   relink     a missing tape: K3 search dust/audio by name and size, E3
--              pick, K3 relink
--   forget     K3 twice: drop it from the list (its notes stay on disk)
--
-- K2 closes (a changed start time is saved then).

local textentry = require 'textentry'
local Wall = include 'lib/wallclock'
local Bext = include 'lib/bext'
local Reel = include 'lib/reel'

local TP = {}

local Tape, Annot, Shelf, Popup, Store, Model, Collection
local layer = nil
TP.modal = false

function TP.init(tape, annot, shelf, popup)
  Tape, Annot, Shelf, Popup = tape, annot, shelf, popup
  Store, Model, Collection = annot.Store, annot.Model, annot.Collection
end

function TP.active() return layer ~= nil end
function TP.layer() return layer end

local function first_file(e)
  if Reel.is(e.path) then
    local r = Reel.load(e.path, audio.file_info)
    return r and r.parts[1].path or nil
  end
  return e.path
end

local function bext_origin(e)
  local f = first_file(e)
  return f and Bext.origin(Bext.read(f)) or nil
end

-- the start time as stored: the open tape's document, else the index (or the
-- file's bext, for a tape not opened since)
local function current_origin(e)
  if Tape.st.path == e.path then return Tape.st.origin end
  if e.origin then return Wall.clean(e.origin) end
  return bext_origin(e)
end

local function rows_for(l)
  local rows = { 'file', 'length', 'start' }
  if l.missing then
    rows[#rows + 1] = 'relink'
  elseif not Reel.is(l.e.path) and l.cands and #l.cands > 1 then
    rows[#rows + 1] = 'join'
  end
  rows[#rows + 1] = 'forget'
  return rows
end

function TP.open(e)
  local missing = Shelf.missing(e)
  local cands, confirmed = nil, 0
  if not missing and not Reel.is(e.path) then cands, confirmed = Shelf.candidates(e.path) end
  layer = { e = e, missing = missing, cands = cands, confirmed = confirmed,
    join_n = confirmed, row = 1, confirm = nil, origin = current_origin(e), origin_dirty = false,
    found = nil, found_i = 1 }
  layer.rows = rows_for(layer)
  Tape.dirty = true
end

-- write a changed start time
local function commit_origin(l)
  if not l.origin_dirty then return end
  l.origin_dirty = false
  local e = l.e
  local o = l.origin
  if Tape.st.path == e.path then
    Annot.set_origin(o)
    return
  end
  local doc = Store.peek(e.path) or Model.new(e.path, e.dur, e.size)
  doc.tape.origin = o or bext_origin(e)
  local ok, err = Store.put(e.path, doc)
  if not ok then print('aurotate: start time not saved: ' .. tostring(err)) end
  e.origin = doc.tape.origin
  Collection.from_doc(doc)
  Collection.flush()
end

function TP.close()
  if layer then commit_origin(layer) end
  layer = nil
  Tape.dirty = true
end

function TP.reset() layer = nil end

---- drawing

local function fmt_len(s)
  s = math.floor(s or 0)
  if s < 3600 then return string.format('%d:%02d', s // 60, s % 60) end
  return string.format('%d:%02d:%02d', s // 3600, (s % 3600) // 60, s % 60)
end

local function name_of(p) return p:match('[^/]*$') end

local function row_value(l, name)
  local e = l.e
  if name == 'file' then return name_of(e.path) end
  if name == 'length' then
    local s = e.dur and fmt_len(e.dur) or '?'
    if e.parts and e.parts > 1 then s = s .. ' (' .. e.parts .. ' parts)' end
    if l.missing then s = s .. ' MISSING' end
    return s
  end
  if name == 'start' then
    if not l.origin then return '-' end
    return Wall.stamp(l.origin):sub(1, 16)
  end
  if name == 'join' then
    if l.confirm == 'join' then return 'K3: join ' .. (l.join_n + 1) end
    if l.join_n == 0 then return 'no (E3: more)' end
    return '+' .. l.join_n .. (l.join_n == 1 and ' file' or ' files') .. (l.join_n <= l.confirmed and ' ok' or '')
  end
  if name == 'relink' then
    if l.confirm == 'relink' then return 'K3 again' end
    if not l.found then return 'K3: search' end
    if #l.found == 0 then return 'not found' end
    return l.found_i .. '/' .. #l.found .. ' ' .. l.found[l.found_i]:sub(#_path.audio + 1)
  end
  if name == 'forget' then return l.confirm == 'forget' and 'K3 again' or '' end
  return ''
end

function TP.redraw()
  local l = layer
  if not l then return end
  local G = Popup.GEOM
  screen.font_face(1)
  screen.font_size(8)
  Popup.frame_box()
  -- the title's right side explains the selected row
  local name = l.rows[l.row]
  local right = l.missing and 'MISSING' or (l.e.parts and (l.e.parts .. ' PARTS') or nil)
  if name == 'start' and l.origin then
    right = l.origin.source == 'bext' and 'FROM FILE' or 'BY HAND'
  elseif name == 'join' and l.join_n > 0 then
    right = name_of(l.cands[l.join_n + 1].path):upper()
  end
  Popup.title('TAPE', right)
  local top = util.clamp(l.row - G.NROWS + 1, 1, math.max(1, #l.rows - G.NROWS + 1))
  if l.row < top then top = l.row end
  for i = 0, G.NROWS - 1 do
    local r = top + i
    local name = l.rows[r]
    if not name then break end
    local y = G.ROWS_Y + i * G.ROW_H
    local sel = r == l.row
    Popup.ui_font()
    screen.level(sel and 15 or 4)
    screen.move(G.TX, y)
    screen.text(name)
    Popup.text_font()
    screen.level(sel and 15 or 8)
    screen.move(G.TX + 34, y)
    screen.text(util.trim_string_to_width(row_value(l, name), G.TW - 36))
  end
  if #l.rows > G.NROWS then
    screen.level(4)
    local h = math.max(3, math.floor((G.H - 16) * G.NROWS / #l.rows))
    local y0 = G.Y + 14 + math.floor((G.H - 16 - h) * (top - 1) / (#l.rows - G.NROWS))
    screen.rect(G.X + G.W - 3, y0, 1, h)
    screen.fill()
  end
  Popup.ui_font()
end

---- keys and encoders

-- a guess for a tape with no start time: the file's time stamp minus its
-- length (recorders stamp a file when they close it)
local function guess_origin(e)
  local f = first_file(e)
  if not f then return nil end
  local mtime = tonumber(util.os_capture('stat -L -c %Y ' .. "'" .. f:gsub("'", "'\\''") .. "'"))
  if not mtime then return nil end
  local t = mtime - math.floor(e.dur or 0)
  return Wall.parse(os.date('%Y-%m-%d %H:%M:%S', t))
end

local function edit_origin(l)
  local cur = l.origin or guess_origin(l.e)
  TP.modal = true
  textentry.enter(function(txt)
    TP.modal = false
    if txt then
      -- empty: back to what the file's bext says (nil)
      local o = Wall.parse(txt)
      if o or txt:match('^%s*$') then
        l.origin, l.origin_dirty = o, true
        commit_origin(l)
        l.origin = current_origin(l.e)
      end
    end
    Tape.dirty = true
  end, cur and Wall.stamp(cur) or '', 'start (YYYY-MM-DD HH:MM:SS)', function(txt)
    if txt:match('^%s*$') then return 'empty: from the file' end
    return Wall.parse(txt) == nil and 'not a date and time' or nil
  end)
end

function TP.key(n, z, shift)
  local l = layer
  if not l or z == 0 then return end
  if n == 2 then
    TP.close()
    return
  end
  if n ~= 3 then return end
  local name = l.rows[l.row]
  if name ~= l.confirm then l.confirm = nil end
  if name == 'start' then
    edit_origin(l)
  elseif name == 'join' then
    if l.join_n == 0 then return end
    if l.confirm == 'join' then
      local paths = {}
      for i = 1, l.join_n + 1 do paths[i] = l.cands[i].path end
      local reel, err = Shelf.join(paths, false)
      layer = nil
      if not reel then print('aurotate: join failed: ' .. tostring(err)) end
      TP.on_done(reel and 'JOINED' or 'JOIN FAILED', reel)
    else
      l.confirm = 'join'
    end
  elseif name == 'relink' then
    if not l.found then
      l.found = Shelf.find_moved(l.e)
      l.found_i = 1
    elseif #l.found > 0 then
      if l.confirm == 'relink' then
        local ok, err = Shelf.relink(l.e, l.found[l.found_i])
        layer = nil
        if not ok then print('aurotate: relink failed: ' .. tostring(err)) end
        TP.on_done(ok and 'RELINKED' or ('RELINK: ' .. tostring(err)):upper(), ok and l.e.path or nil)
      else
        l.confirm = 'relink'
      end
    end
  elseif name == 'forget' then
    if l.confirm == 'forget' then
      local ok = Shelf.forget(l.e)
      layer = nil
      TP.on_done(ok and 'FORGOTTEN' or 'IT IS OPEN')
    else
      l.confirm = 'forget'
    end
  end
  Tape.dirty = true
end

-- the collection page sets this: a message, and the path to select
TP.on_done = function(msg, path) end

function TP.enc(n, d, shift)
  local l = layer
  if not l then return end
  if n == 2 then
    local was = l.rows[l.row]
    l.row = util.clamp(l.row + d, 1, #l.rows)
    if l.rows[l.row] ~= was then
      l.confirm = nil
      if was == 'start' then commit_origin(l) end
    end
  elseif n == 3 then
    local name = l.rows[l.row]
    if name == 'start' then
      local o = l.origin or guess_origin(l.e)
      if o then
        l.origin = Wall.shift(o, d * (shift and 3600 or 60))
        l.origin_dirty = true
      end
    elseif name == 'join' then
      l.join_n = util.clamp(l.join_n + d, 0, #l.cands - 1)
      l.confirm = nil
    elseif name == 'relink' and l.found and #l.found > 0 then
      l.found_i = util.clamp(l.found_i + d, 1, #l.found)
      l.confirm = nil
    end
  end
  Tape.dirty = true
end

return TP

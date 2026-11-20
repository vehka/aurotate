-- shelf: what the collection page does to tapes (docs/PLAN.md §4.2, §6.1)
--
--   join     several files (recorder split files) become one reel: a .reel
--            file next to them; the parts' notes move onto the reel
--   relink   a tape whose file moved: find it by name and size under
--            dust/audio, move its notes and analysis cache along
--   forget   drop a tape from the list (its notes stay on disk)
--   hint     on opening a single file: does the next file continue it?
--
-- Glue over Collection, Store, Reel and Analysis; the UI is
-- lib/ui/collection.lua and lib/ui/tape_popup.lua.

local Reel = include 'lib/reel'
local Bext = include 'lib/bext'
local Analysis = include 'lib/analysis'

local Shelf = {}

local Tape, Annot, Collection, Store, Model

function Shelf.init(tape, annot)
  Tape, Annot = tape, annot
  Collection, Store, Model = annot.Collection, annot.Store, annot.Model
end

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function file_size(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local n = f:seek('end')
  f:close()
  return n
end

function Shelf.exists(path) return path ~= nil and util.file_exists(path) end

-- an entry's file is there (for a reel: the reel file and every part)
function Shelf.missing(e)
  if not Shelf.exists(e.path) then return true end
  if Reel.is(e.path) then
    local r = Reel.load(e.path, audio.file_info)
    return r == nil
  end
  return false
end

---- join

-- the files that may continue `path` (lib/reel.lua: candidates)
function Shelf.candidates(path)
  return Reel.candidates(path, util.scandir, audio.file_info, Bext.read)
end

-- join `paths` (in order) into a new reel next to the first; the notes of
-- each part move onto the reel at its offset. Returns the reel path, or nil
-- and a reason. Opens the reel when `open` is set.
function Shelf.join(paths, open)
  if #paths < 2 then return nil, 'nothing to join' end
  local dir = paths[1]:match('^(.*/)')
  local reel_path = Reel.new_path(paths[1], util.file_exists)
  local f, err = io.open(reel_path, 'w')
  if not f then return nil, tostring(err) end
  f:write(Reel.text(paths, dir))
  f:close()
  local reel, rerr = Reel.load(reel_path, audio.file_info)
  if not reel then
    os.remove(reel_path)
    return nil, rerr
  end
  -- the open tape may be one of the parts: leave it first, so its notes are
  -- on disk and its document isn't the open one
  local reopen = false
  for _, p in ipairs(paths) do
    if Tape.st.path == p then reopen = true end
  end
  if reopen then
    Annot.leave()
    Tape.st.path = nil
  end
  -- carry the parts' notes over
  local doc = Model.new(reel_path, reel.frames / reel.rate, file_size(reel_path))
  doc.tape.title = reel_path:match('[^/]*$'):gsub('%.%w+$', '')
  local moved = 0
  for i, part in ipairs(reel.parts) do
    local d = Store.peek(part.path)
    if d then
      moved = moved + Model.append(doc, d, part.start / reel.rate)
      if i == 1 and d.tape.last_pos then doc.tape.last_pos = d.tape.last_pos end
      if i == 1 and d.tape.origin and d.tape.origin.source == 'manual' then doc.tape.origin = d.tape.origin end
    end
  end
  if moved > 0 or doc.tape.origin then
    local ok, werr = Store.put(reel_path, doc)
    if not ok then print('aurotate: join: notes not saved: ' .. tostring(werr)) end
  end
  -- the parts leave the shelf; the reel takes the first part's place
  local first = Collection.find(paths[1])
  local opened = first and first.opened or os.time()
  for _, p in ipairs(paths) do Collection.remove(p) end
  Collection.update(reel_path, { title = doc.tape.title, dur = reel.frames / reel.rate, parts = #paths,
    marks = #doc.marks, regions = #doc.regions, opened = opened, size = doc.tape.size })
  Collection.flush()
  print(string.format('aurotate: joined %d files into %s (%d notes carried over)', #paths, reel_path, moved))
  if open or reopen then params:set('aur_file', reel_path) end
  return reel_path, moved
end

---- relink

-- where a missing tape went: files under dust/audio with its name and (when
-- known) its size. Returns a list of paths.
function Shelf.find_moved(e)
  local name = e.path:match('[^/]*$')
  local out = {}
  local list = util.os_capture('find ' .. q(_path.audio) .. ' -type f -name ' .. q(name) .. ' 2> /dev/null', true) or ''
  for p in list:gmatch('[^\n]+') do
    if p ~= e.path and (not e.size or file_size(p) == e.size) then out[#out + 1] = p end
  end
  return out
end

-- move a tape's notes, analysis cache and entry to `new`
function Shelf.relink(e, new)
  local old = e.path
  if Tape.st.path == old then return nil, 'tape is open' end
  local ok, err = Store.move(old, new)
  if not ok and err ~= 'no notes' then return nil, err end
  -- the analysis cache is keyed by path, size and time: rename it when the
  -- file kept its size and time (a move), else it is redone on open
  if e.cache and util.file_exists(e.cache .. 'done') then
    local parts = nil
    if Reel.is(new) then
      local r = Reel.load(new, audio.file_info)
      if r then
        parts = {}
        for i, p in ipairs(r.parts) do parts[i] = p.path end
      end
    end
    local to = Analysis.cache_dir(new, parts)
    if to ~= e.cache and not util.file_exists(to) then
      os.execute('mv ' .. q(e.cache:gsub('/$', '')) .. ' ' .. q(to:gsub('/$', '')))
      e.cache = to
    end
  end
  Collection.rename(old, new)
  Collection.flush()
  print('aurotate: relinked ' .. old .. ' -> ' .. new)
  return true
end

---- forget

function Shelf.forget(e)
  if Tape.st.path == e.path then return false end
  Collection.remove(e.path)
  Collection.flush()
  return true
end

---- hint

-- a single file that the next file in its folder continues (by bext): how
-- many files the reel would have, else nil
function Shelf.split_hint(path)
  if Reel.is(path) then return nil end
  local list, confirmed = Shelf.candidates(path)
  if confirmed > 0 then return confirmed + 1, list end
  return nil
end

return Shelf

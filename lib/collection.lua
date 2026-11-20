-- collection: the tapes you work with, the "archive shelf" (docs/PLAN.md §4.2)
--
--   <data>/collection.lua   the index: one entry per tape (a file or a reel)
--
-- entry = { path, title, dur, opened (os.time), marks, regions, last_pos,
--           size, cache (the analysis cache dir), parts (reels), origin,
--           author, license (a downloaded tape's source) }
--
-- The index is a summary for the list, kept up to date when a tape opens and
-- when it is left; the tape documents (lib/store.lua) stay the truth. The
-- first time it is built from the documents already there. A tape whose file
-- is gone stays listed (shown missing) until it is relinked or forgotten.
--
-- Pure Lua apart from the file reads; `strip` reads the coarsest level of a
-- tape's peaks file (a few KB) for the overview strip.

local Collection = {}

local dir = nil
local entries = nil -- list, in no particular order
local dirty_at = nil
local serialise, read_lua, write_file

Collection.err = nil

function Collection.init(data_dir, store)
  dir = data_dir
  serialise, read_lua, write_file = store.serialise_value, store.read_lua, store.write_file
  entries = nil
end

local function index_path() return dir .. 'collection.lua' end

local function num(x) return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge end

local function clean(e)
  if type(e) ~= 'table' or type(e.path) ~= 'string' or e.path == '' then return nil end
  return {
    path = e.path,
    title = type(e.title) == 'string' and e.title or e.path:match('[^/]*$'):gsub('%.%w+$', ''),
    dur = num(e.dur) and e.dur or nil,
    opened = num(e.opened) and e.opened or 0,
    marks = num(e.marks) and e.marks or 0,
    regions = num(e.regions) and e.regions or 0,
    last_pos = num(e.last_pos) and e.last_pos or 0,
    size = num(e.size) and e.size or nil,
    cache = type(e.cache) == 'string' and e.cache or nil,
    parts = num(e.parts) and e.parts or nil,
    origin = type(e.origin) == 'table' and e.origin or nil,
    author = type(e.author) == 'string' and e.author or nil,
    license = type(e.license) == 'string' and e.license or nil,
  }
end

-- load the index; build it from the tape documents when there is none
-- (docs: { doc... } from Store, for that first time)
function Collection.load(docs_fn)
  if entries then return entries end
  entries = {}
  local t = read_lua(index_path())
  if type(t) == 'table' and type(t.tapes) == 'table' then
    for _, e in ipairs(t.tapes) do
      local c = clean(e)
      if c then entries[#entries + 1] = c end
    end
  elseif docs_fn then
    for _, doc in ipairs(docs_fn()) do
      local tape = doc.tape
      if tape.path then
        entries[#entries + 1] = clean({ path = tape.path, title = tape.title, dur = tape.dur,
          marks = #doc.marks, regions = #doc.regions, last_pos = tape.last_pos, size = tape.size,
          origin = tape.origin, author = tape.source and tape.source.author,
          license = tape.source and tape.source.license })
      end
    end
    if #entries > 0 then Collection.save() end
  end
  return entries
end

function Collection.entries() return Collection.load() end

function Collection.find(path)
  for i, e in ipairs(Collection.load()) do
    if e.path == path then return e, i end
  end
end

function Collection.save()
  dirty_at = nil
  if not entries then return end
  local ok, err = write_file(index_path(), '-- aurotate collection (an index; the tape documents are the truth)\nreturn '
    .. serialise({ version = 1, tapes = entries }) .. '\n')
  Collection.err = not ok and tostring(err) or nil
  return ok
end

-- schedule a save (several updates in a row make one write)
local function touch(now) dirty_at = now or os.time() end

function Collection.tick(now)
  if dirty_at and (now or os.time()) - dirty_at >= 1 then Collection.save() end
end

function Collection.flush() if dirty_at then Collection.save() end end

-- add or update the entry for a tape; fields: anything in an entry
function Collection.update(path, fields, now)
  local e = Collection.find(path)
  if not e then
    e = clean({ path = path })
    entries[#entries + 1] = e
  end
  for k, v in pairs(fields) do e[k] = v end
  touch(now)
  return e
end

-- the entry's counts and position from an open document
function Collection.from_doc(doc, now)
  if not doc or not doc.tape.path then return end
  local t = doc.tape
  local e = Collection.update(t.path, { title = t.title ~= '' and t.title or nil, dur = t.dur,
    marks = #doc.marks, regions = #doc.regions, last_pos = t.last_pos or 0, size = t.size }, now)
  e.origin = t.origin
  e.author = t.source and t.source.author or nil
  e.license = t.source and t.source.license or nil
  return e
end

function Collection.remove(path)
  local _, i = Collection.find(path)
  if i then
    table.remove(entries, i)
    touch()
  end
  return i ~= nil
end

-- move an entry to a new path (relink, a reel replacing its first part)
function Collection.rename(old, new)
  local e = Collection.find(old)
  if not e then return nil end
  local other = Collection.find(new)
  if other and other ~= e then Collection.remove(new) end
  e.path = new
  touch()
  return e
end

---- sorting

Collection.SORTS = { 'recent', 'name', 'length' }

function Collection.sorted(how, exists)
  local list = {}
  for _, e in ipairs(Collection.load()) do list[#list + 1] = e end
  table.sort(list, function(a, b)
    if how == 'name' then
      local ta, tb = a.title:lower(), b.title:lower()
      if ta ~= tb then return ta < tb end
    elseif how == 'length' then
      local da, db = a.dur or 0, b.dur or 0
      if da ~= db then return da > db end
    else
      if a.opened ~= b.opened then return a.opened > b.opened end
    end
    return a.path < b.path
  end)
  return list
end

---- the overview strip

-- n columns of rms (0..1, normalised to the loudest) from the coarsest level
-- of a peaks file (tools/aurpeaks.c, AURPK2), reading only that level
function Collection.strip(peaks_path, n)
  local f = io.open(peaks_path, 'rb')
  if not f then return nil end
  local h = f:read(40)
  if not h or #h < 40 or h:sub(1, 6) ~= 'AURPK2' then
    f:close()
    return nil
  end
  local n0, _, n1, n2 = string.unpack('<I4I8I4I4', h, 21)
  local lv_n, off = n2, 40 + 4 * (n0 + n1)
  if n0 == 0 then -- still being written
    f:close()
    return nil
  end
  if n2 < n then lv_n, off = n1, 40 + 4 * n0 end
  if lv_n == 0 then
    f:close()
    return nil
  end
  f:seek('set', off)
  local s = f:read(4 * lv_n)
  f:close()
  if not s or #s < 4 * lv_n then return nil end
  local out, peak = {}, 1
  for c = 1, n do
    local i0 = math.floor((c - 1) * lv_n / n)
    local i1 = math.max(i0, math.floor(c * lv_n / n) - 1)
    local sum, k = 0, 0
    for i = i0, i1 do
      local r = s:byte(4 * i + 3)
      sum, k = sum + r * r, k + 1
    end
    local v = math.sqrt(sum / k)
    out[c] = v
    if v > peak then peak = v end
  end
  for c = 1, n do out[c] = out[c] / peak end
  return out
end

return Collection

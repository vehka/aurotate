-- model: the tape document, its marks and regions (docs/PLAN.md §3)
--
--   doc    = { version, tape = { path, size, dur, title, last_pos }, next_id,
--              marks = { mark... }, regions = { region... } }
--   mark   = { id = 'm3', t, label, note, tags = {}, created }
--   region = { id = 'r4', t0, t1, label, note, tags = {}, created,
--              snd = { dry, send_a, send_b, gain, pan, tone }? }  (lib/sound.lua)
--
-- Pure data, no norns calls, so it can be tested off the device. Lists stay
-- sorted by time (marks by t, regions by t0). Every change goes through a
-- function here and calls Model.changed(doc), which the store sets to
-- schedule a save.

local Sound = include 'lib/sound'

local Model = {}

Model.VERSION = 1
Model.MIN_REGION = 0.05 -- s; a shorter "region" is a slip of the key

Model.changed = function(doc) end

function Model.new(path, dur, size)
  return {
    version = Model.VERSION,
    tape = {
      path = path,
      size = size,
      dur = dur,
      title = path and path:match('[^/]*$'):gsub('%.%w+$', '') or '',
      last_pos = 0,
    },
    next_id = 1,
    marks = {},
    regions = {},
  }
end

function Model.is_region(item) return item ~= nil and item.t0 ~= nil end

-- start time (a mark's t, a region's t0)
function Model.start(item) return item.t0 or item.t end

local function new_id(doc, prefix)
  local n = doc.next_id
  doc.next_id = n + 1
  return prefix .. n
end

-- insert keeping `list` sorted by `key` (stable: after equal keys)
local function insert_sorted(list, item, key)
  local i = #list + 1
  while i > 1 and list[i - 1][key] > item[key] do i = i - 1 end
  table.insert(list, i, item)
end

local function resort(list, key)
  table.sort(list, function(a, b)
    if a[key] ~= b[key] then return a[key] < b[key] end
    return a.id < b.id
  end)
end

-- times are kept to the millisecond (positions come from float32 polls)
function Model.round(t) return math.floor(t * 1000 + 0.5) / 1000 end

local function clamp_t(doc, t)
  local dur = doc.tape.dur or math.huge
  return Model.round(math.max(0, math.min(t, dur)))
end

function Model.add_mark(doc, t, now)
  local m = { id = new_id(doc, 'm'), t = clamp_t(doc, t), label = '', note = '', tags = {}, created = now }
  insert_sorted(doc.marks, m, 't')
  Model.changed(doc)
  return m
end

-- nil when shorter than MIN_REGION
function Model.add_region(doc, a, b, now)
  a, b = clamp_t(doc, a), clamp_t(doc, b)
  if a > b then a, b = b, a end
  if b - a < Model.MIN_REGION then return nil end
  local r = { id = new_id(doc, 'r'), t0 = a, t1 = b, label = '', note = '', tags = {}, created = now }
  insert_sorted(doc.regions, r, 't0')
  Model.changed(doc)
  return r
end

function Model.find(doc, id)
  local list = id:sub(1, 1) == 'r' and doc.regions or doc.marks
  for i, item in ipairs(list) do
    if item.id == id then return item, i end
  end
end

function Model.remove(doc, item)
  local list = Model.is_region(item) and doc.regions or doc.marks
  for i, x in ipairs(list) do
    if x == item then
      table.remove(list, i)
      Model.changed(doc)
      return true
    end
  end
  return false
end

-- set a text field (label, note)
function Model.set(doc, item, field, value)
  if item[field] == value then return end
  item[field] = value
  Model.changed(doc)
end

-- move a mark (t) or a region edge (t0, t1); the edges can't cross
function Model.move(doc, item, field, t)
  t = clamp_t(doc, t)
  if field == 't0' then
    t = math.min(t, item.t1 - Model.MIN_REGION)
  elseif field == 't1' then
    t = math.max(t, item.t0 + Model.MIN_REGION)
  end
  t = math.max(0, t)
  if item[field] == t then return end
  item[field] = t
  if field == 't' then resort(doc.marks, 't') else resort(doc.regions, 't0') end
  Model.changed(doc)
end

-- a region's sound field (lib/sound.lua); clamped, and `snd` is dropped
-- when every field is back at its default
function Model.set_snd(doc, r, field, v)
  if Sound.DEFAULT[field] == nil then return end
  v = Sound.clamp(field, v)
  if Sound.get(r, field) == v then return end
  local s = r.snd or {}
  s[field] = v ~= Sound.DEFAULT[field] and v or nil
  r.snd = next(s) and s or nil
  Model.changed(doc)
end

function Model.reset_snd(doc, r)
  if not r.snd then return end
  r.snd = nil
  Model.changed(doc)
end

function Model.has_tag(item, tag)
  for _, x in ipairs(item.tags) do
    if x == tag then return true end
  end
  return false
end

function Model.toggle_tag(doc, item, tag)
  for i, x in ipairs(item.tags) do
    if x == tag then
      table.remove(item.tags, i)
      Model.changed(doc)
      return false
    end
  end
  item.tags[#item.tags + 1] = tag
  Model.changed(doc)
  return true
end

-- every tag used in the document, sorted
function Model.tags(doc)
  local seen, out = {}, {}
  for _, list in ipairs({ doc.marks, doc.regions }) do
    for _, item in ipairs(list) do
      for _, tag in ipairs(item.tags) do
        if not seen[tag] then
          seen[tag] = true
          out[#out + 1] = tag
        end
      end
    end
  end
  table.sort(out)
  return out
end

-- regions containing t, outermost (longest) first, as §3 combines them
function Model.regions_at(doc, t)
  local out = {}
  for _, r in ipairs(doc.regions) do
    if r.t0 > t then break end
    if t < r.t1 then out[#out + 1] = r end
  end
  table.sort(out, function(a, b)
    local la, lb = a.t1 - a.t0, b.t1 - b.t0
    if la ~= lb then return la > lb end
    return a.t0 < b.t0
  end)
  return out
end

-- the innermost (shortest) region containing t
function Model.innermost(doc, t)
  local best
  for _, r in ipairs(doc.regions) do
    if r.t0 > t then break end
    if t < r.t1 and (best == nil or r.t1 - r.t0 < best.t1 - best.t0) then best = r end
  end
  return best
end

-- the mark nearest t within `tol` seconds
function Model.mark_near(doc, t, tol)
  local best, bd = nil, tol
  for _, m in ipairs(doc.marks) do
    local d = math.abs(m.t - t)
    if d <= bd then best, bd = m, d end
    if m.t > t + tol then break end
  end
  return best
end

-- what "here" means for the popup and the keyboard: a mark close to the
-- playhead wins over the region it sits in
function Model.at(doc, t, tol)
  return Model.mark_near(doc, t, tol) or Model.innermost(doc, t)
end

---- loading: validation and migrations

-- migrations[v] turns a version v document into version v + 1
Model.migrations = {}

local function str(x) return type(x) == 'string' and x or '' end
local function num(x) return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge end

local function clean_snd(snd)
  if type(snd) ~= 'table' then return nil end
  local out = {}
  for _, f in ipairs(Sound.FIELDS) do
    local v = snd[f]
    if num(v) then
      v = Sound.clamp(f, v)
      if v ~= Sound.DEFAULT[f] then out[f] = v end
    end
  end
  return next(out) and out or nil
end

local function clean_tags(tags)
  local out, seen = {}, {}
  if type(tags) == 'table' then
    for _, tag in ipairs(tags) do
      if type(tag) == 'string' and tag ~= '' and not seen[tag] then
        seen[tag] = true
        out[#out + 1] = tag
      end
    end
  end
  return out
end

-- bring a loaded table up to date and drop anything malformed. Returns the
-- document, or nil and a reason. `dropped` counts the items left out.
function Model.validate(t)
  if type(t) ~= 'table' then return nil, 'not a table' end
  local v = t.version
  if type(v) ~= 'number' then return nil, 'no version' end
  if v > Model.VERSION then return nil, 'version ' .. v .. ' is newer than this script (' .. Model.VERSION .. ')' end
  while v < Model.VERSION do
    local m = Model.migrations[v]
    if not m then return nil, 'no migration from version ' .. v end
    t = m(t)
    v = v + 1
    t.version = v
  end
  local tape = type(t.tape) == 'table' and t.tape or {}
  local doc = Model.new(type(tape.path) == 'string' and tape.path or nil,
    num(tape.dur) and tape.dur or nil, num(tape.size) and tape.size or nil)
  doc.tape.title = str(tape.title)
  doc.tape.last_pos = num(tape.last_pos) and math.max(0, tape.last_pos) or 0
  local max_id, dropped, ids = 0, 0, {}
  local function take_id(id, prefix)
    if type(id) ~= 'string' or id:sub(1, 1) ~= prefix or ids[id] then return nil end
    local n = tonumber(id:sub(2))
    if not n or n ~= math.floor(n) then return nil end
    ids[id] = true
    max_id = math.max(max_id, n)
    return id
  end
  for _, m in ipairs(type(t.marks) == 'table' and t.marks or {}) do
    local id = type(m) == 'table' and take_id(m.id, 'm')
    if id and num(m.t) then
      doc.marks[#doc.marks + 1] = { id = id, t = math.max(0, m.t), label = str(m.label), note = str(m.note),
        tags = clean_tags(m.tags), created = num(m.created) and m.created or nil }
    else
      dropped = dropped + 1
    end
  end
  for _, r in ipairs(type(t.regions) == 'table' and t.regions or {}) do
    local id = type(r) == 'table' and take_id(r.id, 'r')
    if id and num(r.t0) and num(r.t1) and r.t1 > r.t0 then
      doc.regions[#doc.regions + 1] = { id = id, t0 = math.max(0, r.t0), t1 = r.t1, label = str(r.label),
        note = str(r.note), tags = clean_tags(r.tags), created = num(r.created) and r.created or nil,
        snd = clean_snd(r.snd) }
    else
      dropped = dropped + 1
    end
  end
  resort(doc.marks, 't')
  resort(doc.regions, 't0')
  doc.next_id = math.max(num(t.next_id) and math.floor(t.next_id) or 1, max_id + 1)
  return doc, nil, dropped
end

return Model

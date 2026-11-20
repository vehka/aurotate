-- store: tape documents on disk (docs/PLAN.md §3)
--
--   <data>/tapes/<name>-<fnv(path)>.lua   the document (plain Lua, `return {...}`)
--   <data>/tapes/<...>.lua.bak            the previous save
--   <data>/last_tape                      path of the tape open last
--   <data>/tags.lua                       the tag palette (user-editable)
--
-- Annotations are not PSET data: a PSET holds the tape's path (the aur_file
-- param), the document is found from it. Saves are debounced (Store.touch,
-- then Store.tick from a UI timer) and atomic (write .tmp, keep the old file
-- as .bak, rename). A document that can't be read is never overwritten: a
-- corrupt one is set aside, a newer one makes the store read-only.

local Model = include 'lib/model'

local Store = {}

Store.DEBOUNCE = 2 -- s after the last edit

Store.DEFAULT_TAGS = { 'interview', 'story', 'song', 'ritual', 'place', 'name', 'todo', 'private' }

local dir = nil      -- data dir, with trailing slash
local doc = nil      -- the open document
local doc_path = nil
local due = nil      -- time a save is due (nil: nothing pending)
local readonly = nil -- reason the open document must not be saved
local clock_fn = function() return os.time() end

Store.err = nil -- last error, for the UI

function Store.init(data_dir, now_fn)
  dir = data_dir
  if now_fn then clock_fn = now_fn end
  os.execute('mkdir -p ' .. Store.q(dir .. 'tapes'))
end

function Store.q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function fnv(s)
  local h = 0x811c9dc5
  for i = 1, #s do h = ((h ~ s:byte(i)) * 0x01000193) & 0xffffffff end
  return string.format('%08x', h)
end

-- the tape's id: its name plus a hash of the path, so two files with the same
-- name don't share notes, and editing the audio (mtime) doesn't lose them
function Store.id(path)
  local base = path:match('[^/]*$'):gsub('%.%w+$', ''):gsub('[^%w%-_]', '_'):sub(1, 40)
  return base .. '-' .. fnv(path)
end

function Store.path_of(path) return dir .. 'tapes/' .. Store.id(path) .. '.lua' end

---- serialising

-- keys written first, so a document reads top-down
local FIRST = { version = 1, id = 1, tape = 2, t = 2, t0 = 2, t1 = 3, label = 4, next_id = 5, marks = 6 }

local function is_ident(k) return type(k) == 'string' and k:match('^[%a_][%w_]*$') ~= nil end

local function ser_value(v, indent, out)
  local t = type(v)
  if t == 'string' then
    out[#out + 1] = string.format('%q', v)
  elseif t == 'number' then
    if math.type(v) == 'integer' then
      out[#out + 1] = tostring(v)
    elseif v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = '0'
    else
      out[#out + 1] = string.format('%.17g', v)
    end
  elseif t == 'boolean' then
    out[#out + 1] = tostring(v)
  elseif t == 'table' then
    local n = #v
    local keys = {}
    for k in pairs(v) do
      if not (math.type(k) == 'integer' and k >= 1 and k <= n) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      local pa, pb = FIRST[a] or 99, FIRST[b] or 99
      if pa ~= pb then return pa < pb end
      return tostring(a) < tostring(b)
    end)
    -- short lists of scalars (tags) on one line
    local flat = #keys == 0
    for i = 1, n do
      if type(v[i]) == 'table' then flat = false end
    end
    if flat then
      out[#out + 1] = '{'
      for i = 1, n do
        if i > 1 then out[#out + 1] = ', ' end
        ser_value(v[i], indent, out)
      end
      out[#out + 1] = '}'
      return
    end
    local inner = indent .. '  '
    out[#out + 1] = '{\n'
    for _, k in ipairs(keys) do
      out[#out + 1] = inner
      out[#out + 1] = is_ident(k) and k or ('[' .. string.format(type(k) == 'string' and '%q' or '%s', k) .. ']')
      out[#out + 1] = ' = '
      ser_value(v[k], inner, out)
      out[#out + 1] = ',\n'
    end
    for i = 1, n do
      out[#out + 1] = inner
      ser_value(v[i], inner, out)
      out[#out + 1] = ',\n'
    end
    out[#out + 1] = indent .. '}'
  else
    out[#out + 1] = 'nil'
  end
end

function Store.serialise(t)
  local out = { '-- aurotate tape document\nreturn ' }
  ser_value(t, '', out)
  out[#out + 1] = '\n'
  return table.concat(out)
end

-- a document file is data: loaded with an empty environment
local function read_lua(path)
  local f = io.open(path, 'r')
  if not f then return nil, 'missing' end
  local src = f:read('a')
  f:close()
  local chunk, err = load(src, '=' .. path, 't', {})
  if not chunk then return nil, err end
  local ok, t = pcall(chunk)
  if not ok then return nil, t end
  return t
end

local function write_file(path, s)
  local tmp = path .. '.tmp'
  local f, err = io.open(tmp, 'w')
  if not f then return false, err end
  local ok, werr = f:write(s)
  f:close()
  if not ok then
    os.remove(tmp)
    return false, werr
  end
  local old = io.open(path, 'r')
  if old then
    old:close()
    os.rename(path, path .. '.bak')
  end
  local rok, rerr = os.rename(tmp, path)
  if not rok then return false, rerr end
  return true
end

-- atomic write with a .bak of the old file (exports use it too)
Store.write_file = write_file

---- the open document

-- load the document for `path` (or start a new one). Returns the document
-- and a message when something was wrong (nil when all is well).
function Store.open(path, dur, size)
  Store.flush()
  doc, doc_path, due, readonly, Store.err = nil, Store.path_of(path), nil, nil, nil
  local msg = nil
  local t, err = read_lua(doc_path)
  local d, verr, dropped
  if t then d, verr, dropped = Model.validate(t) end
  if not d and err ~= 'missing' then
    local why = err or verr
    if verr and verr:find('newer', 1, true) then
      -- written by a later version of the script: read-only, never overwrite
      readonly = verr
      msg = 'notes are from a newer aurotate: read-only'
    else
      -- corrupt: set it aside and fall back to the previous save
      os.rename(doc_path, doc_path .. '.corrupt-' .. os.date('%Y%m%d-%H%M%S'))
      local bt, berr = read_lua(doc_path .. '.bak')
      if bt then d, verr, dropped = Model.validate(bt) end
      msg = d and 'notes damaged: restored the previous save' or 'notes damaged: starting empty'
      print('aurotate: ' .. doc_path .. ': ' .. tostring(why) .. (d and '' or ('; .bak: ' .. tostring(berr or verr))))
    end
    Store.err = msg
  end
  if d and dropped and dropped > 0 then
    msg = msg or (dropped .. ' damaged notes left out')
  end
  doc = d or Model.new(path, dur, size)
  -- the document follows the file: update what may have changed
  doc.tape.path = path
  doc.tape.dur = dur or doc.tape.dur
  doc.tape.size = size or doc.tape.size
  if not readonly then Store.set_last(path) end
  return doc, msg
end

function Store.doc() return doc end
function Store.readonly() return readonly end

-- schedule a save
function Store.touch()
  if doc and not readonly then due = clock_fn() + Store.DEBOUNCE end
end

-- true when a save is pending
function Store.pending() return due ~= nil end

function Store.save()
  due = nil
  if not doc or readonly then return false end
  local ok, err = write_file(doc_path, Store.serialise(doc))
  if not ok then
    Store.err = 'save failed: ' .. tostring(err)
    print('aurotate: ' .. Store.err)
    due = clock_fn() + 10 -- try again later
  else
    Store.err = nil
  end
  return ok
end

function Store.tick()
  if due and clock_fn() >= due then Store.save() end
end

function Store.flush()
  if due then Store.save() end
end

-- the last playing position, saved with the document (not on every poll)
function Store.set_pos(pos)
  if not doc or readonly then return end
  if math.abs((doc.tape.last_pos or 0) - pos) < 0.5 then return end
  doc.tape.last_pos = Model.round(pos)
  -- only worth a file when the tape has notes or a file already
  local f = io.open(doc_path, 'r')
  if f then f:close() end
  if f or #doc.marks + #doc.regions > 0 then Store.touch() end
end

function Store.close(pos)
  if pos then Store.set_pos(pos) end
  Store.flush()
  doc, doc_path, due, readonly = nil, nil, nil, nil
end

---- the last tape, the tag palette

function Store.set_last(path)
  local f = io.open(dir .. 'last_tape', 'w')
  if f then
    f:write(path, '\n')
    f:close()
  end
end

function Store.last()
  local f = io.open(dir .. 'last_tape', 'r')
  if not f then return nil end
  local s = f:read('l')
  f:close()
  return s ~= '' and s or nil
end

-- the palette for tagging on the device: tags.lua (a list of strings),
-- written with the defaults the first time
function Store.palette()
  local path = dir .. 'tags.lua'
  local t = read_lua(path)
  if type(t) ~= 'table' then
    t = Store.DEFAULT_TAGS
    local f = io.open(path, 'w')
    if f then
      f:write('-- aurotate tag palette: edit freely, one string per tag\n', 'return ')
      local out = {}
      ser_value(t, '', out)
      f:write(table.concat(out), '\n')
      f:close()
    end
  end
  local out = {}
  for _, tag in ipairs(t) do
    if type(tag) == 'string' and tag ~= '' then out[#out + 1] = tag end
  end
  return out
end

return Store

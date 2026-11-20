-- reel: several files played as one tape (docs/PLAN.md §6.1)
--
-- Field recorders split a long take into files of 2 or 4 GB. A reel joins
-- them again: a small text file `<name>.reel` next to the parts, one part
-- per line, in order, relative to the reel's folder (absolute paths work
-- too; lines starting with # are comments). Written by the collection's
-- join (lib/ui/tape_popup.lua), or by hand over SMB. The reel's path is the
-- tape's identity: its notes, analysis cache and PSET entry follow it.
--
-- All parts must have the same rate and channel count. Positions on the
-- tape run through the parts without a gap; the engine maps them back to
-- (part, offset) (lib/sc/AurTape.sc).
--
-- Pure Lua: file info, bext and folder listings are passed in, so the tests
-- run off the device.

local Bext = include 'lib/bext'

local Reel = {}

Reel.MAX_PARTS = 64
Reel.AUDIO = { wav = true, flac = true, aif = true, aiff = true, bwf = true, rf64 = true }

function Reel.is(path) return type(path) == 'string' and path:lower():match('%.reel$') ~= nil end

function Reel.is_audio(path)
  local ext = path:match('%.(%w+)$')
  return ext ~= nil and Reel.AUDIO[ext:lower()] == true
end

local function dir_of(path) return path:match('^(.*/)') or './' end
local function name_of(path) return path:match('[^/]*$') end

-- the part paths in a reel file's text (absolute)
function Reel.parse(text, dir)
  local out = {}
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    line = line:match('^%s*(.-)%s*$')
    if line ~= '' and line:sub(1, 1) ~= '#' then
      out[#out + 1] = line:sub(1, 1) == '/' and line or (dir .. line)
    end
  end
  return out
end

-- the reel file's text for these part paths (relative where they sit in `dir`)
function Reel.text(paths, dir)
  local o = { '# aurotate reel: these files play as one tape, in this order',
    '# (names relative to this folder; edit freely)' }
  for _, p in ipairs(paths) do
    if p:sub(1, #dir) == dir and not p:sub(#dir + 1):find('/', 1, true) then
      o[#o + 1] = p:sub(#dir + 1)
    else
      o[#o + 1] = p
    end
  end
  return table.concat(o, '\n') .. '\n'
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

-- info(path) → channels, frames, rate (norns: audio.file_info)
-- returns { path, parts = { { path, frames, start } }, frames, rate, ch }
-- or nil and a reason
function Reel.load(path, info)
  local text = read_file(path)
  if not text then return nil, "can't read " .. name_of(path) end
  local paths = Reel.parse(text, dir_of(path))
  if #paths == 0 then return nil, 'no parts in ' .. name_of(path) end
  if #paths > Reel.MAX_PARTS then return nil, 'more than ' .. Reel.MAX_PARTS .. ' parts' end
  local r = { path = path, parts = {}, frames = 0 }
  for i, p in ipairs(paths) do
    local ch, frames, rate = info(p)
    if not frames or frames <= 0 or not rate or rate <= 0 then
      return nil, 'part ' .. i .. ' missing: ' .. name_of(p), i
    end
    if i == 1 then
      r.ch, r.rate = ch, rate
    elseif ch ~= r.ch or rate ~= r.rate then
      return nil, 'part ' .. i .. ' differs (' .. ch .. ' ch, ' .. rate .. ' Hz)', i
    end
    r.parts[i] = { path = p, frames = frames, start = r.frames }
    r.frames = r.frames + frames
  end
  return r
end

-- does b continue a, by their bext time references? true / false, or nil
-- when either has none (most recorders that split write it)
function Reel.continues(ba, bb, frames_a)
  if not ba or not bb or not ba.time_ref or not bb.time_ref or ba.time_ref == 0 or bb.time_ref == 0 then
    return nil
  end
  local d = bb.time_ref - ba.time_ref
  -- a take over midnight: time_ref counts from midnight
  if d < 0 and ba.rate then d = d + 86400 * ba.rate end
  return math.abs(d - frames_a) <= 2
end

-- the files that may continue `path`: the ones after it in its folder (by
-- name), with the same format, up to the first that doesn't match.
-- list(dir) → names; info as in Reel.load; bext(path) → Bext.read (optional)
-- Returns { { path, frames, continuous = true | false | nil } } (the first
-- entry is `path` itself, continuous = nil) and how many in a row from the
-- start are confirmed by bext.
function Reel.candidates(path, list, info, bext, max)
  bext = bext or Bext.read
  max = max or 16
  local dir, me = dir_of(path), name_of(path)
  local names = {}
  for _, n in ipairs(list(dir) or {}) do
    if n:sub(-1) ~= '/' and Reel.is_audio(n) then names[#names + 1] = n end
  end
  table.sort(names)
  local ch, frames, rate = info(path)
  if not frames then return {}, 0 end
  local out = { { path = path, frames = frames } }
  local prev_b = bext(path)
  local prev_frames = frames
  local confirmed, chain = 0, true
  local after = false
  for _, n in ipairs(names) do
    if after then
      if #out > max then break end
      local p = dir .. n
      local c2, f2, r2 = info(p)
      if not f2 or c2 ~= ch or r2 ~= rate then break end
      local b = bext(p)
      local cont = Reel.continues(prev_b, b, prev_frames)
      out[#out + 1] = { path = p, frames = f2, continuous = cont }
      if chain and cont then confirmed = confirmed + 1 else chain = false end
      prev_b, prev_frames = b, f2
    elseif n == me then
      after = true
    end
  end
  return out, confirmed
end

-- a free name for a new reel of these parts: `<first part's name>.reel`
-- in its folder (with -2, -3 … when taken). exists(path) → bool
function Reel.new_path(first, exists)
  local dir = dir_of(first)
  local stem = name_of(first):gsub('%.%w+$', '')
  local p = dir .. stem .. '.reel'
  local k = 2
  while exists(p) do
    p = dir .. stem .. '-' .. k .. '.reel'
    k = k + 1
  end
  return p
end

return Reel

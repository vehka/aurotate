-- bext: the BWF `bext` chunk of a WAV file (EBU Tech 3285), for the wall
-- clock (docs/PLAN.md §6.2) and for telling recorder split files apart
-- (§6.1)
--
-- Bext.read(path) → { date = 'YYYY-MM-DD', time = 'HH:MM:SS',
--   time_ref = samples since midnight (integer) or nil, rate, channels,
--   frames, description, originator } or nil when the file has no bext.
-- Reads the chunk headers only (fmt, bext, ds64, data), never the audio.
-- RIFF and RF64 (files over 4 GB). Pure Lua: tests run off the device.

local Bext = {}

local unpack = string.unpack

-- a fixed-width text field: up to the first NUL, trailing spaces trimmed
local function field(s, i, n)
  local v = s:sub(i, i + n - 1)
  v = v:match('^[^%z]*')
  return (v:gsub('%s+$', ''))
end

-- parse the chunks of an open file. Returns the bext table (with the format
-- fields) or nil.
local function parse(f)
  local h = f:read(12)
  if not h or #h < 12 then return nil end
  local riff, wave = h:sub(1, 4), h:sub(9, 12)
  if (riff ~= 'RIFF' and riff ~= 'RF64') or wave ~= 'WAVE' then return nil end
  local out = {}
  local data_size = nil -- from ds64 (RF64)
  local have_bext = false
  for _ = 1, 64 do -- chunks before the audio; a sane file has a handful
    local c = f:read(8)
    if not c or #c < 8 then break end
    local id, len = c:sub(1, 4), unpack('<I4', c, 5)
    if id == 'ds64' then
      local b = f:read(len)
      if not b or #b < 16 then break end
      data_size = unpack('<I8', b, 9)
      if len % 2 == 1 then f:read(1) end
    elseif id == 'fmt ' then
      local b = f:read(len)
      if not b or #b < 16 then break end
      local _, ch, rate, _, align, bits = unpack('<I2I2I4I4I2I2', b)
      out.channels, out.rate, out.align, out.bits = ch, rate, align, bits
      if len % 2 == 1 then f:read(1) end
    elseif id == 'bext' then
      local b = f:read(len)
      if not b or #b < 346 then break end
      have_bext = true
      out.description = field(b, 1, 256)
      out.originator = field(b, 257, 32)
      out.date = field(b, 321, 10)
      out.time = field(b, 331, 8)
      local lo, hi = unpack('<I4I4', b, 339)
      local tr = lo + hi * 4294967296
      out.time_ref = tr
      if len % 2 == 1 then f:read(1) end
    elseif id == 'data' then
      local size = (len == 0xffffffff and data_size) or len
      if out.align and out.align > 0 then out.frames = size // out.align end
      break
    else
      if not f:seek('cur', len + (len % 2)) then break end
    end
  end
  if not have_bext then return nil end
  -- recorders write '-', ':', '.' or ' ' as separators: normalise
  local y, mo, d = out.date:match('^(%d%d%d%d)%D(%d%d)%D(%d%d)$')
  out.date = y and string.format('%s-%s-%s', y, mo, d) or nil
  local hh, mm, ss = out.time:match('^(%d%d)%D(%d%d)%D(%d%d)$')
  out.time = hh and string.format('%s:%s:%s', hh, mm, ss) or nil
  return out
end

function Bext.read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local ok, b = pcall(parse, f)
  f:close()
  return ok and b or nil
end

-- where the recording starts: { date, secs (since midnight), source }, or
-- nil. time_ref (exact, in samples) wins over the origination time (whole
-- seconds), when it is set and agrees with it to within a minute: some
-- recorders write time_ref 0, or time_ref from a free-running timecode.
function Bext.origin(b)
  if not b or not b.date then return nil end
  local secs = nil
  if b.time then
    local h, m, s = b.time:match('(%d+):(%d+):(%d+)')
    secs = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
  end
  if b.time_ref and b.time_ref > 0 and b.rate and b.rate > 0 then
    local tr = (b.time_ref / b.rate) % 86400
    if not secs or math.abs(tr - secs) < 60 then secs = tr end
  end
  if not secs then return nil end
  return { date = b.date, secs = secs, source = 'bext' }
end

return Bext

-- wallclock: the time of day on a tape (docs/PLAN.md §6.2)
--
-- A tape's origin is where its recording started:
--   origin = { date = 'YYYY-MM-DD', secs = seconds since midnight, source = 'bext' | 'manual' }
-- (from the BWF bext chunk, lib/bext.lua, or typed in the collection). A
-- position on the tape is then a date and a time of day; a recording that
-- runs past midnight moves on to the next date. Pure Lua.

local Wall = {}

local function valid_date(y, m, d)
  if not (y and m and d) or m < 1 or m > 12 or d < 1 or d > 31 then return false end
  local t = os.time({ year = y, month = m, day = d, hour = 12 })
  return t ~= nil and os.date('*t', t).day == d
end

-- 'YYYY-MM-DD HH:MM[:SS]' (also with '.', '/' or 'T' between) → origin, or nil
function Wall.parse(s, source)
  if type(s) ~= 'string' then return nil end
  local y, mo, d, rest = s:match('^%s*(%d%d%d%d)[%-./](%d%d?)[%-./](%d%d?)[%sT]+(.-)%s*$')
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if not valid_date(y, mo, d) then return nil end
  local h, m, sec = rest:match('^(%d%d?)[:.](%d%d)[:.](%d%d%.?%d*)$')
  if not h then
    h, m = rest:match('^(%d%d?)[:.](%d%d)$')
    sec = '0'
  end
  h, m, sec = tonumber(h), tonumber(m), tonumber(sec)
  if not h or h > 23 or m > 59 or sec >= 60 then return nil end
  return { date = string.format('%04d-%02d-%02d', y, mo, d), secs = h * 3600 + m * 60 + sec,
    source = source or 'manual' }
end

-- a stored origin, checked (documents are files anyone can edit)
function Wall.clean(o)
  if type(o) ~= 'table' or type(o.date) ~= 'string' or type(o.secs) ~= 'number' then return nil end
  if o.secs ~= o.secs or o.secs < 0 or o.secs >= 86400 then return nil end
  local y, m, d = o.date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
  if not y or not valid_date(tonumber(y), tonumber(m), tonumber(d)) then return nil end
  return { date = o.date, secs = o.secs, source = o.source == 'bext' and 'bext' or 'manual' }
end

-- the date `days` after 'YYYY-MM-DD'
local function add_days(date, days)
  if days == 0 then return date end
  local y, m, d = date:match('^(%d+)%-(%d+)%-(%d+)$')
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  return os.date('%Y-%m-%d', t + days * 86400)
end

-- the origin moved by `delta` seconds (either way, across dates); manual
function Wall.shift(o, delta)
  local t = o.secs + delta
  local days = math.floor(t / 86400)
  return { date = add_days(o.date, days), secs = t - days * 86400, source = 'manual' }
end

-- position `pos` (s) on a tape with this origin → date, seconds of that day
function Wall.at(o, pos)
  local t = o.secs + math.max(0, pos or 0)
  local days = math.floor(t / 86400)
  return add_days(o.date, days), t - days * 86400
end

local function clock(secs, frac)
  local whole = math.floor(secs)
  local s = string.format('%02d:%02d:%02d', whole // 3600, whole // 60 % 60, whole % 60)
  if frac then s = s .. string.format('.%d', math.floor((secs - whole) * 10)) end
  return s
end

-- 'HH:MM:SS' (frac: '.d') at position pos
function Wall.time(o, pos, frac)
  local _, secs = Wall.at(o, pos)
  return clock(secs, frac)
end

-- 'YYYY-MM-DD HH:MM:SS' at position pos (0: the origin itself)
function Wall.stamp(o, pos)
  local date, secs = Wall.at(o, pos or 0)
  return date .. ' ' .. clock(secs)
end

local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }

-- '3 Aug 2025' for the date at pos
function Wall.date_label(o, pos)
  local date = Wall.at(o, pos or 0)
  local y, m, d = date:match('^(%d+)%-(%d+)%-(%d+)$')
  return string.format('%d %s %s', tonumber(d), MONTHS[tonumber(m)], y)
end

return Wall

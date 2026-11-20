-- sound: per-region sound settings and how overlapping regions combine
-- (docs/PLAN.md §2.4, §3)
--
--   region.snd = { dry, send_a, send_b, gain, pan, tone }  (nil: neutral)
--
-- A field left out has its default; a region whose fields are all default
-- has no `snd` at all (Model.set_snd keeps it that way), so "has sound" is
-- `region.snd ~= nil`.
--
-- Overlapping regions combine (§3): dry multiplies, sends add (clipped to 1),
-- gain adds in dB, pan and tone add (clipped). The engine gets a list of
-- segments, each with one combined set: `Sound.segments(doc)`.
--
-- Pure Lua, no norns calls.

local Sound = {}

Sound.FIELDS = { 'dry', 'send_a', 'send_b', 'gain', 'pan', 'tone' }
Sound.DEFAULT = { dry = 1, send_a = 0, send_b = 0, gain = 0, pan = 0, tone = 0 }
Sound.MIN = { dry = 0, send_a = 0, send_b = 0, gain = -60, pan = -1, tone = -1 }
Sound.MAX = { dry = 1, send_a = 1, send_b = 1, gain = 12, pan = 1, tone = 1 }
Sound.OFF_DB = -60 -- gain at or below this is silence

function Sound.clamp(field, v)
  v = math.max(Sound.MIN[field], math.min(Sound.MAX[field], v))
  return math.floor(v * 1000 + 0.5) / 1000
end

function Sound.get(r, field)
  local s = r.snd
  local v = s and s[field]
  if v == nil then return Sound.DEFAULT[field] end
  return v
end

function Sound.has(r) return r.snd ~= nil end

-- "send-as-insert": the dry signal taken away and a send at full level, so
-- the region is heard only through that send's effects. Returns 'a', 'b' or nil.
function Sound.insert_send(r)
  if not r.snd or Sound.get(r, 'dry') > 0 then return nil end
  if Sound.get(r, 'send_a') >= 1 then return 'a' end
  if Sound.get(r, 'send_b') >= 1 then return 'b' end
  return nil
end

-- the settings heard where `list` (regions, outermost first) overlap
function Sound.combine(list)
  local c = { dry = 1, send_a = 0, send_b = 0, gain = 0, pan = 0, tone = 0 }
  for _, r in ipairs(list) do
    if r.snd then
      c.dry = c.dry * Sound.get(r, 'dry')
      c.send_a = c.send_a + Sound.get(r, 'send_a')
      c.send_b = c.send_b + Sound.get(r, 'send_b')
      local g = Sound.get(r, 'gain')
      c.gain = (g <= Sound.OFF_DB or c.gain <= Sound.OFF_DB) and Sound.OFF_DB or c.gain + g
      c.pan = c.pan + Sound.get(r, 'pan')
      c.tone = c.tone + Sound.get(r, 'tone')
    end
  end
  for _, f in ipairs(Sound.FIELDS) do c[f] = Sound.clamp(f, c[f]) end
  return c
end

function Sound.equal(a, b)
  for _, f in ipairs(Sound.FIELDS) do
    if a[f] ~= b[f] then return false end
  end
  return true
end

function Sound.neutral(c) return Sound.equal(c, Sound.DEFAULT) end

-- what the playhead hears along the tape: { { t0, t1, settings }... },
-- sorted, not overlapping, neutral stretches left out, equal neighbours
-- joined. Only regions with sound make boundaries.
function Sound.segments(doc)
  local rs, cuts, seen = {}, {}, {}
  for _, r in ipairs(doc.regions) do -- sorted by t0
    if r.snd then
      rs[#rs + 1] = r
      for _, t in ipairs({ r.t0, r.t1 }) do
        if not seen[t] then
          seen[t] = true
          cuts[#cuts + 1] = t
        end
      end
    end
  end
  table.sort(cuts)
  local out = {}
  for i = 1, #cuts - 1 do
    local a, b = cuts[i], cuts[i + 1]
    local here = {}
    for _, r in ipairs(rs) do
      if r.t0 > a then break end
      if r.t1 >= b then here[#here + 1] = r end
    end
    -- outermost (longest) first, as Model.regions_at
    table.sort(here, function(x, y)
      local lx, ly = x.t1 - x.t0, y.t1 - y.t0
      if lx ~= ly then return lx > ly end
      return x.t0 < y.t0
    end)
    local c = Sound.combine(here)
    if not Sound.neutral(c) then
      local last = out[#out]
      if last and last[2] == a and Sound.equal(last[3], c) then
        last[2] = b
      else
        out[#out + 1] = { a, b, c }
      end
    end
  end
  return out
end

-- for the popup: a short text per field
function Sound.format(field, v)
  if field == 'dry' or field == 'send_a' or field == 'send_b' then
    return string.format('%d%%', math.floor(v * 100 + 0.5))
  elseif field == 'gain' then
    if v <= Sound.OFF_DB then return 'off' end
    return string.format('%+.1f dB', v)
  elseif field == 'pan' then
    if math.abs(v) < 0.005 then return 'centre' end
    return string.format('%s %d', v < 0 and 'L' or 'R', math.floor(math.abs(v) * 100 + 0.5))
  elseif field == 'tone' then
    if math.abs(v) < 0.005 then return 'flat' end
    return string.format('%s %d', v < 0 and 'dark' or 'bright', math.floor(math.abs(v) * 100 + 0.5))
  end
  return tostring(v)
end

-- encoder steps per field: { fine (K1), normal }
Sound.STEP = {
  dry = { 0.01, 0.05 }, send_a = { 0.01, 0.05 }, send_b = { 0.01, 0.05 },
  gain = { 0.1, 0.5 }, pan = { 0.01, 0.05 }, tone = { 0.01, 0.05 },
}

return Sound

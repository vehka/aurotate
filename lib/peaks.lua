-- peaks: reader for the aurpeaks file (format in tools/aurpeaks.c)
--
-- The file stays one Lua string, read with string.byte while drawing; there
-- are no per-bin tables. Level 0 is 20 ms bins, level 1 ×16, level 2 ×256.

local Peaks = {}

local HDR = 40
local PER = { 1, 16, 256 }

-- returns a peaks object, or nil. A file still being written has n0 = 0 in its
-- header: its level 0 is counted from the size and it has no reduced levels.
function Peaks.load(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  if #s < HDR or s:sub(1, 6) ~= 'AURPK2' then return nil end
  local bin, rate, ch, n0, frames, n1, n2 = string.unpack('<I4I4I4I4I8I4I4', s, 9)
  local complete = n0 > 0
  if not complete then n0, n1, n2 = (#s - HDR) // 4, 0, 0 end
  return {
    s = s, bin = bin, rate = rate, ch = ch, frames = frames, complete = complete,
    n = { n0, n1, n2 },
    off = { HDR, HDR + 4 * n0, HDR + 4 * (n0 + n1) },
  }
end

-- `w` columns over [t0, t1) seconds. Returns three arrays of 0..1: peak
-- amplitude, rms, brightness (of the loudest bin). Uses the coarsest level
-- that still has a bin per column.
function Peaks.columns(p, t0, t1, w)
  local amp, rms, bright = {}, {}, {}
  local bins0 = (t1 - t0) * p.rate / p.bin -- level-0 bins in view
  local lv = 1
  for l = 3, 2, -1 do
    if p.n[l] > 0 and bins0 / PER[l] >= w then lv = l break end
  end
  local per, n, off, s = PER[lv], p.n[lv], p.off[lv], p.s
  local b0 = t0 * p.rate / p.bin / per
  local step = bins0 / per / w
  local byte = string.byte
  for x = 1, w do
    local a = math.floor(b0 + (x - 1) * step)
    local b = math.max(a, math.floor(b0 + x * step) - 1)
    local pk, r, br = 0, 0, 0
    if a < n then
      b = math.min(b, n - 1)
      for i = math.max(0, a), b do
        local o = off + 4 * i + 1
        local mn, mx, rr, bb = byte(s, o, o + 3)
        mn = mn >= 128 and 256 - mn or mn -- |min| (i8)
        mx = mx >= 128 and 0 or mx
        local v = math.max(mn, mx)
        if v > pk then pk = v end
        if rr > r then r, br = rr, bb end
      end
    end
    amp[x], rms[x], bright[x] = pk / 128, r / 255, br / 255
  end
  return amp, rms, bright
end

return Peaks

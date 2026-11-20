-- peaks: reader for the aurpeaks file (format in tools/aurpeaks.c)
--
-- The file stays one Lua string, read with string.byte while drawing; there
-- are no per-bin tables. Level 0 is 20 ms bins, level 1 ×16, level 2 ×256.

local Peaks = {}

local HDR = 40
local PER = { 1, 16, 256 }
-- bins read per column at most; more are sampled with a stride (only happens
-- while level 0 is all there is, i.e. during the analysis)
local MAX_READS = 24
local STAT_SAMPLES = 20000

local byte = string.byte

-- |min|, max, rms, bright of bin i (0-based) at byte offset `off`
local function rec(s, off, i)
  local o = off + 4 * i + 1
  local mn, mx, rr, bb = byte(s, o, o + 3)
  mn = mn >= 128 and 256 - mn or mn -- |min| (i8)
  mx = mx >= 128 and 0 or mx
  return mn > mx and mn or mx, rr, bb
end

-- per-tape display stats, from the coarsest level there is (sampled):
--   peak: loudest bin (0..1 of full scale), for normalising the height
--   rpeak: loudest rms (0..1), for normalising rms-only displays
--   blo, bhi: 5th and 95th percentile of brightness, weighted by rms, so the
--     brightness → level mapping spans what this tape actually contains
local function stats(p)
  local lv = p.n[3] > 0 and 3 or 1
  local n, off, s = p.n[lv], p.off[lv], p.s
  p.peak, p.rpeak, p.blo, p.bhi = 1, 1, 0, 1
  if n == 0 then return end
  local stride = math.max(1, n // STAT_SAMPLES)
  local hist, total, pk, rpk = {}, 0, 0, 0
  for i = 0, 255 do hist[i] = 0 end
  for i = 0, n - 1, stride do
    local v, rr, bb = rec(s, off, i)
    if v > pk then pk = v end
    if rr > rpk then rpk = rr end
    hist[bb] = hist[bb] + rr
    total = total + rr
  end
  -- level 0 is sampled, so its max may miss the loudest bin: fine for display
  p.peak = math.max(pk, 4) / 128
  p.rpeak = math.max(rpk, 4) / 255
  if total <= 0 then return end
  local acc, lo, hi = 0, nil, 255
  for i = 0, 255 do
    acc = acc + hist[i]
    if not lo and acc >= 0.05 * total then lo = i end
    if acc >= 0.95 * total then hi = i break end
  end
  lo = lo or 0
  if hi - lo < 16 then -- a nearly uniform tape: don't blow tiny differences up
    local c = (lo + hi) / 2
    lo, hi = math.max(0, c - 8), math.min(255, c + 8)
  end
  p.blo, p.bhi = lo / 255, hi / 255
end

-- returns a peaks object, or nil. A file still being written has n0 = 0 in its
-- header: its level 0 is counted from the size and it has no reduced levels.
function Peaks.load(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  if #s < HDR or s:sub(1, 6) ~= 'AURPK2' then return nil end
  local bin, rate, ch, n0, frames, n1, n2 = string.unpack('<I4I4I4I4I8I4I4', s, 9)
  if bin == 0 or rate == 0 then return nil end
  local complete = n0 > 0
  if not complete then n0, n1, n2 = (#s - HDR) // 4, 0, 0 end
  local p = {
    s = s, bin = bin, rate = rate, ch = ch, frames = frames, complete = complete,
    n = { n0, n1, n2 },
    off = { HDR, HDR + 4 * n0, HDR + 4 * (n0 + n1) },
  }
  p.secs = n0 * bin / rate -- seconds covered (grows during the analysis)
  stats(p)
  return p
end

-- `w` columns over [t0, t1) seconds. Fills (or returns new) three arrays of
-- 0..1: peak amplitude, rms (both of full scale) and brightness (of the
-- loudest bin, raw). Uses the coarsest level that still has a bin per column.
-- Column x covers bins [floor(b0 + (x-1)·step), floor(b0 + x·step)), so
-- columns on a fixed time grid give the same values every frame.
function Peaks.columns(p, t0, t1, w, amp, rms, bright)
  amp, rms, bright = amp or {}, rms or {}, bright or {}
  local bins0 = (t1 - t0) * p.rate / p.bin -- level-0 bins in view
  local lv = 1
  for l = 3, 2, -1 do
    if p.n[l] > 0 and bins0 / PER[l] >= w then lv = l break end
  end
  local per, n, off, s = PER[lv], p.n[lv], p.off[lv], p.s
  local b0 = t0 * p.rate / p.bin / per
  local step = bins0 / per / w
  local stride = math.max(1, math.floor(step / MAX_READS))
  for x = 1, w do
    local a = math.floor(b0 + (x - 1) * step + 1e-6)
    local b = math.max(a, math.floor(b0 + x * step + 1e-6) - 1)
    local pk, r, br = 0, 0, 0
    if a < n and b >= 0 then
      b = math.min(b, n - 1)
      for i = math.max(0, a), b, stride do
        local v, rr, bb = rec(s, off, i)
        if v > pk then pk = v end
        if rr > r then r, br = rr, bb end
      end
    end
    amp[x], rms[x], bright[x] = pk / 128, r / 255, br / 255
  end
  return amp, rms, bright
end

-- display helpers: height 0..1 (normalised to the tape, with a mild curve so
-- quiet speech still shows) and brightness 0..1 (stretched to the tape)
function Peaks.height(p, v)
  v = v / p.peak
  if v <= 0 then return 0 end
  return v >= 1 and 1 or v ^ 0.6
end

function Peaks.rms_height(p, v)
  v = v / p.rpeak
  if v <= 0 then return 0 end
  return v >= 1 and 1 or v ^ 0.6
end

function Peaks.bright(p, b)
  local x = (b - p.blo) / (p.bhi - p.blo)
  return x < 0 and 0 or (x > 1 and 1 or x)
end

return Peaks

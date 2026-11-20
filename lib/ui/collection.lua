-- collection: the first page, the tapes you work with (docs/PLAN.md §4.2)
--
--   E2       select
--   E3       sort: recent / name / length
--   K2       play / stop the open tape
--   K3       open the selected tape (and go to the tape page); on the last
--            row: add a tape (the add popup: file, URL, Freesound); on a
--            download: K3 twice cancels it (or drops a failed one)
--   K1+K3    the tape popup: start time, join split files, relink, forget
--
-- Downloads (lib/download.lua) are rows between the tapes and "+ add", with
-- an arrow, the name and the progress.
--
-- Rows: a bar at the left for the open tape, ≡ for a reel, the title, a dot
-- when it has notes, the length. Missing tapes are dim with a ?. Under the
-- list, the selected tape: its overview strip (from the analysis cache) with
-- the last position, and a line with its notes, start time and state.

local Draw = include 'lib/ui/draw'
local Wall = include 'lib/wallclock'
local Bext = include 'lib/bext'
local Reel = include 'lib/reel'
local Analysis = include 'lib/analysis'

local C = {}

local ROWS = 5
local ROW_H = 7
local TOP = 10
local STRIP_Y, STRIP_H = 48, 7

local Tape, Annot, Shelf, View, Collection, D
local draw_job
C.sel = 1
C.top = 1
C.sort = 1

-- per path: { missing, strip, origin, t } (looked up when shown, cached a while)
local info = {}
local INFO_TTL = 10

local list_cache = { rev = -1, sort = 0, n = -1, list = {} }

function C.init(tape, annot, shelf, view, download)
  Tape, Annot, Shelf, View, D = tape, annot, shelf, view, download
  Collection = annot.Collection
end

local function list()
  local entries = Collection.entries()
  -- rebuilt when the index changes size, the sort changes, or a tape opens
  local key = #entries .. '|' .. tostring(Tape.st.path)
  if list_cache.sort ~= C.sort or list_cache.key ~= key or list_cache.rev ~= C.rev then
    list_cache.list = Collection.sorted(Collection.SORTS[C.sort])
    list_cache.sort, list_cache.key, list_cache.rev = C.sort, key, C.rev
  end
  return list_cache.list
end
C.rev = 0
function C.changed() C.rev = C.rev + 1 end

local function count() return #list() + #D.jobs + 1 end -- + the downloads, the "add" row

function C.selected()
  return list()[C.sel]
end

-- the download on the selected row, if it is one
function C.selected_job()
  local n = #list()
  if C.sel > n then return D.jobs[C.sel - n] end
end

C.confirm = nil -- a job whose cancel waits for K3 again

local function clamp()
  C.sel = util.clamp(C.sel, 1, count())
  if C.sel < C.top then C.top = C.sel end
  if C.sel > C.top + ROWS - 1 then C.top = C.sel - ROWS + 1 end
  C.top = util.clamp(C.top, 1, math.max(1, count() - ROWS + 1))
end

-- coming to the page: select the open tape
function C.enter()
  for i, e in ipairs(list()) do
    if e.path == Tape.st.path then C.sel = i end
  end
  clamp()
  info = {}
end

function C.select_path(path)
  C.changed()
  for i, e in ipairs(list()) do
    if e.path == path then C.sel = i end
  end
  clamp()
end

function C.move(d)
  C.confirm = nil
  C.sel = util.clamp(C.sel + d, 1, count())
  clamp()
  Tape.dirty = true
end

function C.sort_turn(d)
  local keep = C.selected()
  C.sort = util.clamp(C.sort + d, 1, #Collection.SORTS)
  if keep then C.select_path(keep.path) end
  View.message('SORT ' .. Collection.SORTS[C.sort]:upper(), 1)
  Tape.dirty = true
end

-- K3: the tape opens; returns true when the page should change to the tape
function C.open()
  local e = C.selected()
  local job = C.selected_job()
  if job then
    if job.state == 'failed' then
      D.dismiss(job)
    elseif C.confirm == job then
      D.cancel(job)
      C.confirm = nil
      View.message('CANCELLED', 1)
    else
      C.confirm = job
      View.message('K3 AGAIN: CANCEL', 2)
    end
    clamp()
    return false
  end
  if not e then return 'add' end
  if Shelf.missing(e) then
    View.message('MISSING: K1+K3 RELINK', 2)
    return false
  end
  if e.path ~= Tape.st.path then
    params:set('aur_file', e.path)
    if Tape.st.path ~= e.path then
      View.message(('CAN\'T OPEN: ' .. (Tape.err or '?')):upper(), 3)
      return false
    end
  end
  return true
end

---- the selected tape's details

local function details(e)
  local d = info[e.path]
  local t = util.time()
  if d and t - d.t < INFO_TTL then return d end
  d = { t = t }
  d.missing = Shelf.missing(e)
  if not d.missing then
    local cache = e.cache
    if not cache then
      local parts = nil
      if Reel.is(e.path) then
        local r = Reel.load(e.path, audio.file_info)
        if r then
          parts = {}
          for i, p in ipairs(r.parts) do parts[i] = p.path end
        end
      end
      cache = Analysis.cache_dir(e.path, parts)
      e.cache = cache
    end
    d.strip = Collection.strip(cache .. 'peaks', Draw.W)
    if not e.origin then
      local first = e.path
      if Reel.is(e.path) then
        local r = Reel.load(e.path, audio.file_info)
        first = r and r.parts[1].path
      end
      d.origin = first and Bext.origin(Bext.read(first))
    end
  end
  info[e.path] = d
  return d
end

local function fmt_len(s)
  s = math.floor(s or 0)
  if s < 3600 then return string.format('%d:%02d', s // 60, s % 60) end
  return string.format('%d:%02d:%02d', s // 3600, (s % 3600) // 60, s % 60)
end

---- drawing

local function tiny() screen.font_face(25) screen.font_size(6) end
local function normal() screen.font_face(1) screen.font_size(8) end

local function job_state(job)
  local s = job.state
  if s == 'fetching' then return math.floor((job.progress or 0) * 100) .. '%' end
  if s == 'converting' then return 'convert' end
  if s == 'metadata' or s == 'login' or s == 'starting' then return '...' end
  return s
end

-- a download row: an arrow, its name, its state on the right
draw_job = function(job, y, sel)
  local failed = job.state == 'failed'
  screen.level(failed and 4 or (sel and 15 or 9))
  screen.move(4, y + 1)
  screen.line_rel(0, 4)
  screen.stroke()
  screen.rect(2, y + 4, 5, 1)
  screen.rect(3, y + 5, 3, 1)
  screen.fill()
  local right = job_state(job)
  screen.move(126, y + 6)
  screen.text_right(right)
  local w = screen.text_extents(right)
  screen.level(failed and 4 or (sel and 15 or 9))
  screen.move(9, y + 6)
  screen.text(util.trim_string_to_width(job.name or job.line, 126 - w - 4 - 9))
  -- the progress, a line under the row
  if job.state == 'fetching' and (job.progress or 0) > 0 then
    screen.level(sel and 8 or 4)
    screen.rect(9, y + ROW_H - 1, math.floor((117 - 9) * job.progress), 1)
    screen.fill()
  end
end

function C.redraw(page, pages)
  local st = Tape.st
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  local l = list()
  clamp()
  local state, slev = View.state_label(Tape, st)
  Draw.header(page, pages, Collection.SORTS[C.sort]:upper() .. ' ' .. #l, state, slev,
    st.path and Tape.clock(st.pos, true) or nil, 8)
  tiny()
  local doc = Annot.doc()
  for i = 0, ROWS - 1 do
    local k = C.top + i
    if k > count() then break end
    local y = TOP + i * ROW_H
    local sel = k == C.sel
    if sel then
      screen.level(2)
      screen.rect(0, y, 127, ROW_H)
      screen.fill()
    end
    local e = l[k]
    local job = not e and D.jobs[k - #l]
    if job then
      draw_job(job, y, sel)
    elseif not e then
      screen.level(sel and 15 or 5)
      screen.move(9, y + 6)
      screen.text('+ add a tape')
    else
      local open = e.path == st.path
      local missing = details(e).missing
      if open then
        screen.level(15)
        screen.rect(0, y + 1, 1, ROW_H - 2)
        screen.fill()
      end
      -- a reel: three short lines
      if e.parts and e.parts > 1 then
        screen.level(sel and 15 or 7)
        for j = 0, 2 do screen.rect(3, y + 1 + j * 2, 3, 1) end
        screen.fill()
      end
      local len = e.dur and fmt_len(e.dur) or ''
      local right = 126 - (len ~= '' and screen.text_extents(len) or 0)
      screen.level(missing and 3 or (sel and 15 or 6))
      screen.move(126, y + 6)
      screen.text_right(len)
      local marks = e.marks + e.regions
      if open and doc then marks = #doc.marks + #doc.regions end
      if marks > 0 then
        screen.level(sel and 15 or 6)
        screen.rect(right - 4, y + 2, 2, 3)
        screen.fill()
      end
      local title = (missing and '? ' or '') .. e.title
      screen.level(missing and 3 or (sel and 15 or (open and 12 or 9)))
      screen.move(9, y + 6)
      screen.text(util.trim_string_to_width(title, right - 6 - 9))
    end
  end
  if count() > ROWS then
    local h = math.max(3, math.floor(ROWS * ROW_H * ROWS / count()))
    local y0 = TOP + math.floor((ROWS * ROW_H - h) * (C.top - 1) / (count() - ROWS))
    screen.level(4)
    screen.rect(127, y0, 1, h)
    screen.fill()
  end
  -- the selected tape
  local e = l[C.sel]
  screen.level(2)
  screen.move(0, STRIP_Y - 1.5)
  screen.line(128, STRIP_Y - 1.5)
  screen.stroke()
  if e then
    local d = details(e)
    local open = e.path == st.path
    if d.strip then
      local h, lv = {}, {}
      for x = 1, Draw.W do
        local v = d.strip[x] or 0
        h[x] = math.floor(v * (STRIP_H - 1) / 2 + 0.5)
        lv[x] = 3 + math.floor(v * 6)
      end
      Draw.columns(0, STRIP_Y + STRIP_H // 2, Draw.W, h, lv)
    else
      screen.level(d.missing and 3 or 4)
      screen.move(64, STRIP_Y + 6)
      screen.text_center(d.missing and 'missing: K1+K3' or (open and Tape.analysis.state == 'running')
        and 'analysing' or 'not analysed yet')
    end
    -- where it was left (the playhead, when open)
    local pos = open and st.pos or e.last_pos
    if e.dur and e.dur > 0 and pos then
      local x = math.floor(pos / e.dur * (Draw.W - 1) + 0.5)
      screen.level(15)
      screen.rect(x, STRIP_Y - 1, 1, STRIP_H + 1)
      screen.fill()
    end
    -- notes · start time
    local marks, regions = e.marks, e.regions
    if open and doc then marks, regions = #doc.marks, #doc.regions end
    local origin = (open and st.origin) or Wall.clean(e.origin) or d.origin
    local parts = {}
    local n = marks + regions
    if n > 0 then parts[#parts + 1] = n .. (n == 1 and ' note' or ' notes') end
    if origin then parts[#parts + 1] = Wall.date_label(origin) .. ' ' .. Wall.time(origin, 0):sub(1, 5) end
    if e.author then parts[#parts + 1] = 'by ' .. e.author end
    if #parts == 0 then parts[1] = d.missing and 'missing' or 'no notes' end
    screen.level(6)
    screen.move(0, 63)
    screen.text(util.trim_string_to_width(table.concat(parts, ', '), 127))
  elseif C.selected_job() then
    local job = C.selected_job()
    screen.level(6)
    screen.move(0, STRIP_Y + 7)
    screen.text(util.trim_string_to_width(job.line, 127))
    local msg
    if job.state == 'failed' then
      msg = (job.err or 'failed') .. (job.needs and '' or ' (K3: drop)')
    elseif job.state == 'queued' then
      msg = 'queued (K3 twice: cancel)'
    else
      msg = job.state .. (job.preview and ', freesound preview' or '') .. ' (K3 twice: cancel)'
    end
    screen.level(job.state == 'failed' and 10 or 6)
    screen.move(0, 63)
    screen.text(util.trim_string_to_width(msg, 127))
  else
    screen.level(4)
    screen.move(64, STRIP_Y + 10)
    screen.text_center('K3: add a tape or download')
  end
  normal()
end

return C

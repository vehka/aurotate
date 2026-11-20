-- draw: shared screen pieces (header with page dots, level-bucketed columns)

local Draw = {}

Draw.W = 128

-- header, baseline y = 8: page dots · name (dim) · state · time
-- name_font: draw the name in tom-thumb (a label someone wrote: ä, ö, å)
function Draw.header(page, pages, name, state, state_level, time, name_level, name_font)
  for i = 1, pages do
    screen.level(i == page and 15 or 2)
    screen.rect((i - 1) * 4, 3, 2, 2)
    screen.fill()
  end
  screen.font_face(1)
  screen.font_size(8)
  local x = 127
  if time then
    -- a fixed box: digits differ in width ("1" is narrow), so measure as if
    -- every digit were "0" and draw left-aligned in it; neither the time's
    -- digits nor the state beside it move as it counts
    local w = screen.text_extents((time:gsub('%d', '0')))
    screen.level(15)
    screen.move(x - w, 8)
    screen.text(time)
    x = x - w - 6
  end
  if state then
    screen.level(state_level or 15)
    screen.move(x, 8)
    screen.text_right(state)
    x = x - screen.text_extents(state) - 5
  end
  local x0 = pages * 4 + 3
  if name and x - x0 > 8 then
    if name_font then
      screen.font_face(25)
      screen.font_size(6)
    end
    screen.level(name_level or 4)
    screen.move(x0, 8)
    screen.text(util.trim_string_to_width(name, x - x0))
    screen.font_face(1)
    screen.font_size(8)
  end
end

-- a horizontal dotted line from x0 to x1 (inclusive) at y
function Draw.dotted(x0, x1, y, level)
  screen.level(level)
  for x = x0 - x0 % 2, x1, 2 do
    if x >= x0 then screen.rect(x, y, 1, 1) end
  end
  screen.fill()
end

-- vertical columns centred on y: column i is at x0 + i - 1, half height h[i]
-- (0 = one pixel, < 0 = none), level lv[i] (0..15; 0 cuts out of what is
-- below). Columns are filled one level at a time (≤ 16 fills per call, not
-- one per column). `skip` (optional)
-- is a table of columns to leave out.
function Draw.columns(x0, y, n, h, lv, skip)
  for l = 0, 15 do
    local any = false
    for i = 1, n do
      if lv[i] == l and h[i] >= 0 and not (skip and skip[i]) then
        screen.rect(x0 + i - 1, y - h[i], 1, 2 * h[i] + 1)
        any = true
      end
    end
    if any then
      screen.level(l)
      screen.fill()
    end
  end
end

-- runs of equal values in v[1..n] (0 = none) as rects from y, h tall; one
-- fill per level. With `level`, v is 0/1 and every run is drawn at it.
function Draw.runs(x0, y, h, n, v, level)
  for l = 1, 15 do
    local any, i = false, 1
    while i <= n do
      if v[i] == l then
        local j = i
        while j < n and v[j + 1] == l do j = j + 1 end
        screen.rect(x0 + i - 1, y, j - i + 1, h)
        any = true
        i = j + 1
      else
        i = i + 1
      end
    end
    if any then
      screen.level(level or l)
      screen.fill()
    end
    if level then return end
  end
end

-- rects collected by level and filled once per level: a fill is the
-- expensive screen call, so many small shapes (flags, mark lines) go in here
local batch = {}
for l = 0, 15 do batch[l] = { n = 0 } end

function Draw.add(l, x, y, w, h)
  local b = batch[l]
  local n = b.n
  b[n + 1], b[n + 2], b[n + 3], b[n + 4] = x, y, w, h
  b.n = n + 4
end

-- fill what was added, in level order (0 first, so cut-outs can't hide
-- brighter shapes added after them)
function Draw.flush()
  for l = 0, 15 do
    local b = batch[l]
    if b.n > 0 then
      for i = 1, b.n, 4 do screen.rect(b[i], b[i + 1], b[i + 2], b[i + 3]) end
      screen.level(l)
      screen.fill()
      b.n = 0
    end
  end
end

return Draw

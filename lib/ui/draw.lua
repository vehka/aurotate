-- draw: shared screen pieces (header with page dots, level-bucketed columns)

local Draw = {}

Draw.W = 128

-- header, baseline y = 8: page dots · name (dim) · state · time
function Draw.header(page, pages, name, state, state_level, time)
  for i = 1, pages do
    screen.level(i == page and 15 or 2)
    screen.rect((i - 1) * 4, 3, 2, 2)
    screen.fill()
  end
  screen.font_face(1)
  screen.font_size(8)
  local x = 127
  if time then
    screen.level(15)
    screen.move(x, 8)
    screen.text_right(time)
    x = x - screen.text_extents(time) - 6
  end
  if state then
    screen.level(state_level or 15)
    screen.move(x, 8)
    screen.text_right(state)
    x = x - screen.text_extents(state) - 5
  end
  local x0 = pages * 4 + 3
  if name and x - x0 > 8 then
    screen.level(4)
    screen.move(x0, 8)
    screen.text(util.trim_string_to_width(name, x - x0))
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
-- (0 = one pixel, < 0 = none), level lv[i] (1..15). Columns are filled one
-- level at a time (≤ 15 fills per call, not one per column). `skip` (optional)
-- is a table of columns to leave out.
function Draw.columns(x0, y, n, h, lv, skip)
  for l = 1, 15 do
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

return Draw

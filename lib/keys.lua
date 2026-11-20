-- keys: the USB keyboard (docs/PLAN.md §4.6)
--
-- Typing on the tape page writes the note of the mark or region under the
-- playhead (a new mark when there is none) in the editor popup. Hotkeys work
-- while typing, borrowed from transcription software:
--
--   Esc        play / stop; resuming rewinds by `aur_rewind` seconds
--   F6 / F7    −5 s / +5 s
--   F8         mark
--   F9         region in, then out
--   Enter      close the editor (Shift+Enter: a new line)
--
-- On the regions page the hotkeys work too; Up/Down (PgUp/PgDn, Home/End)
-- select, Enter jumps the tape there. In the reader popup Up/Down and
-- PgUp/PgDn scroll, Enter closes. On the collection page Up/Down select,
-- Enter opens the tape, Esc plays / stops (Keys.collection, set by the
-- script: move(d), open(), busy()).
--
-- F1–F5 belong to the system menu (core/keyboard.lua takes them before the
-- script sees them), hence F6–F9 rather than the usual F1–F4.

local Keys = {}

local Tape, Annot, Popup, Regions
local page = function() return 'tape' end

local SKIP = 5 -- s for F6 / F7

-- page_fn: the page showing ('tape', 'regions', ...), nil while the file
-- browser is open
function Keys.init(tape, annot, popup, regions, page_fn)
  Tape, Annot, Popup, Regions = tape, annot, popup, regions
  page = page_fn
  keyboard.code = Keys.code
  keyboard.char = Keys.char
end

local function editing() return Popup.kind() == 'editor' end

local MOVES = { LEFT = 'left', RIGHT = 'right', UP = 'up', DOWN = 'down', HOME = 'home', END = 'end' }

local LIST_MOVES = { UP = -1, DOWN = 1, PAGEUP = -7, PAGEDOWN = 7, HOME = -math.huge, END = math.huge }

Keys.collection = nil

function Keys.code(c, v)
  local pg = page()
  if pg == 'collection' and Keys.collection and v > 0 and not Keys.collection.busy() then
    if LIST_MOVES[c] then
      Keys.collection.move(math.max(-100000, math.min(100000, LIST_MOVES[c])))
    elseif v == 1 and (c == 'ENTER' or c == 'KPENTER') then
      Keys.collection.open()
    elseif v == 1 and c == 'ESC' and Tape.st.path then
      Tape.toggle()
    end
    return
  end
  if v == 0 or (pg ~= 'tape' and pg ~= 'regions') or Popup.modal or not Tape.st.path then return end
  local press = v == 1
  -- transport hotkeys, also while typing
  if c == 'ESC' then
    if press then Tape.toggle_rewind(params:get('aur_rewind')) end
    return
  elseif c == 'F6' or c == 'F7' then
    Tape.jump(Tape.st.pos + (c == 'F6' and -SKIP or SKIP))
    Tape.dirty = true
    return
  elseif c == 'F8' then
    if press then Annot.add_mark(Tape.st.pos) end
    return
  elseif c == 'F9' then
    if press then Annot.region_key(Tape.st.pos) end
    return
  end
  if editing() then
    if c == 'ENTER' or c == 'KPENTER' then
      if keyboard.shift() then Popup.insert('\n') else Popup.close() end
    elseif c == 'BACKSPACE' then
      Popup.backspace()
    elseif c == 'DELETE' then
      Popup.delete_char()
    elseif MOVES[c] then
      Popup.move(MOVES[c])
    end
  elseif Popup.active() then
    if press and (c == 'ENTER' or c == 'KPENTER') then
      Popup.close()
    elseif Popup.kind() == 'reader' and (c == 'UP' or c == 'DOWN') then
      Popup.enc(2, c == 'UP' and -1 or 1)
    elseif Popup.kind() == 'reader' and (c == 'PAGEUP' or c == 'PAGEDOWN') then
      Popup.enc(3, c == 'PAGEUP' and -1 or 1)
    end
  elseif pg == 'regions' then
    if LIST_MOVES[c] then
      Regions.move(math.max(-100000, math.min(100000, LIST_MOVES[c])))
    elseif press and (c == 'ENTER' or c == 'KPENTER') then
      Regions.jump()
    end
  end
end

function Keys.char(ch)
  local pg = page()
  if Popup.modal or not Tape.st.path or not pg then return end
  if keyboard.ctrl() or keyboard.alt() or keyboard.meta() then return end
  -- typing writes notes from the tape page, or into an editor opened anywhere
  if not editing() and pg ~= 'tape' then return end
  if not editing() then
    local back = Popup.kind() == 'item' and Popup.layer() or nil
    local item = Popup.item() or Annot.here() or Annot.add_mark(Tape.st.pos)
    if not item then return end
    Popup.open_editor(item, 'note', back)
  end
  Popup.insert(ch)
end

return Keys

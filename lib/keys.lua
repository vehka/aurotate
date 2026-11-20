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
-- F1–F5 belong to the system menu (core/keyboard.lua takes them before the
-- script sees them), hence F6–F9 rather than the usual F1–F4.

local Keys = {}

local Tape, Annot, Popup
local on_tape = function() return true end

local SKIP = 5 -- s for F6 / F7

function Keys.init(tape, annot, popup, on_tape_page)
  Tape, Annot, Popup = tape, annot, popup
  on_tape = on_tape_page
  keyboard.code = Keys.code
  keyboard.char = Keys.char
end

local function editing() return Popup.kind() == 'editor' end

local MOVES = { LEFT = 'left', RIGHT = 'right', UP = 'up', DOWN = 'down', HOME = 'home', END = 'end' }

function Keys.code(c, v)
  if v == 0 or not on_tape() or Popup.modal or not Tape.st.path then return end
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
  elseif Popup.active() and press and (c == 'ENTER' or c == 'KPENTER') then
    Popup.close()
  end
end

function Keys.char(ch)
  if not on_tape() or Popup.modal or not Tape.st.path then return end
  if keyboard.ctrl() or keyboard.alt() or keyboard.meta() then return end
  if not editing() then
    local back = Popup.kind() == 'item' and Popup.layer() or nil
    local item = Popup.item() or Annot.here() or Annot.add_mark(Tape.st.pos)
    if not item then return end
    Popup.open_editor(item, 'note', back)
  end
  Popup.insert(ch)
end

return Keys

-- region_sound: per-region sound on the tape voice (docs/PLAN.md §2.4, §3)
--
-- Sends the combined segments (lib/sound.lua) to the engine whenever they
-- change, and keeps the "current region" params (aur_cur_*) in step with the
-- innermost region under the playhead: they show its settings, and turning
-- them (menu, PMAP, MIDI) edits that region.
--
-- The sends feed the fx mod's send a / send b. Without the mod (or with an
-- empty send) they go nowhere; `RS.send_ok` and `RS.warning` tell the UI.

local cs = require 'controlspec'
local Sound = include 'lib/sound'

local RS = {}
RS.Sound = Sound

local Tape, Annot, Model
local sent = nil      -- the segment list the engine has
local sent_doc = nil
local cur = nil       -- the region the aur_cur_* params show
local cur_doc = nil
local cur_rev = -1

-- param id, field, scale (param value × scale = field value)
local CUR = {
  { 'aur_cur_dry', 'dry', 0.01 },
  { 'aur_cur_send_a', 'send_a', 0.01 },
  { 'aur_cur_send_b', 'send_b', 0.01 },
  { 'aur_cur_gain', 'gain', 1 },
  { 'aur_cur_pan', 'pan', 0.01 },
  { 'aur_cur_tone', 'tone', 0.01 },
}

function RS.init(tape, annot)
  Tape, Annot, Model = tape, annot, annot.Model
end

---- fx sends

local function fx_core()
  local c = package.loaded['fx/lib/core']
  if type(c) == 'table' and c.enabled and type(c.rack) == 'table' then return c end
  return nil
end

-- whether send 'a' / 'b' is heard: the engine found the fx bus, and (when
-- the fx v2 mod tells) the send has an effect in it. Returns ok, reason.
function RS.send_ok(which)
  local bit = which == 'a' and 1 or 2
  if (Tape.st.fx & bit) == 0 then return false, 'no fx' end
  local c = fx_core()
  if c and type(c.rack[which]) == 'table' and next(c.rack[which]) == nil then return false, 'empty' end
  return true
end

-- a region that would be silent: no dry and no send that is heard
function RS.warning(r)
  if not r or Sound.get(r, 'dry') > 0 or Sound.get(r, 'gain') <= Sound.OFF_DB then
    return (r and Sound.get(r, 'gain') <= Sound.OFF_DB) and 'GAIN OFF' or nil
  end
  for _, w in ipairs({ 'a', 'b' }) do
    if Sound.get(r, 'send_' .. w) > 0 and RS.send_ok(w) then return nil end
  end
  return 'SILENT'
end

---- engine

local function same(a, b)
  if a == nil or #a ~= #b then return false end
  for i, s in ipairs(a) do
    local o = b[i]
    if s[1] ~= o[1] or s[2] ~= o[2] or not Sound.equal(s[3], o[3]) then return false end
  end
  return true
end

function RS.push(force)
  local doc = Annot.doc()
  local segs = (doc and params:get('aur_snd') == 1) and Sound.segments(doc) or {}
  if not force and same(sent, segs) then return end
  sent = segs
  engine.snd_clear(#segs)
  for _, s in ipairs(segs) do
    local c = s[3]
    engine.snd_seg(s[1], s[2], c.dry, c.send_a, c.send_b, c.gain, c.pan, c.tone)
  end
  engine.snd_commit(#segs)
end

function RS.segments() return sent or {} end

---- current region params

local function mirror(r)
  for _, c in ipairs(CUR) do
    local v = r and Sound.get(r, c[2]) or Sound.DEFAULT[c[2]]
    params:set(c[1], v / c[3], true)
  end
end

function RS.current() return cur end

-- from the UI timer
function RS.tick()
  local doc = Annot.doc()
  if doc ~= sent_doc or Annot.rev ~= cur_rev then
    sent_doc = doc
    RS.push()
  end
  local r = doc and Model.innermost(doc, Tape.st.pos) or nil
  if r ~= cur or doc ~= cur_doc or Annot.rev ~= cur_rev then
    cur, cur_doc, cur_rev = r, doc, Annot.rev
    mirror(r)
  end
end

---- params

local function pct(lo, hi, default)
  return cs.new(lo, hi, 'lin', 1, default, '%')
end

local function signed(p, neg, pos, zero)
  local v = p:get()
  if math.abs(v) < 0.5 then return zero end
  return (v < 0 and neg or pos) .. ' ' .. math.floor(math.abs(v) + 0.5)
end

function RS.add_params()
  params:add_group('aur_sound', 'SOUND', 9)
  params:add_binary('aur_snd', 'region sound', 'toggle', 1)
  params:set_action('aur_snd', function() RS.push() end)
  params:add_control('aur_snd_glide', 'boundary glide', cs.new(0, 500, 'lin', 1, 50, 'ms'))
  params:set_action('aur_snd_glide', function(ms) engine.snd_glide(ms / 1000) end)

  params:add_separator('aur_sep_cur', 'region here')
  params:add_control('aur_cur_dry', 'dry', pct(0, 100, 100))
  params:add_control('aur_cur_send_a', 'send a', pct(0, 100, 0))
  params:add_control('aur_cur_send_b', 'send b', pct(0, 100, 0))
  params:add_control('aur_cur_gain', 'gain', cs.new(-60, 12, 'lin', 0.1, 0, 'dB', 0.5 / 72),
    function(p) return Sound.format('gain', p:get()) end)
  params:add_control('aur_cur_pan', 'pan', cs.new(-100, 100, 'lin', 1, 0, ''),
    function(p) return signed(p, 'L', 'R', 'centre') end)
  params:add_control('aur_cur_tone', 'tone', cs.new(-100, 100, 'lin', 1, 0, ''),
    function(p) return signed(p, 'dark', 'bright', 'flat') end)
  for _, c in ipairs(CUR) do
    local id, field, scale = c[1], c[2], c[3]
    -- these follow the playhead: not PSET data
    params:set_save(id, false)
    params:set_action(id, function(v)
      local doc = Annot.doc()
      if not cur or doc ~= cur_doc then
        cur_rev = -1 -- no region here: the next tick shows the defaults again
        return
      end
      Model.set_snd(doc, cur, field, v * scale)
      Tape.dirty = true
    end)
  end
end

return RS

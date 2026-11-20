-- add popup: the collection's last row, "+ add a tape" (docs/PLAN.md §6.9)
--
--   file       K3 the file browser (dust/audio)
--   url        K3 type an http(s) link
--   freesound  K3 type a Freesound id (or a link to the sound)
--   queue      the requests waiting in dust/data/aurotate/downloads.txt;
--              K3 fetch them
--   login      Freesound: K3 log in (the link goes to freesound_login.txt
--              and maiden; then type the code Freesound shows), or log out
--   api key    K3 type the Freesound client secret (the API key)
--   client id  K3 type the Freesound client id
--
-- E2 row, K2 close. A USB keyboard makes the typing easy.

local textentry = require 'textentry'

local AP = {}

local Tape, Popup, D, FS
local layer = nil
AP.modal = false

-- set by the script
AP.on_file = function() end
AP.on_message = function(msg, secs) end

local ROWS = { 'file', 'url', 'freesound', 'queue', 'login', 'api key', 'client id' }

function AP.init(tape, popup, download)
  Tape, Popup, D = tape, popup, download
  FS = D.FS
end

function AP.active() return layer ~= nil end

function AP.open()
  FS.load()
  layer = { row = 1, confirm = nil, queue = D.queue_count() }
  Tape.dirty = true
end

function AP.close()
  layer = nil
  Tape.dirty = true
end
AP.reset = AP.close

local function login_value()
  local s = FS.state(os.time())
  if s == 'no key' then return 'needs an api key' end
  if s == 'logged in' then return layer.confirm == 'logout' and 'K3 again: log out' or 'logged in (K3: out)' end
  if not FS.can_login() then return 'needs a client id' end
  if s == 'waiting for code' then return 'K3: type the code' end
  return 'K3: log in'
end

local function row_value(name)
  if name == 'file' then return 'browse dust/audio' end
  if name == 'url' then return 'K3: type a link' end
  if name == 'freesound' then return FS.has_key() and 'K3: type an id' or 'needs an api key' end
  if name == 'queue' then
    return layer.queue > 0 and (layer.queue .. ' waiting (K3)') or 'downloads.txt empty'
  end
  if name == 'login' then return login_value() end
  if name == 'api key' then return FS.has_key() and 'set' or '-' end
  if name == 'client id' then return FS.cfg.client_id and 'set' or '-' end
  return ''
end

function AP.redraw()
  if not layer then return end
  local G = Popup.GEOM
  screen.font_face(1)
  screen.font_size(8)
  Popup.frame_box()
  local name = ROWS[layer.row]
  local right = nil
  if name == 'freesound' or name == 'login' or name == 'api key' or name == 'client id' then right = 'FREESOUND' end
  if name == 'queue' or name == 'url' then right = 'DOWNLOAD' end
  Popup.title('ADD', right)
  local top = util.clamp(layer.row - G.NROWS + 1, 1, math.max(1, #ROWS - G.NROWS + 1))
  for i = 0, G.NROWS - 1 do
    local r = top + i
    local n = ROWS[r]
    if not n then break end
    local y = G.ROWS_Y + i * G.ROW_H
    local sel = r == layer.row
    Popup.ui_font()
    screen.level(sel and 15 or 4)
    screen.move(G.TX, y)
    screen.text(n)
    Popup.text_font()
    screen.level(sel and 15 or 8)
    screen.move(G.TX + 46, y)
    screen.text(util.trim_string_to_width(row_value(n), G.TW - 48))
  end
  screen.level(4)
  local h = math.max(3, math.floor((G.H - 16) * G.NROWS / #ROWS))
  local y0 = G.Y + 14 + math.floor((G.H - 16 - h) * (top - 1) / (#ROWS - G.NROWS))
  screen.rect(G.X + G.W - 3, y0, 1, h)
  screen.fill()
  Popup.ui_font()
end

---- typing

local function enter(default, heading, check, done)
  AP.modal = true
  textentry.enter(function(txt)
    AP.modal = false
    if txt then done(txt) end
    Tape.dirty = true
  end, default or '', heading, check)
end

local function queued(job, err)
  if job then
    AP.close()
    AP.on_message('QUEUED: ' .. job.line:upper(), 2)
  else
    AP.on_message(('NOT QUEUED: ' .. tostring(err)):upper(), 2)
  end
end

local function type_code()
  enter('', 'code from Freesound', nil, function(code)
    AP.on_message('LOGGING IN…', 3)
    D.login_code(code, function(ok, msg)
      AP.on_message(ok and 'LOGGED IN TO FREESOUND' or ('LOGIN: ' .. tostring(msg)):upper(), 3)
      Tape.dirty = true
    end)
  end)
end

function AP.key(n, z)
  if not layer or z == 0 then return end
  if n == 2 then
    AP.close()
    return
  end
  if n ~= 3 then return end
  local name = ROWS[layer.row]
  if name ~= 'login' then layer.confirm = nil end
  if name == 'file' then
    AP.close()
    AP.on_file()
  elseif name == 'url' then
    enter('https://', 'link (http/https)', function(t)
      local r = D.parse(t)
      return (not r or r.kind ~= 'url') and 'not a link' or nil
    end, function(t) queued(D.request(t, 'ui')) end)
  elseif name == 'freesound' then
    if not FS.has_key() then
      AP.on_message('PUT AN API KEY IN FIRST', 2)
      return
    end
    enter('', 'freesound id or link', function(t)
      local r = D.parse(t)
      return (not r or r.kind ~= 'freesound') and 'digits, or a sound link' or nil
    end, function(t) queued(D.request(t, 'ui')) end)
  elseif name == 'queue' then
    local k = D.fetch_queue()
    layer.queue = D.queue_count()
    if k > 0 then AP.close() end
    AP.on_message(k > 0 and ('QUEUED ' .. k) or 'NOTHING IN DOWNLOADS.TXT', 2)
  elseif name == 'login' then
    local s = FS.state(os.time())
    if s == 'logged in' then
      if layer.confirm == 'logout' then
        D.logout()
        layer.confirm = nil
        AP.on_message('LOGGED OUT', 2)
      else
        layer.confirm = 'logout'
      end
    elseif s == 'waiting for code' then
      type_code()
    elseif FS.can_login() then
      local url, err = D.login_start()
      if not url then
        AP.on_message(('LOGIN: ' .. tostring(err)):upper(), 3)
        return
      end
      AP.on_message('OPEN THE LINK IN FREESOUND_LOGIN.TXT', 4)
      type_code()
    else
      AP.on_message('NEEDS API KEY AND CLIENT ID', 2)
    end
  elseif name == 'api key' then
    enter('', 'freesound api key (client secret)', nil, function(t)
      FS.set('api_key', D.trim(t))
    end)
  elseif name == 'client id' then
    enter('', 'freesound client id', nil, function(t)
      FS.set('client_id', D.trim(t))
    end)
  end
  Tape.dirty = true
end

function AP.enc(n, d)
  if not layer then return end
  if n == 2 then
    layer.row = util.clamp(layer.row + d, 1, #ROWS)
    layer.confirm = nil
    if ROWS[layer.row] == 'queue' then layer.queue = D.queue_count() end
  end
  Tape.dirty = true
end

return AP

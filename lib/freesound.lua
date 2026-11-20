-- freesound: API v2 credentials, the OAuth2 + PKCE login and the requests
-- (docs/PLAN.md §6.9). No network here: lib/download.lua runs the requests
-- with curl. Everything but the file writes is pure, for the tests.
--
--   <data>/freesound.lua   { api_key, client_id, redirect_uri?, base?,
--                            access_token, refresh_token, expires,
--                            pending = { verifier, state, started } }
--                          mode 600; never in PSETs, never printed
--   <data>/freesound_login.txt   the authorize link, for a computer or phone
--
-- The user registers once at https://freesound.org/apiv2/apply and puts the
-- client id and the client secret (the API key) in freesound.lua. The key
-- alone gives metadata and previews; the original file needs a login.

local Pkce = include 'lib/pkce'

local FS = {}

FS.BASE = 'https://freesound.org'
FS.LOGIN_TTL = 600 -- s: an authorization code lives 10 minutes
FS.cfg = {}

local dir, read_lua, serialise, write_file

function FS.init(data_dir, store)
  dir = data_dir
  read_lua, serialise, write_file = store.read_lua, store.serialise_value, store.write_file
  FS.load()
end

function FS.path() return dir .. 'freesound.lua' end
function FS.login_path() return dir .. 'freesound_login.txt' end

local function str(x) return type(x) == 'string' and x ~= '' and x or nil end

function FS.load()
  local t = dir and read_lua(FS.path())
  FS.cfg = type(t) == 'table' and t or {}
  return FS.cfg
end

function FS.save()
  local q = "'" .. FS.path():gsub("'", "'\\''") .. "'"
  -- the file is created private before anything secret goes in
  os.execute('touch ' .. q .. ' ' .. q .. '.tmp; chmod 600 ' .. q .. ' ' .. q .. '.tmp')
  local ok, err = write_file(FS.path(), '-- aurotate: Freesound credentials (keep private)\n'
    .. '-- api_key = the client secret, client_id = the client id, from\n'
    .. '-- https://freesound.org/apiv2/apply\nreturn ' .. serialise(FS.cfg) .. '\n')
  os.execute('chmod 600 ' .. q .. ' 2> /dev/null; rm -f ' .. q .. '.bak')
  return ok, err
end

function FS.base() return (str(FS.cfg.base) or FS.BASE):gsub('/+$', '') end

---- state

function FS.has_key(c) c = c or FS.cfg return str(c.api_key) ~= nil end
function FS.can_login(c) c = c or FS.cfg return FS.has_key(c) and str(c.client_id) ~= nil end
function FS.logged_in(c) c = c or FS.cfg return str(c.refresh_token) ~= nil or str(c.access_token) ~= nil end

-- the access token is good for a while yet
function FS.token_valid(c, now)
  return str(c.access_token) ~= nil and type(c.expires) == 'number' and now < c.expires
end

function FS.needs_refresh(c, now)
  return FS.logged_in(c) and not FS.token_valid(c, now) and str(c.refresh_token) ~= nil
end

-- a login started less than 10 minutes ago, waiting for its code
function FS.pending(c, now)
  local p = c.pending
  return type(p) == 'table' and str(p.verifier) ~= nil and type(p.started) == 'number'
    and now - p.started < FS.LOGIN_TTL
end

-- 'no key' | 'key only' | 'waiting for code' | 'logged in'
function FS.state(now, c)
  c = c or FS.cfg
  if not FS.has_key(c) then return 'no key' end
  if FS.logged_in(c) then return 'logged in' end
  if FS.pending(c, now) then return 'waiting for code' end
  return 'key only'
end

---- the login

local function urlenc(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(ch) return string.format('%%%02X', ch:byte()) end))
end
FS.urlenc = urlenc

function FS.authorize_url(c, challenge, state)
  local u = FS.base() .. '/apiv2/oauth2/authorize/?client_id=' .. urlenc(c.client_id)
    .. '&response_type=code&code_challenge=' .. challenge .. '&code_challenge_method=S256&state=' .. state
  if str(c.redirect_uri) then u = u .. '&redirect_uri=' .. urlenc(c.redirect_uri) end
  return u
end

-- start a login: a new verifier and state, the link written to
-- freesound_login.txt. Returns the link, or nil and why.
function FS.login_start(now, random)
  local c = FS.cfg
  if not FS.can_login(c) then return nil, 'needs api_key and client_id' end
  random = random or Pkce.random
  local v, s = random(32), random(12)
  if not v or not s then return nil, 'no random bytes' end
  c.pending = { verifier = Pkce.verifier(v), state = Pkce.b64url(s), started = now }
  local url = FS.authorize_url(c, Pkce.challenge(c.pending.verifier), c.pending.state)
  local ok, err = FS.save()
  if not ok then return nil, err end
  local f = io.open(FS.login_path(), 'w')
  if f then
    f:write('aurotate: log in to Freesound\n\n',
      '1. Open this link on a computer or phone (logged in to Freesound) and allow access:\n\n',
      url, '\n\n',
      '2. Freesound shows a code. Type it on the norns within 10 minutes\n',
      '   (the login row of the add popup, or freesound_code(\'...\') in maiden).\n\n',
      'Started ', os.date('%Y-%m-%d %H:%M:%S', now), '.\n')
    f:close()
  end
  return url
end

-- a pasted code may be the whole redirect URL (…?code=XYZ&state=…)
function FS.clean_code(code)
  if type(code) ~= 'string' then return nil end
  code = code:match('[?&]code=([^&%s]+)') or code
  code = code:gsub('%s', '')
  return code ~= '' and code or nil
end

---- requests: { url, method?, headers = {}, data = {k, v}... } -> curl config

local function token_fields(c)
  local d = { { 'client_id', c.client_id } }
  if str(c.api_key) then d[#d + 1] = { 'client_secret', c.api_key } end
  return d
end

function FS.token_request(code, c)
  c = c or FS.cfg
  if not FS.pending(c, os.time()) then return nil, 'the login has expired: start it again' end
  local d = token_fields(c)
  d[#d + 1] = { 'grant_type', 'authorization_code' }
  d[#d + 1] = { 'code', code }
  d[#d + 1] = { 'code_verifier', c.pending.verifier }
  if str(c.redirect_uri) then d[#d + 1] = { 'redirect_uri', c.redirect_uri } end
  return { url = FS.base() .. '/apiv2/oauth2/access_token/', data = d }
end

function FS.refresh_request(c)
  c = c or FS.cfg
  local d = token_fields(c)
  d[#d + 1] = { 'grant_type', 'refresh_token' }
  d[#d + 1] = { 'refresh_token', c.refresh_token }
  return { url = FS.base() .. '/apiv2/oauth2/access_token/', data = d }
end

function FS.sound_request(id, c)
  c = c or FS.cfg
  return { url = FS.base() .. '/apiv2/sounds/' .. math.tointeger(id) .. '/',
    headers = { 'Authorization: Token ' .. (c.api_key or '') } }
end

function FS.download_request(id, c)
  c = c or FS.cfg
  return { url = FS.base() .. '/apiv2/sounds/' .. math.tointeger(id) .. '/download/',
    headers = { 'Authorization: Bearer ' .. (c.access_token or '') } }
end

-- a curl config file (curl -K) for a request: the secrets stay out of the
-- command line (and so out of ps)
local function cq(s) return '"' .. tostring(s):gsub('[\\"]', '\\%0'):gsub('[\r\n]', '') .. '"' end
function FS.curl_config(req)
  local o = { 'url = ' .. cq(req.url) }
  for _, h in ipairs(req.headers or {}) do o[#o + 1] = 'header = ' .. cq(h) end
  for _, kv in ipairs(req.data or {}) do o[#o + 1] = 'data-urlencode = ' .. cq(kv[1] .. '=' .. kv[2]) end
  return table.concat(o, '\n') .. '\n'
end

-- a token response (decoded JSON). Stores the tokens; every refresh gives a
-- new refresh token, saved at once. Returns true, or nil and why.
function FS.take_token(t, now)
  if type(t) ~= 'table' or not str(t.access_token) then
    return nil, type(t) == 'table' and (str(t.error_description) or str(t.error)) or 'no token'
  end
  local c = FS.cfg
  c.access_token = t.access_token
  c.refresh_token = str(t.refresh_token) or c.refresh_token
  c.expires = now + math.max(60, (tonumber(t.expires_in) or 86400) - 60)
  c.pending = nil
  local ok, err = FS.save()
  if not ok then return nil, err end
  os.remove(FS.login_path())
  return true
end

function FS.clear_tokens()
  local c = FS.cfg
  c.access_token, c.refresh_token, c.expires, c.pending = nil, nil, nil, nil
  return FS.save()
end

function FS.set(field, value)
  if FS.cfg[field] == str(value) then return true end
  FS.cfg[field] = str(value)
  if field == 'api_key' or field == 'client_id' then
    -- other credentials: the old login doesn't belong to them
    FS.cfg.access_token, FS.cfg.refresh_token, FS.cfg.expires, FS.cfg.pending = nil, nil, nil, nil
  end
  return FS.save()
end

return FS

-- download: bring recordings onto the device by URL or Freesound id
-- (docs/PLAN.md §6.9)
--
--   D.request(line, from)  queue 'https://…', 'freesound:123', a Freesound
--                          link or bare digits; from: 'ui' | 'repl' | 'file'
--   D.fetch_queue()        everything in <data>/downloads.txt
--   D.cancel(job), D.dismiss(job)
--   D.login_start(), D.login_code(code)   the Freesound login
--
-- One job at a time, in a clock coroutine. Each shell step (curl, sox,
-- ffmpeg) is a detached job (norns-deps' runner) that the coroutine polls,
-- so nothing blocks matron. A download goes into a hidden temp folder next
-- to its destination, is converted when it isn't WAV/FLAC (to FLAC at
-- 48 kHz), then moved into place with a sidecar <file>.source.txt and a tape
-- document that carries its source (and, from Freesound, a first note).
--
-- Where: Freesound into dust/audio/aurotate/freesound/, URLs into
-- dust/audio/aurotate/.

local Source = include 'lib/source'
local Json = include 'lib/json'
local FS = include 'lib/freesound'

local D = {}

D.MAX_BYTES = 4 * 1024 ^ 3   -- one download at most
D.RESERVE = 200 * 1024 ^ 2   -- left free on the disk
D.jobs = {}                  -- queued, running, failed (done ones leave)
D.installing = false         -- the deps installer has the screen
D.FS = FS
D.parse = Source.parse_request
D.trim = Source.trim

local data_dir, audio_dir
local Store, Model, Collection
local deps = nil
local runner = nil
local worker = nil
local changed = false
local seq = 0

-- set by the script: a tape arrived (job.path), or a job changed
D.on_done = function(job) end
D.on_fail = function(job) end

function D.init(opts)
  data_dir, audio_dir = opts.data_dir, opts.audio_dir
  Store, Model, Collection = opts.Store, opts.Model, opts.Collection
  FS.init(data_dir, Store)
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function read_file(path, n)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read(n or 'a')
  f:close()
  return s
end

local function exists(path)
  local f = io.open(path, 'r')
  if f then f:close() end
  return f ~= nil
end

local function touch() changed = true end

-- true once when something worth a redraw happened
function D.tick()
  local c = changed
  changed = false
  return c
end

---- dependencies (norns-deps), checked when a download is first asked for

function D.deps()
  if deps then return deps end
  local Deps = include 'lib/deps'
  deps = Deps.new { name = 'aurotate', dir = data_dir .. 'deps' }
  deps:add { id = 'curl', label = 'curl', check = 'curl', pkg = 'curl', size = '1 MB',
    why = 'downloads by URL and from Freesound' }
  deps:add { id = 'ffmpeg', label = 'ffmpeg', check = 'ffmpeg', pkg = 'ffmpeg', size = '~20 MB',
    why = 'mp3 and m4a downloads (sox reads wav, aif, flac, ogg)' }
  runner = Deps.runner.new(data_dir .. 'downloads/jobs')
  return deps
end

-- open the installer for ids; then(ok) afterwards
function D.ensure(ids, after)
  local d = D.deps()
  if #d:missing(ids) == 0 then
    if after then after(true) end
    return
  end
  D.installing = true
  d:ensure(ids, { on_done = function(ok)
    D.installing = false
    touch()
    if after then after(ok) end
  end })
end

---- running shell steps from the coroutine

local function sh(job, cmd, progress)
  local j = runner:start(cmd, { progress = progress and 'percent' or nil })
  job.handle = j
  while true do
    clock.sleep(0.25)
    if job.cancelled then j:cancel() end
    local r = j:poll()
    if progress and r.progress and r.progress ~= job.progress then
      job.progress = r.progress
      touch()
    end
    if r.done then
      job.handle = nil
      os.remove(j.log)
      return r.code, r.tail
    end
  end
end

local function fail(msg) error({ msg = msg }, 0) end

local function check_cancel(job)
  if job.cancelled then fail('cancelled') end
end

-- a curl config file (mode 600) for a request with secrets
local function config_file(job, req)
  local path = job.tmp .. 'req.conf'
  os.execute('touch ' .. q(path) .. '; chmod 600 ' .. q(path))
  local f = io.open(path, 'w')
  f:write(FS.curl_config(req))
  f:close()
  return path
end

local CURL_ERR = {
  [6] = 'no such host', [7] = 'can\'t connect', [22] = 'HTTP error', [23] = 'disk write failed',
  [28] = 'too slow / timed out', [35] = 'TLS failed', [47] = 'too many redirects',
  [60] = 'certificate not trusted', [63] = 'too big', [143] = 'cancelled',
}

-- a small API call: JSON back. Returns the decoded body, the HTTP status
local function api(job, req)
  local conf = config_file(job, req)
  local body, w = job.tmp .. 'api.json', job.tmp .. 'api.w'
  local code = sh(job, string.format('curl -sS --connect-timeout 20 --max-time 60 -K %s -o %s -w %s > %s',
    q(conf), q(body), q('%{http_code}'), q(w)))
  os.remove(conf)
  check_cancel(job)
  if code ~= 0 then fail(CURL_ERR[code] or ('curl failed (' .. code .. ')')) end
  local status = tonumber(read_file(w) or '') or 0
  local t = Json.decode(read_file(body) or '')
  os.remove(body)
  return t, status
end

-- free bytes on the disk that holds dir
local function free_bytes(dir)
  local s = util.os_capture('df -Pk ' .. q(dir) .. ' | tail -1') or ''
  local avail = tonumber(s:match('^%S+%s+%d+%s+%d+%s+(%d+)'))
  return avail and avail * 1024 or nil
end

-- fetch a file into job.tmp .. 'body'. req: { url, headers? }.
-- Returns the response headers and curl's write-out (final url, type)
local function fetch(job, req)
  local free = free_bytes(job.dir)
  local cap = D.MAX_BYTES
  if free then cap = math.min(cap, free - D.RESERVE) end
  if cap < 1024 * 1024 then fail('disk full') end
  local auth = ''
  if req.headers and #req.headers > 0 then auth = '-K ' .. q(config_file(job, { url = req.url, headers = req.headers })) .. ' ' end
  job.state, job.progress = 'fetching', 0
  touch()
  local code = sh(job, string.format(
    'curl -L -# --proto =http,https --proto-redir =http,https --max-redirs 10 --connect-timeout 20 '
    .. '-y 60 -Y 500 --max-filesize %d -D %s -o %s -w %s %s%s > %s',
    math.floor(cap), q(job.tmp .. 'headers'), q(job.tmp .. 'body'),
    q('%{url_effective}\\n%{content_type}\\n%{http_code}\\n'), auth,
    auth == '' and q(req.url) or '', q(job.tmp .. 'w')), true)
  os.remove(job.tmp .. 'req.conf')
  check_cancel(job)
  local h = Source.parse_headers(read_file(job.tmp .. 'headers') or '')
  if code ~= 0 then fail(CURL_ERR[code] or ('curl failed (' .. code .. ')')) end
  local w = {}
  for line in (read_file(job.tmp .. 'w') or ''):gmatch('[^\n]*') do w[#w + 1] = line end
  -- an HTTP error: no file (the body is the server's error page)
  local status = tonumber(w[3] or '') or h.status or 0
  if status >= 400 or status == 0 then
    h.status = status
    return nil, h
  end
  return { final_url = w[1] ~= '' and w[1] or req.url, content_type = w[2] ~= '' and w[2] or nil }, h
end

local function http_fail(h)
  local s = h and h.status
  if s == 404 then fail('not found (404)') end
  if s == 401 or s == 403 then fail('refused (' .. s .. ')') end
  fail('HTTP ' .. tostring(s or '?'))
end

---- the steps after the fetch: type, conversion, into place

local function finish(job, src, stem)
  local body = job.tmp .. 'body'
  local kind = Source.sniff(read_file(body, 64))
  local how = Source.how(kind)
  if not how then
    fail('not audio' .. (kind and (' (' .. kind .. ')') or (src.content_type and (' (' .. src.content_type .. ')') or '')))
  end
  local out, ext = body, kind
  if how ~= 'keep' then
    if how == 'ffmpeg' and not D.deps():ok('ffmpeg') then
      job.needs = 'ffmpeg'
      fail(kind .. ' needs ffmpeg')
    end
    job.state = 'converting'
    touch()
    out, ext = job.tmp .. 'out.flac', 'flac'
    local cmd
    if how == 'sox' then
      cmd = string.format('nice -n 10 sox -t %s %s -t flac %s rate -v 48k', kind == 'aiff' and 'aiff' or kind, q(body), q(out))
    else
      cmd = string.format('nice -n 10 ffmpeg -nostdin -hide_banner -loglevel error -y -i %s -ar 48000 -c:a flac %s',
        q(body), q(out))
    end
    local code, tail = sh(job, cmd)
    check_cancel(job)
    if code ~= 0 then
      print('aurotate: conversion failed: ' .. tostring(tail))
      fail('conversion failed')
    end
  end
  local path = Source.unique(job.dir, stem, ext, exists)
  local ok, err = os.rename(out, path)
  if not ok then fail('move failed: ' .. tostring(err)) end
  job.path = path
  local f = io.open(path .. '.source.txt', 'w')
  if f then
    f:write(Source.sidecar(src))
    f:close()
  end
  -- the tape document, with its source (and the first note)
  local ch, frames, rate = audio.file_info(path)
  local dur = (frames and rate and rate > 0) and frames / rate or nil
  if not dur or dur <= 0 then fail('unreadable after download') end
  local size = tonumber(util.os_capture('stat -c %s ' .. q(path)))
  local doc = Store.peek(path) or Model.new(path, dur, size)
  doc.tape.dur, doc.tape.size = dur, size
  doc.tape.source = Source.clean(src)
  if src.title then doc.tape.title = Source.title(src.title) end
  local label, note, tags = Source.first_note(doc.tape.source)
  if label and #doc.marks == 0 then
    local m = Model.add_mark(doc, 0, os.time())
    m.label, m.note, m.tags = label, note, tags
  end
  local wok, werr = Store.put(path, doc)
  if not wok then print('aurotate: notes for the download not saved: ' .. tostring(werr)) end
  local e = Collection.from_doc(doc)
  if e then e.opened = os.time() end
  Collection.flush()
  job.dur, job.ch = dur, ch
end

---- the two kinds

local function run_url(job)
  job.dir = audio_dir
  local info, h = fetch(job, { url = job.req.url })
  if not info then http_fail(h) end
  local src = {
    kind = 'url', url = job.req.url, final_url = info.final_url, content_type = info.content_type,
    last_modified = h['last-modified'], downloaded = os.time(),
  }
  local name = Source.name_from(h, info.final_url) or 'download'
  local stem = Source.split_ext(name)
  src.title = stem
  job.name = stem
  finish(job, src, Source.safe(stem))
end

-- refresh the access token if it has run out; false when the login is gone
local function refreshed(job)
  local c = FS.cfg
  if not FS.needs_refresh(c, os.time()) then return FS.token_valid(c, os.time()) end
  job.state = 'login'
  touch()
  local t, status = api(job, FS.refresh_request(c))
  if status == 200 and FS.take_token(t, os.time()) then return true end
  print('aurotate: Freesound refresh failed (' .. tostring(status) .. '): the login is gone')
  FS.clear_tokens()
  return false
end

local function run_freesound(job)
  FS.load()
  if not FS.has_key() then fail('no Freesound API key (freesound.lua)') end
  job.dir = audio_dir .. 'freesound/'
  os.execute('mkdir -p ' .. q(job.dir))
  job.state = 'metadata'
  touch()
  local snd, status = api(job, FS.sound_request(job.req.id))
  if status == 404 then fail('no sound ' .. job.req.id) end
  if status == 401 then fail('API key refused (401)') end
  if status ~= 200 or type(snd) ~= 'table' then fail('metadata: HTTP ' .. status) end
  job.name = type(snd.name) == 'string' and snd.name or tostring(job.req.id)
  touch()
  local file, info, h = 'original', nil, nil
  if FS.logged_in() and refreshed(job) then
    info, h = fetch(job, FS.download_request(job.req.id))
    if not info and h and h.status == 401 then
      print('aurotate: Freesound login refused (401): log in again')
      FS.clear_tokens()
    elseif not info then
      http_fail(h)
    end
  end
  if not info then
    local previews = type(snd.previews) == 'table' and snd.previews or {}
    local url = previews['preview-hq-ogg'] or previews['preview-lq-ogg']
    if type(url) ~= 'string' then fail('no preview') end
    file = url == previews['preview-hq-ogg'] and 'preview-hq-ogg' or 'preview-lq-ogg'
    job.preview = true
    info, h = fetch(job, { url = url })
    if not info then http_fail(h) end
  end
  local src = Source.from_freesound(snd, file, os.time(), Json.null)
  src.final_url = info.final_url
  src.content_type = info.content_type
  finish(job, src, Source.freesound_stem(src.freesound))
end

---- the queue

local function run(job)
  seq = seq + 1
  job.tmp = (job.req.kind == 'freesound' and (audio_dir .. 'freesound/') or audio_dir)
    .. '.aurotate-dl-' .. os.time() .. '-' .. seq .. '/'
  os.execute('mkdir -p ' .. q(job.tmp) .. '; chmod 700 ' .. q(job.tmp))
  local ok, err = pcall(job.req.kind == 'freesound' and run_freesound or run_url, job)
  os.execute('rm -rf ' .. q(job.tmp))
  job.handle = nil
  if ok then
    job.state = 'done'
    print('aurotate: downloaded ' .. job.path .. (job.preview and ' (Freesound preview)' or ''))
  else
    job.state = job.cancelled and 'cancelled' or 'failed'
    job.err = type(err) == 'table' and err.msg or tostring(err)
    if type(err) ~= 'table' then print('aurotate: download error: ' .. job.err) end
    print('aurotate: download ' .. job.line .. ': ' .. job.err)
  end
  touch()
end

local function file_failed(job)
  if job.from ~= 'file' or job.cancelled then return end
  local f = io.open(data_dir .. 'downloads.txt', 'a')
  if f then
    f:write('# failed (', os.date('%Y-%m-%d %H:%M'), ', ', job.err or '?', '): ', job.line, '\n')
    f:close()
  end
end

local function next_job()
  for _, j in ipairs(D.jobs) do
    if j.state == 'queued' then return j end
  end
end

local function remove(job)
  for i, j in ipairs(D.jobs) do
    if j == job then table.remove(D.jobs, i) return end
  end
end

local function start_worker()
  if worker then return end
  worker = clock.run(function()
    while true do
      local job = next_job()
      if not job then break end
      job.state = 'starting'
      touch()
      run(job)
      if job.state == 'done' then
        remove(job)
        D.on_done(job)
      elseif job.state == 'cancelled' then
        remove(job)
      else
        file_failed(job)
        D.on_fail(job)
        -- a missing ffmpeg: offer it, then try again
        if job.needs then
          local needs = job.needs
          D.ensure({ needs }, function(ok)
            if ok then
              job.state, job.err, job.needs = 'queued', nil, nil
              start_worker()
            end
          end)
        end
      end
    end
    worker = nil
    touch()
  end)
end

-- queue a request; returns the job, or nil and why
function D.request(line, from)
  local req, why = Source.parse_request(line)
  if not req then return nil, why end
  local job = { req = req, line = Source.request_line(req), from = from or 'ui', state = 'queued', progress = 0 }
  job.name = req.kind == 'freesound' and ('freesound ' .. req.id) or (Source.name_from(nil, req.url) or req.url)
  D.jobs[#D.jobs + 1] = job
  touch()
  D.ensure({ 'curl' }, function(ok)
    if ok then
      start_worker()
    else
      job.state, job.err = 'failed', 'needs curl'
      touch()
    end
  end)
  return job
end

function D.busy() return worker ~= nil end

function D.cancel(job)
  if job.state == 'queued' or job.state == 'failed' then
    remove(job)
  else
    job.cancelled = true
    if job.handle then job.handle:cancel() end
  end
  touch()
end

D.dismiss = remove

---- the queue file: dust/data/aurotate/downloads.txt

function D.queue_path() return data_dir .. 'downloads.txt' end

-- the requests waiting in the file
function D.queue_count()
  local n = 0
  for line in (read_file(D.queue_path()) or ''):gmatch('[^\n]+') do
    if Source.parse_request(line) then n = n + 1 end
  end
  return n
end

-- queue every request in the file; the file keeps only comments (and lines
-- it didn't understand, marked). Returns how many were queued.
function D.fetch_queue()
  local text = read_file(D.queue_path())
  if not text then return 0 end
  local keep, n = {}, 0
  for line in text:gmatch('[^\n]+') do
    local t = Source.trim(line)
    if t == '' or t:sub(1, 1) == '#' then
      keep[#keep + 1] = line
    elseif D.request(t, 'file') then
      n = n + 1
    else
      keep[#keep + 1] = '# not understood: ' .. t
    end
  end
  local f = io.open(D.queue_path(), 'w')
  if f then
    f:write(table.concat(keep, '\n'), #keep > 0 and '\n' or '')
    f:close()
  end
  return n
end

---- the Freesound login

-- the link to open elsewhere (also in freesound_login.txt), or nil and why
function D.login_start()
  FS.load()
  local url, err = FS.login_start(os.time())
  if url then
    print('aurotate: open this link to log in to Freesound (also in ' .. FS.login_path() .. '):')
    print(url)
  end
  return url, err
end

-- exchange the code; after(ok, msg)
function D.login_code(code, after)
  after = after or function() end
  code = FS.clean_code(code)
  if not code then return after(false, 'no code') end
  local req, err = FS.token_request(code)
  if not req then return after(false, err) end
  D.ensure({ 'curl' }, function(ok)
    if not ok then return after(false, 'needs curl') end
    clock.run(function()
      seq = seq + 1
      local job = { tmp = data_dir .. 'downloads/login-' .. seq .. '/' }
      os.execute('mkdir -p ' .. q(job.tmp) .. '; chmod 700 ' .. q(job.tmp))
      local pok, t, status = pcall(api, job, req)
      os.execute('rm -rf ' .. q(job.tmp))
      if not pok then return after(false, type(t) == 'table' and t.msg or tostring(t)) end
      local tok, terr = false, nil
      if status == 200 then tok, terr = FS.take_token(t, os.time()) end
      if not tok then
        terr = terr or (type(t) == 'table' and (Json.val(t.error_description) or Json.val(t.error))) or ('HTTP ' .. status)
        print('aurotate: Freesound login failed: ' .. tostring(terr))
      else
        print('aurotate: logged in to Freesound')
      end
      touch()
      after(tok and true or false, tok and 'logged in' or tostring(terr))
    end)
  end)
end

function D.logout() FS.clear_tokens() touch() end

function D.cleanup()
  for _, j in ipairs(D.jobs) do
    if j.handle then
      j.cancelled = true
      j.handle:cancel()
    end
  end
  if worker then clock.cancel(worker) end
  worker = nil
  -- the running job's temp folder (the coroutine won't get to it now)
  for _, j in ipairs(D.jobs) do
    if j.tmp then os.execute('rm -rf ' .. q(j.tmp)) end
  end
end

return D

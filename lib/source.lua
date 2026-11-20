-- source: where a downloaded tape came from, and who to credit
-- (docs/PLAN.md §6.9). Pure Lua: requests, file names, HTTP headers, file
-- types, the credit line, the sidecar, validation.
--
--   source = { kind = 'freesound' | 'url', url, final_url, content_type,
--              last_modified, author, license, license_url, title,
--              downloaded, freesound = { id, name, username, url, license,
--              description, tags, created, pack, geotag, file, original =
--              { type, samplerate, channels, duration, filesize, md5 } } }

local Source = {}

local AUDIO_EXT = { wav = true, wave = true, aif = true, aiff = true, flac = true, ogg = true, mp3 = true,
  m4a = true, bwf = true, rf64 = true }

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
Source.trim = trim

---- requests: one line of downloads.txt, the REPL or textentry

-- { kind = 'freesound', id = n } | { kind = 'url', url = s }, or nil and why
function Source.parse_request(line)
  if type(line) ~= 'string' then return nil, 'nothing' end
  line = trim(line)
  if line == '' or line:sub(1, 1) == '#' then return nil, 'empty' end
  local id = line:match('^freesound:%s*(%d+)$') or line:match('^(%d+)$')
    or line:match('^https?://w?w?w?%.?freesound%.org/people/[^/]+/sounds/(%d+)/?$')
    or line:match('^https?://w?w?w?%.?freesound%.org/s/(%d+)/?$')
  if id then return { kind = 'freesound', id = math.tointeger(tonumber(id)) } end
  if line:match('^[Hh][Tt][Tt][Pp][Ss]?://[^%s/]+') and not line:find('%s') then
    return { kind = 'url', url = line }
  end
  return nil, 'not a URL or a Freesound id'
end

-- the request as one line again (for the queue file, messages)
function Source.request_line(req)
  if req.kind == 'freesound' then return 'freesound:' .. req.id end
  return req.url
end

---- file names

local function pct_decode(s)
  return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

-- a safe file name stem: letters, digits, - _ . (UTF-8 letters become _)
function Source.safe(s, max)
  s = tostring(s or ''):gsub('[^%w%-_%.]', '_'):gsub('_+', '_'):gsub('^[_%.%-]+', ''):gsub('[_%.%-]+$', '')
  s = s:sub(1, max or 80)
  return s ~= '' and s or 'download'
end

-- split 'name.ext' (ext lowercased, '' when none)
function Source.split_ext(name)
  local stem, ext = name:match('^(.-)%.(%w+)$')
  if not stem or stem == '' then return name, '' end
  return stem, ext:lower()
end

-- the file name a server suggests: Content-Disposition, else the URL's path
function Source.name_from(headers, url)
  local cd = headers and headers['content-disposition']
  if cd then
    local ext = cd:match("[Ff][Ii][Ll][Ee][Nn][Aa][Mm][Ee]%*%s*=%s*[%w%-]*'[%w%-]*'([^;]+)")
    if ext then return pct_decode(trim(ext)) end
    local q = cd:match('[Ff][Ii][Ll][Ee][Nn][Aa][Mm][Ee]%s*=%s*"([^"]*)"')
      or cd:match('[Ff][Ii][Ll][Ee][Nn][Aa][Mm][Ee]%s*=%s*([^;%s]+)')
    if q and q ~= '' then return (q:gsub('.*[/\\]', '')) end
  end
  local path = (url or ''):gsub('[?#].*$', ''):match('^%a+://[^/]+(/.*)$') or ''
  local last = pct_decode(path:match('([^/]*)/*$') or '')
  return last ~= '' and last or nil
end

-- `stem.ext` in `dir`, or `stem-2.ext`, `stem-3.ext`… (exists(path) -> bool)
function Source.unique(dir, stem, ext, exists)
  local dot = ext ~= '' and ('.' .. ext) or ''
  local p = dir .. stem .. dot
  local n = 1
  while exists(p) do
    n = n + 1
    p = dir .. stem .. '-' .. n .. dot
  end
  return p
end

-- a name without an audio file extension ('wind.wav' -> 'wind')
function Source.title(name)
  local stem, ext = Source.split_ext(name or '')
  if AUDIO_EXT[ext] then return stem end
  return name
end

-- the file name for a Freesound sound: <id>-<username>-<name>
function Source.freesound_stem(fs)
  return Source.safe(fs.id .. '-' .. (fs.username or '') .. '-' .. Source.split_ext(fs.name or ''), 90)
end

---- HTTP

-- the headers of the last response in a curl -D dump (redirects come first)
-- -> { status = n, [lowercase name] = value }
function Source.parse_headers(text)
  local h = {}
  for line in (text or ''):gsub('\r', ''):gmatch('[^\n]*') do
    local code = line:match('^HTTP/[%d%.]+%s+(%d+)')
    if code then
      h = { status = tonumber(code) }
    else
      local k, v = line:match('^([%w%-]+):%s*(.-)%s*$')
      if k then h[k:lower()] = v end
    end
  end
  return h
end

---- file types

-- the audio type from a file's first bytes: wav, flac, ogg, aiff, mp3, m4a,
-- html (an error page), or nil
function Source.sniff(b)
  if type(b) ~= 'string' or #b < 4 then return nil end
  local h4 = b:sub(1, 4)
  if (h4 == 'RIFF' or h4 == 'RF64' or h4 == 'BW64') and b:sub(9, 12) == 'WAVE' then return 'wav' end
  if h4 == 'fLaC' then return 'flac' end
  if h4 == 'OggS' then return 'ogg' end
  if h4 == 'FORM' and (b:sub(9, 12) == 'AIFF' or b:sub(9, 12) == 'AIFC') then return 'aiff' end
  if b:sub(1, 3) == 'ID3' then return 'mp3' end
  local b1, b2 = b:byte(1, 2)
  if b1 == 0xFF and b2 and b2 & 0xE0 == 0xE0 then return 'mp3' end
  if b:sub(5, 8) == 'ftyp' then return 'm4a' end
  local lead = b:gsub('^%s+', ''):sub(1, 15):lower()
  if lead:sub(1, 1) == '<' and (lead:find('html', 1, true) or lead:find('<!doctype', 1, true)
    or lead:find('<?xml', 1, true)) then return 'html' end
  if lead:sub(1, 1) == '{' then return 'json' end
  return nil
end

-- what to do with a type: 'keep' (wav, flac), 'sox' (sox reads it),
-- 'ffmpeg' (needs ffmpeg), or nil (not audio)
local HOW = { wav = 'keep', flac = 'keep', ogg = 'sox', aiff = 'sox', mp3 = 'ffmpeg', m4a = 'ffmpeg' }
function Source.how(kind) return HOW[kind] end

---- licenses

-- a Creative Commons license URL (as the Freesound API gives it) -> a name
function Source.license_name(url)
  if type(url) ~= 'string' then return nil end
  local u = url:lower()
  local ver = u:match('/(%d+%.%d+)/?$') or ''
  if u:find('publicdomain/zero', 1, true) then return 'Creative Commons 0' end
  if u:find('sampling%+') then return 'Sampling+' end
  local kind = u:match('/licenses/([%a%-]+)/')
  local names = {
    by = 'Attribution', ['by-nc'] = 'Attribution NonCommercial', ['by-sa'] = 'Attribution ShareAlike',
    ['by-nd'] = 'Attribution NoDerivs', ['by-nc-sa'] = 'Attribution NonCommercial ShareAlike',
    ['by-nc-nd'] = 'Attribution NonCommercial NoDerivs',
  }
  if kind and names[kind] then return names[kind] .. (ver ~= '' and (' ' .. ver) or '') end
  return url
end

function Source.noncommercial(license)
  return type(license) == 'string' and (license:find('NonCommercial', 1, true) or license:lower():find('by%-nc')) ~= nil
end

---- from the Freesound API

-- Freesound descriptions can hold HTML (links, <br>)
function Source.plain(s)
  if type(s) ~= 'string' then return '' end
  s = s:gsub('\r', ''):gsub('<[Bb][Rr]%s*/?>', '\n'):gsub('<[^>]*>', '')
  s = s:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&#39;', "'"):gsub('&amp;', '&')
  return trim(s)
end

local function str(x) return type(x) == 'string' and x ~= '' and x or nil end
local function num(x) return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge and x or nil end

-- a sound instance (decoded JSON) -> source; file: 'original' | 'preview-hq-ogg'
function Source.from_freesound(snd, file, now, null)
  local function v(x) if x == null then return nil end return x end
  local tags = {}
  for _, t in ipairs(type(v(snd.tags)) == 'table' and snd.tags or {}) do
    if type(t) == 'string' then tags[#tags + 1] = t end
  end
  local id = math.tointeger(num(v(snd.id))) or 0
  local page = str(v(snd.url)) or ('https://freesound.org/s/' .. id .. '/')
  local lic_url = str(v(snd.license))
  local fs = {
    id = id,
    name = str(v(snd.name)) or tostring(id),
    username = str(v(snd.username)),
    url = page,
    license = Source.license_name(lic_url),
    description = Source.plain(v(snd.description)),
    tags = tags,
    created = str(v(snd.created)),
    pack = str(v(snd.pack)),
    geotag = str(v(snd.geotag)),
    file = file,
    original = {
      type = str(v(snd.type)),
      samplerate = num(v(snd.samplerate)),
      channels = num(v(snd.channels)),
      duration = num(v(snd.duration)),
      filesize = num(v(snd.filesize)),
      md5 = str(v(snd.md5)),
    },
  }
  return {
    kind = 'freesound',
    url = 'freesound:' .. id,
    author = fs.username,
    license = fs.license,
    license_url = lic_url,
    title = fs.name,
    downloaded = now,
    freesound = fs,
  }
end

---- crediting

-- one line: "<name>" by <author> (<page>), <license>
function Source.credit(src)
  if type(src) ~= 'table' then return nil end
  local fs = src.freesound
  local title = src.title or (fs and fs.name)
  local page = fs and ('https://freesound.org/s/' .. fs.id .. '/') or src.url
  local s = title and ('"' .. title .. '"') or ''
  if src.author then s = s .. (s ~= '' and ' by ' or 'by ') .. src.author end
  if page then s = s .. (s ~= '' and ' (' .. page .. ')' or page) end
  s = s .. ', ' .. (src.license or 'license unknown')
  return s
end

-- a license name, short: 'Attribution NonCommercial 4.0' -> 'CC BY-NC 4.0'
function Source.license_short(l)
  if type(l) ~= 'string' then return nil end
  if l == 'Creative Commons 0' then return 'CC0' end
  local words, ver = l:match('^(Attribution[%a ]*)%s+(%d+%.%d+)$')
  if not words then words, ver = l:match('^(Attribution[%a ]*)$'), nil end
  if not words then return l end
  local code = { 'BY' }
  for w in words:gmatch('%a+') do
    local c = ({ NonCommercial = 'NC', ShareAlike = 'SA', NoDerivs = 'ND' })[w]
    if c then code[#code + 1] = c end
  end
  return 'CC ' .. table.concat(code, '-') .. (ver and (' ' .. ver) or '')
end

-- author, license (short): the tape popup's source row
function Source.short(src)
  if type(src) ~= 'table' then return nil end
  return (src.author or '?') .. ', ' .. (Source.license_short(src.license) or '?')
end

-- the sidecar <file>.source.txt: the credit line, then the fields
function Source.sidecar(src)
  local o = { Source.credit(src), '' }
  local function add(k, val)
    if val ~= nil and val ~= '' then o[#o + 1] = k .. ': ' .. tostring(val):gsub('\n', ' ') end
  end
  add('kind', src.kind)
  add('requested', src.url)
  add('final url', src.final_url)
  add('content type', src.content_type)
  add('last modified', src.last_modified)
  add('title', src.title)
  add('author', src.author)
  add('license', src.license)
  add('license url', src.license_url)
  if src.downloaded then add('downloaded', os.date('!%Y-%m-%d %H:%M:%S UTC', src.downloaded)) end
  local fs = src.freesound
  if fs then
    add('freesound id', fs.id)
    add('freesound page', fs.url)
    add('freesound file', fs.file)
    add('created', fs.created)
    add('pack', fs.pack)
    add('geotag', fs.geotag)
    if #fs.tags > 0 then add('tags', table.concat(fs.tags, ' ')) end
    local og = fs.original or {}
    add('original', table.concat({ og.type or '?', og.samplerate and (og.samplerate .. ' Hz') or nil,
      og.channels and (og.channels .. ' ch') or nil, og.duration and string.format('%.3f s', og.duration) or nil,
      og.filesize and (og.filesize .. ' bytes') or nil }, ', '))
    add('md5', og.md5)
    if fs.description ~= '' then
      o[#o + 1] = ''
      o[#o + 1] = fs.description
    end
  end
  o[#o + 1] = ''
  return table.concat(o, '\n')
end

-- the first note of a Freesound tape: label, note text and tags (Freesound's
-- tags become the mark's aurotate tags, so the tape's tag picker and the
-- regions filter offer them; the palette in tags.lua stays as it is)
function Source.first_note(src)
  local fs = src.freesound
  if not fs then return nil end
  local parts = {}
  if fs.description ~= '' then parts[#parts + 1] = fs.description end
  parts[#parts + 1] = Source.credit(src)
  local tags = {}
  for i, t in ipairs(fs.tags) do tags[i] = t end
  return fs.name, table.concat(parts, '\n\n'), tags
end

---- validation (Model.validate)

local function clean_str_list(t)
  local out = {}
  if type(t) == 'table' then
    for _, s in ipairs(t) do
      if type(s) == 'string' and s ~= '' then out[#out + 1] = s end
    end
  end
  return out
end

function Source.clean(src)
  if type(src) ~= 'table' or (src.kind ~= 'freesound' and src.kind ~= 'url') then return nil end
  local out = {
    kind = src.kind, url = str(src.url), final_url = str(src.final_url), content_type = str(src.content_type),
    last_modified = str(src.last_modified), author = str(src.author), license = str(src.license),
    license_url = str(src.license_url), title = str(src.title), downloaded = num(src.downloaded),
  }
  local fs = src.freesound
  if src.kind == 'freesound' then
    if type(fs) ~= 'table' or not math.tointeger(num(fs.id)) then return nil end
    local og = type(fs.original) == 'table' and fs.original or {}
    out.freesound = {
      id = math.tointeger(fs.id), name = str(fs.name) or tostring(fs.id), username = str(fs.username),
      url = str(fs.url), license = str(fs.license), description = type(fs.description) == 'string' and fs.description or '',
      tags = clean_str_list(fs.tags), created = str(fs.created), pack = str(fs.pack), geotag = str(fs.geotag),
      file = str(fs.file),
      original = { type = str(og.type), samplerate = num(og.samplerate), channels = num(og.channels),
        duration = num(og.duration), filesize = num(og.filesize), md5 = str(og.md5) },
    }
  end
  return out
end

return Source

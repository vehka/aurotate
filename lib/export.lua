-- export: the tape's notes as files for a computer (docs/PLAN.md §5)
--
--   <data>/exports/<tape id>/notes.md    one section per mark / region
--
-- Pure Lua (no norns calls) apart from Export.write's mkdir, so it can be
-- tested off the device. The previous export is kept as notes.md.bak: once
-- phase 5b reads edits back from notes.md, an export must not silently eat
-- what was written there.
--
-- notes.md, for a re-import later (phase 5b):
--   - each item is a `## ` heading followed by `<!-- aur:<id> -->`; the id
--     (m3, r12) is what matches it to the document, the rest is for reading
--   - the line after it is metadata (id, exact times, enclosing region, tags,
--     a region's sound settings that differ from neutral)
--   - then the note, verbatim. Lines that would read as a heading or an aur
--     comment get a leading backslash (Markdown shows `\#` as `#`); a re-import
--     strips one backslash from such lines.

local Model = include 'lib/model'
local Sound = include 'lib/sound'

local Export = {}

-- times: H:MM:SS for tapes of an hour or more, M:SS for shorter ones, so the
-- columns line up within one tape; `ms` adds .mmm
function Export.tc(t, long, ms)
  t = math.max(0, t)
  local whole = math.floor(t)
  local frac = math.floor((t - whole) * 1000 + 0.5)
  if frac >= 1000 then whole, frac = whole + 1, frac - 1000 end
  local h, m, s = whole // 3600, whole // 60 % 60, whole % 60
  local out
  if long or h > 0 then
    out = string.format('%d:%02d:%02d', h, m, s)
  else
    out = string.format('%d:%02d', m, s)
  end
  if ms then out = out .. string.format('.%03d', frac) end
  return out
end

-- tags as hashtags (Obsidian, Logseq); a tag with spaces or punctuation as
-- #[[tag]] (Logseq), so it stays one tag
function Export.hashtag(tag)
  if tag:match('^[%w_%-/]+$') and not tag:match('^%d+$') then return '#' .. tag end
  return '#[[' .. tag .. ']]'
end

-- a line of a note that Markdown (or the re-import) would take as structure
local function escape_line(line)
  local pre, rest = line:match('^(%s*)(.*)$')
  if rest:match('^\\*#') or rest:match('^\\*<!%-%-') then return pre .. '\\' .. rest end
  return line
end

function Export.escape_note(note)
  local out = {}
  for line in (note .. '\n'):gmatch('(.-)\n') do out[#out + 1] = escape_line(line) end
  -- no trailing blank lines (the section break adds its own)
  while #out > 0 and out[#out]:match('^%s*$') do out[#out] = nil end
  return table.concat(out, '\n')
end

-- the inverse of escape_note, for the re-import
function Export.unescape_note(text)
  local out = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    local pre, rest = line:match('^(%s*)(.*)$')
    if rest:match('^\\+#') or rest:match('^\\+<!%-%-') then line = pre .. rest:sub(2) end
    out[#out + 1] = line
  end
  return table.concat(out, '\n')
end

-- a label on one line (labels come from textentry, but a document is a file
-- anyone can edit)
local function one_line(s) return (s:gsub('%s*\n%s*', ' ')) end

-- marks and regions merged by start time; at the same time a region comes
-- before the marks in it, a longer region before a shorter one
function Export.items(doc)
  local all = {}
  for _, r in ipairs(doc.regions) do all[#all + 1] = r end
  for _, m in ipairs(doc.marks) do all[#all + 1] = m end
  table.sort(all, function(a, b)
    local sa, sb = Model.start(a), Model.start(b)
    if sa ~= sb then return sa < sb end
    local ra, rb = Model.is_region(a), Model.is_region(b)
    if ra ~= rb then return ra end
    if ra and a.t1 ~= b.t1 then return a.t1 > b.t1 end
    local na, nb = tonumber(a.id:sub(2)) or 0, tonumber(b.id:sub(2)) or 0
    return na < nb
  end)
  return all
end

-- the innermost region that holds `item`: for a mark, one it plays inside
-- (end exclusive, as on the tape); for a region, a longer one around it
function Export.parent(doc, item)
  if not Model.is_region(item) then return Model.innermost(doc, item.t) end
  local best
  local len = item.t1 - item.t0
  for _, r in ipairs(doc.regions) do
    if r.t0 > item.t0 then break end
    local rl = r.t1 - r.t0
    if r ~= item and item.t1 <= r.t1 and rl > len and (best == nil or rl < best.t1 - best.t0) then best = r end
  end
  return best
end

local function name(item)
  local l = one_line(item.label or '')
  return l ~= '' and l or nil
end

-- the whole file as a string. opts: now (os.time() for the "exported" line),
-- id (the tape's document id)
function Export.markdown(doc, opts)
  opts = opts or {}
  local tape = doc.tape
  local long = (tape.dur or 0) >= 3600
  local items = Export.items(doc)
  local o = {}
  local function add(s) o[#o + 1] = s end

  local title = one_line(tape.title ~= '' and tape.title or (tape.path or ''):match('[^/]*$') or 'tape')
  add('# ' .. title)
  add('')
  if tape.path then add('- file: `' .. tape.path .. '`') end
  if tape.dur then add('- length: ' .. Export.tc(tape.dur, long)) end
  add(string.format('- %d %s, %d %s', #doc.marks, #doc.marks == 1 and 'mark' or 'marks',
    #doc.regions, #doc.regions == 1 and 'region' or 'regions'))
  local tags = Model.tags(doc)
  if #tags > 0 then
    local h = {}
    for i, tag in ipairs(tags) do h[i] = Export.hashtag(tag) end
    add('- tags: ' .. table.concat(h, ' '))
  end
  add('- exported: ' .. os.date('%Y-%m-%d %H:%M', opts.now or os.time()) .. ' (aurotate)')
  add('')
  add('<!-- aur:tape ' .. (opts.id or '') .. ' -->')
  add('<!-- Times are offsets into the file. Each section is matched to the tape by')
  add('     the aur comment under its heading; keep those lines as they are. -->')

  if #items == 0 then
    add('')
    add('*No marks or regions yet.*')
  end

  for _, item in ipairs(items) do
    add('')
    local meta = { '`' .. item.id .. '`' }
    local head
    if Model.is_region(item) then
      head = Export.tc(item.t0, long) .. '–' .. Export.tc(item.t1, long)
      meta[#meta + 1] = string.format('region %s–%s (%s)', Export.tc(item.t0, long, true),
        Export.tc(item.t1, long, true), Export.tc(item.t1 - item.t0, false, false))
    else
      head = Export.tc(item.t, long)
      meta[#meta + 1] = 'mark ' .. Export.tc(item.t, long, true)
    end
    local p = Export.parent(doc, item)
    if p then meta[#meta + 1] = 'in ' .. (name(p) and (name(p) .. ' (`' .. p.id .. '`)') or ('`' .. p.id .. '`')) end
    if #item.tags > 0 then
      local h = {}
      for i, tag in ipairs(item.tags) do h[i] = Export.hashtag(tag) end
      meta[#meta + 1] = table.concat(h, ' ')
    end
    if item.snd then
      local h = {}
      for _, f in ipairs(Sound.FIELDS) do
        if item.snd[f] ~= nil then h[#h + 1] = f:gsub('_', ' ') .. ' ' .. Sound.format(f, item.snd[f]) end
      end
      meta[#meta + 1] = 'sound: ' .. table.concat(h, ', ')
    end
    add('## ' .. head .. (name(item) and (' · ' .. name(item)) or ''))
    add('<!-- aur:' .. item.id .. ' -->')
    add(table.concat(meta, ' · '))
    local note = Export.escape_note(item.note or '')
    if note:match('%S') then
      add('')
      add(note)
    end
  end
  add('')
  return table.concat(o, '\n')
end

-- write the export for `doc` under `dir` (the data dir, trailing slash).
-- Returns the path written, or nil and an error.
function Export.write(doc, dir, id, write_file, now)
  local out = dir .. 'exports/' .. id .. '/'
  os.execute("mkdir -p '" .. out:gsub("'", "'\\''") .. "'")
  local path = out .. 'notes.md'
  local ok, err = write_file(path, Export.markdown(doc, { now = now, id = id }))
  if not ok then return nil, err end
  return path
end

return Export

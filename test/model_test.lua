-- model + store tests, off the device: `lua5.3 test/model_test.lua` from the
-- repo root (on the device they run from the REPL with notes_test())

local on_norns = include ~= nil
if not on_norns then
  include = function(p) return dofile(p .. '.lua') end
end

local Model = include 'lib/model'
local Store = include 'lib/store'

local T = {}
local fails, passes = 0, 0
local function check(name, ok, detail)
  if ok then
    passes = passes + 1
  else
    fails = fails + 1
    print('FAIL ' .. name .. (detail and (': ' .. tostring(detail)) or ''))
  end
end

local function rm_rf(d) os.execute("rm -rf '" .. d .. "'") end

function T.run(dir)
  fails, passes = 0, 0
  dir = dir or (os.getenv('TMPDIR') or '/tmp') .. '/aurotate-model-test-' .. os.time() .. '/'
  rm_rf(dir)
  local now = 1000
  Store.init(dir, function() return now end)
  Model.changed = function() Store.touch() end

  -- model basics
  local doc = Model.new('/x/tape one.flac', 3600, 123)
  local m2 = Model.add_mark(doc, 20)
  local m1 = Model.add_mark(doc, 10)
  check('marks sorted', doc.marks[1] == m1 and doc.marks[2] == m2)
  check('ids', m2.id == 'm1' and m1.id == 'm2', m2.id .. ' ' .. m1.id)
  local outer = Model.add_region(doc, 100, 50)
  local inner = Model.add_region(doc, 60, 70)
  check('region order', outer.t0 == 50 and outer.t1 == 100)
  check('too short', Model.add_region(doc, 5, 5.01) == nil)
  check('innermost', Model.innermost(doc, 65) == inner)
  check('innermost outside', Model.innermost(doc, 80) == outer)
  check('none', Model.innermost(doc, 200) == nil)
  local at = Model.regions_at(doc, 65)
  check('regions_at outermost first', at[1] == outer and at[2] == inner and #at == 2)
  check('mark near', Model.mark_near(doc, 10.2, 0.25) == m1)
  check('mark not near', Model.mark_near(doc, 11, 0.25) == nil)
  check('at prefers mark', Model.at(doc, 10.1, 0.25) == m1)
  check('end exclusive', Model.innermost(doc, 70) == outer)
  Model.move(doc, inner, 't1', 40) -- can't cross t0
  check('edge clamp', math.abs(inner.t1 - (inner.t0 + Model.MIN_REGION)) < 1e-9, inner.t1)
  Model.move(doc, m1, 't', 30)
  check('resort marks', doc.marks[1] == m2 and doc.marks[2] == m1)
  Model.toggle_tag(doc, m1, 'kin')
  Model.toggle_tag(doc, outer, 'place')
  check('tags', table.concat(Model.tags(doc), ',') == 'kin,place')
  Model.toggle_tag(doc, m1, 'kin')
  check('untag', #m1.tags == 0)

  -- store: a round trip
  local path = '/x/tape one.flac'
  local d = Store.open(path, 3600, 999)
  check('new doc', #d.marks == 0 and d.tape.path == path)
  check('nothing pending', not Store.pending())
  local m = Model.add_mark(d, 12.345678901)
  Model.set(d, m, 'note', 'line one\nline "two" ä\\')
  Model.toggle_tag(d, m, 'story')
  local r = Model.add_region(d, 1.5, 9.25)
  Model.set(d, r, 'label', 'intro')
  check('pending after edit', Store.pending())
  Store.tick()
  check('debounced', Store.pending())
  now = now + 3
  Store.tick()
  check('saved', not Store.pending())
  local f = io.open(Store.path_of(path))
  check('file exists', f ~= nil)
  if f then f:close() end
  Store.close(42.5)
  local d2, msg = Store.open(path, 3600, 999)
  check('reload msg', msg == nil, msg)
  check('reload marks', #d2.marks == 1 and d2.marks[1].note == 'line one\nline "two" ä\\', d2.marks[1] and d2.marks[1].note)
  check('reload rounded to ms', d2.marks[1].t == 12.346, d2.marks[1].t)
  check('reload tags', d2.marks[1].tags[1] == 'story')
  check('reload region', #d2.regions == 1 and d2.regions[1].label == 'intro' and d2.regions[1].t1 == 9.25)
  check('last pos', d2.tape.last_pos == 42.5, d2.tape.last_pos)
  check('next id', d2.next_id == 3, d2.next_id)
  check('last tape', Store.last() == path)

  -- .bak keeps the previous save
  Model.add_mark(d2, 99)
  Store.flush()
  local bak = loadfile(Store.path_of(path) .. '.bak', 't', {})
  check('bak is previous', bak and #bak().marks == 1)

  -- corrupt file: set aside, previous save restored
  Store.close()
  local fw = io.open(Store.path_of(path), 'w')
  fw:write('return { version = 1, marks = { oops')
  fw:close()
  local d3, msg3 = Store.open(path, 3600)
  check('corrupt -> bak', d3 and #d3.marks == 1, #d3.marks)
  check('corrupt msg', msg3 and msg3:find('previous', 1, true), msg3)
  local ls = io.popen("ls '" .. dir .. "tapes/'"):read('a')
  check('corrupt kept aside', ls:find('corrupt', 1, true), ls)
  Store.close()

  -- newer version: read-only, never overwritten
  local p2 = '/x/newer.wav'
  fw = io.open(Store.path_of(p2), 'w')
  fw:write('return { version = 99, marks = {} }')
  fw:close()
  local d4, msg4 = Store.open(p2, 10)
  check('newer readonly', Store.readonly() ~= nil and msg4 ~= nil, msg4)
  Model.add_mark(d4, 1)
  Store.flush()
  Store.close(5)
  local src = io.open(Store.path_of(p2)):read('a')
  check('newer untouched', src:find('version = 99', 1, true) ~= nil)

  -- damaged entries are left out, not fatal
  local p3 = '/x/partial.wav'
  fw = io.open(Store.path_of(p3), 'w')
  fw:write([[return { version = 1, next_id = 2, marks = { { id = "m1", t = 3 }, { id = "m1", t = 4 }, { t = 5 } },
    regions = { { id = "r7", t0 = 2, t1 = 1 }, { id = "r8", t0 = 1, t1 = 2, tags = { "a", 3, "a" } } } }]])
  fw:close()
  local d5, msg5 = Store.open(p3, 10)
  check('partial marks', #d5.marks == 1 and d5.marks[1].label == '')
  check('partial regions', #d5.regions == 1 and #d5.regions[1].tags == 1)
  check('partial next id above max', d5.next_id == 9, d5.next_id)
  check('partial msg', msg5 and msg5:find('3 damaged', 1, true), msg5)
  Store.close()

  -- a tape with no notes writes no file
  local p4 = '/x/empty.wav'
  Store.open(p4, 10)
  Store.close(5)
  check('no file for empty tape', io.open(Store.path_of(p4)) == nil)

  -- palette
  local pal = Store.palette()
  check('palette defaults', #pal == #Store.DEFAULT_TAGS)
  check('palette file', io.open(dir .. 'tags.lua') ~= nil)

  -- the id: same name, other folder → other document
  check('ids differ', Store.id('/a/x.wav') ~= Store.id('/b/x.wav'))

  -- markdown export
  local Export = include 'lib/export'
  check('tc short', Export.tc(83.45, false) == '1:23', Export.tc(83.45, false))
  check('tc long ms', Export.tc(3723.0456, true, true) == '1:02:03.046', Export.tc(3723.0456, true, true))
  check('tc carry', Export.tc(59.9996, false, true) == '1:00.000', Export.tc(59.9996, false, true))
  check('hashtag', Export.hashtag('story') == '#story' and Export.hashtag('two words') == '#[[two words]]')
  local tricky = '# not a heading\n  <!-- aur:m1 -->\n\\# already\nplain #tag'
  local esc = Export.escape_note(tricky)
  check('escape', esc == '\\# not a heading\n  \\<!-- aur:m1 -->\n\\\\# already\nplain #tag', esc)
  check('unescape round trip', Export.unescape_note(esc) == tricky, Export.unescape_note(esc))
  local e = Model.new('/x/talk.flac', 4000, 1)
  local outer_r = Model.add_region(e, 100, 400)
  Model.set(e, outer_r, 'label', 'arrival')
  local inner_r = Model.add_region(e, 150, 160)
  local em = Model.add_mark(e, 155)
  Model.set(e, em, 'note', 'she says "yes"\n\n# not a heading\n')
  Model.toggle_tag(e, em, 'story')
  local early = Model.add_mark(e, 100) -- same start as the region: after it
  local at_end = Model.add_mark(e, 400) -- the end is outside the region
  local md = Export.markdown(e, { now = 0, id = 'talk-1234' })
  local order = {}
  for id in md:gmatch('<!%-%- aur:([mr]%d+) %-%->') do order[#order + 1] = id end
  check('md order', table.concat(order, ',') == table.concat({ outer_r.id, early.id, inner_r.id, em.id, at_end.id }, ','),
    table.concat(order, ','))
  check('md tape id', md:find('<!-- aur:tape talk-1234 -->', 1, true) ~= nil)
  check('md region heading', md:find('## 0:01:40–0:06:40 · arrival\n', 1, true) ~= nil)
  check('md mark meta', md:find('`' .. em.id .. '` · mark 0:02:35.000 · in `' .. inner_r.id .. '` · #story', 1, true) ~= nil)
  check('md nested region', md:find('in arrival (`' .. outer_r.id .. '`)', 1, true) ~= nil)
  check('md end exclusive', not md:find('mark 0:06:40.000 · in', 1, true))
  check('md note escaped', md:find('\n\\# not a heading\n', 1, true) ~= nil)
  check('md no stray headings', select(2, md:gsub('\n## ', '')) == 5)
  check('md empty', Export.markdown(Model.new('/x/e.wav', 10, 1), { now = 0 }):find('No marks', 1, true) ~= nil)
  local p_md = Export.write(e, dir, 'talk-1234', Store.write_file, 0)
  Export.write(e, dir, 'talk-1234', Store.write_file, 0)
  check('md written', p_md and io.open(p_md) ~= nil)
  check('md bak', p_md and io.open(p_md .. '.bak') ~= nil)

  -- region sound (phase 6)
  local Sound = include 'lib/sound'
  local s = Model.new('/x/snd.flac', 1000, 1)
  local big = Model.add_region(s, 100, 300)
  local mid = Model.add_region(s, 150, 200)
  local plain = Model.add_region(s, 400, 500)
  check('snd none', not Sound.has(big) and #Sound.segments(s) == 0)
  Model.set_snd(s, big, 'gain', -6)
  Model.set_snd(s, big, 'send_a', 0.4)
  Model.set_snd(s, big, 'dry', 0.5)
  Model.set_snd(s, mid, 'send_a', 0.8)
  Model.set_snd(s, mid, 'dry', 0)
  Model.set_snd(s, mid, 'gain', 3)
  Model.set_snd(s, mid, 'pan', 2) -- clamped
  check('snd clamp', mid.snd.pan == 1, mid.snd.pan)
  local segs = Sound.segments(s)
  check('snd segments', #segs == 3, #segs)
  local function seg(i) return segs[i] and string.format('%g-%g', segs[i][1], segs[i][2]) end
  check('snd bounds', seg(1) == '100-150' and seg(2) == '150-200' and seg(3) == '200-300',
    tostring(seg(1)) .. ' ' .. tostring(seg(2)) .. ' ' .. tostring(seg(3)))
  local c = segs[2] and segs[2][3] or {}
  check('snd combine', c.dry == 0 and c.send_a == 1 and c.gain == -3 and c.pan == 1,
    string.format('%s %s %s %s', c.dry, c.send_a, c.gain, c.pan))
  check('snd outer alone', segs[1] and segs[1][3].dry == 0.5 and segs[1][3].send_a == 0.4)
  check('snd insert', Sound.insert_send(mid) == nil and Sound.insert_send(plain) == nil)
  Model.set_snd(s, mid, 'send_a', 1)
  check('snd insert a', Sound.insert_send(mid) == 'a')
  -- equal neighbours join; neutral stretches are left out
  local q = Model.new('/x/q.flac', 1000, 1)
  local q1 = Model.add_region(q, 10, 20)
  local q2 = Model.add_region(q, 20, 30)
  Model.set_snd(q, q1, 'tone', 0.5)
  Model.set_snd(q, q2, 'tone', 0.5)
  local qs = Sound.segments(q)
  check('snd join', #qs == 1 and qs[1][1] == 10 and qs[1][2] == 30, #qs)
  Model.set_snd(q, q2, 'tone', 0)
  check('snd back to neutral drops snd', q2.snd == nil)
  -- off gain wins
  Model.set_snd(q, q2, 'gain', -60)
  local q3 = Model.add_region(q, 22, 25)
  Model.set_snd(q, q3, 'gain', 12)
  local off = Sound.combine({ q2, q3 })
  check('snd off wins', off.gain == -60, off.gain)
  -- round trip through the store and validation
  local sv = Store.serialise(s)
  local back = Model.validate(load(sv, 'snd', 't', {})())
  local rb = back and Model.find(back, mid.id)
  check('snd round trip', rb and rb.snd and rb.snd.dry == 0 and rb.snd.send_a == 1 and rb.snd.gain == 3)
  local bad = Model.validate({ version = 1, regions = { { id = 'r1', t0 = 1, t1 = 2, snd = { dry = 'x', gain = 99, pan = 0 } } } })
  check('snd validate', bad and bad.regions[1].snd and bad.regions[1].snd.gain == 12 and bad.regions[1].snd.dry == nil
    and bad.regions[1].snd.pan == nil)
  local bad2 = Model.validate({ version = 1, regions = { { id = 'r1', t0 = 1, t1 = 2, snd = 5 } } })
  check('snd validate junk', bad2 and bad2.regions[1].snd == nil)
  local smd = Export.markdown(s, { now = 0 })
  check('md sound', smd:find('sound: dry 0%, send a 100%, gain +3.0 dB, pan R 100', 1, true) ~= nil)

  -- phase 8: bext, wall clock, reels, joins, the collection
  local Bext = include 'lib/bext'
  local Wall = include 'lib/wallclock'
  local Reel = include 'lib/reel'
  local Collection = include 'lib/collection'
  local function u32(n) return string.pack('<I4', n) end
  -- a WAV with chunks: fmt, (bext), (junk), data of `frames` frames
  local function wav(path, o)
    local ch, rate = o.ch or 1, o.rate or 48000
    local chunks = {}
    chunks[#chunks + 1] = 'fmt ' .. u32(16) .. string.pack('<I2I2I4I4I2I2', 1, ch, rate, rate * ch * 2, ch * 2, 16)
    if o.junk then chunks[#chunks + 1] = 'JUNK' .. u32(3) .. 'abc\0' end
    if o.date then
      local b = string.rep('\0', 256) .. ('zoom' .. string.rep('\0', 28)) .. string.rep('\0', 32)
        .. o.date .. o.time .. string.pack('<I4I4', (o.tr or 0) % 4294967296, (o.tr or 0) // 4294967296)
        .. string.rep('\0', 602 - 346)
      chunks[#chunks + 1] = 'bext' .. u32(#b) .. b
    end
    local data = string.rep('\0', (o.frames or 10) * ch * 2)
    chunks[#chunks + 1] = 'data' .. u32(#data) .. data
    local body = 'WAVE' .. table.concat(chunks)
    local f = io.open(path, 'wb')
    f:write('RIFF' .. u32(#body) .. body)
    f:close()
  end
  os.execute("mkdir -p '" .. dir .. "rec'")
  local rec = dir .. 'rec/'
  wav(rec .. 'ZOOM0001.WAV', { date = '2025-08-03', time = '23:59:00', tr = 86340 * 48000, frames = 960, junk = true })
  wav(rec .. 'ZOOM0001_0001.WAV', { date = '2025-08-04', time = '00:00:00', tr = 86340 * 48000 + 960, frames = 480 })
  wav(rec .. 'ZOOM0001_0002.WAV', { date = '2025-08-04', time = '00:00:00', tr = 1, frames = 480 }) -- a gap
  wav(rec .. 'ZOOM0002.WAV', { ch = 2, frames = 100 })
  wav(rec .. 'plain.wav', { frames = 10 })
  local b = Bext.read(rec .. 'ZOOM0001.WAV')
  check('bext read', b and b.date == '2025-08-03' and b.time == '23:59:00' and b.rate == 48000 and b.frames == 960
    and b.originator == 'zoom', b and (tostring(b.date) .. ' ' .. tostring(b.frames)))
  check('bext none', Bext.read(rec .. 'plain.wav') == nil)
  check('bext not wav', Bext.read(dir .. 'tags.lua') == nil)
  local o = Bext.origin(b)
  check('bext origin', o and o.date == '2025-08-03' and o.secs == 86340 and o.source == 'bext', o and o.secs)
  check('bext origin bad time_ref', Bext.origin({ date = '2025-01-01', time = '10:00:00', time_ref = 5, rate = 48000 }).secs == 36000)
  -- wall clock
  local w = Wall.parse('2025-08-03 14:32:07')
  check('wall parse', w and w.secs == 14 * 3600 + 32 * 60 + 7 and w.source == 'manual')
  check('wall parse short', Wall.parse('2025-8-3 9:05').secs == 9 * 3600 + 300)
  check('wall parse bad', Wall.parse('2025-02-30 10:00') == nil and Wall.parse('nope') == nil and Wall.parse('2025-01-01 24:00') == nil)
  check('wall time', Wall.time(w, 60.25, true) == '14:33:07.2', Wall.time(w, 60.25, true))
  check('wall midnight', Wall.stamp(o, 90) == '2025-08-04 00:00:30', Wall.stamp(o, 90))
  check('wall shift back', Wall.stamp(Wall.shift(Wall.parse('2025-03-01 00:00:30'), -60)) == '2025-02-28 23:59:30')
  check('wall date label', Wall.date_label(w) == '3 Aug 2025')
  check('wall clean', Wall.clean({ date = '2025-13-01', secs = 1 }) == nil and Wall.clean(w).secs == w.secs)
  local wd = Model.new('/x/w.wav', 10, 1)
  wd.tape.origin = w
  local wb = Model.validate(load(Store.serialise(wd), 'w', 't', {})())
  check('origin round trip', wb.tape.origin and wb.tape.origin.secs == w.secs and wb.tape.origin.date == w.date)
  -- reels
  local function info(p)
    local bb = Bext.read(p)
    if bb then return bb.channels, bb.frames, bb.rate end
    local f = io.open(p, 'rb')
    if not f then return 0, 0, 0 end
    local h = f:read(44)
    f:close()
    local ch, rate = string.unpack('<I2I4', h, 23)
    return ch, string.unpack('<I4', h, 41) // (ch * 2), rate
  end
  local function ls(d)
    local out = {}
    local pipe = io.popen("ls -p '" .. d .. "'")
    for n in pipe:lines() do out[#out + 1] = n end
    pipe:close()
    return out
  end
  check('reel parse', table.concat(Reel.parse('# c\n a.wav \n\n/abs/b.wav\r\n', '/d/'), ',') == '/d/a.wav,/abs/b.wav')
  local cands, confirmed = Reel.candidates(rec .. 'ZOOM0001.WAV', ls, info)
  check('reel candidates', #cands == 3 and confirmed == 1 and cands[2].continuous == true and cands[3].continuous == false,
    #cands .. ' ' .. confirmed)
  check('reel continues midnight', Reel.continues({ time_ref = 86400 * 48000 - 100, rate = 48000 }, { time_ref = 5 }, 105))
  local rp = Reel.new_path(rec .. 'ZOOM0001.WAV', function(p) return p == rec .. 'ZOOM0001.reel' end)
  check('reel new path', rp == rec .. 'ZOOM0001-2.reel', rp)
  local f = io.open(rec .. 'Z.reel', 'w')
  f:write(Reel.text({ rec .. 'ZOOM0001.WAV', rec .. 'ZOOM0001_0001.WAV' }, rec))
  f:close()
  local reel = Reel.load(rec .. 'Z.reel', info)
  check('reel load', reel and reel.frames == 1440 and #reel.parts == 2 and reel.parts[2].start == 960 and reel.rate == 48000)
  f = io.open(rec .. 'bad.reel', 'w')
  f:write('ZOOM0001.WAV\nZOOM0002.WAV\nmissing.wav\n')
  f:close()
  local nr, why = Reel.load(rec .. 'bad.reel', info)
  check('reel mixed formats', nr == nil and why:find('part 2 differs', 1, true), why)
  -- joining notes: part 2's notes land after part 1
  local big1 = Model.new('/x/a.wav', 100, 1)
  Model.add_mark(big1, 5)
  local big2 = Model.new('/x/b.wav', 100, 1)
  local rr = Model.add_region(big2, 1, 2)
  Model.set_snd(big2, rr, 'gain', -6)
  Model.add_mark(big2, 3)
  local jj = Model.new('/x/ab.reel', 200, 1)
  Model.append(jj, big1, 0)
  Model.append(jj, big2, 100)
  check('append offsets', #jj.marks == 2 and jj.marks[2].t == 103 and jj.regions[1].t0 == 101
    and jj.regions[1].snd.gain == -6 and jj.regions[1].snd ~= rr.snd)
  check('append ids', jj.marks[1].id == 'm1' and jj.regions[1].id == 'r3' and jj.next_id == 4,
    jj.marks[1].id .. jj.regions[1].id .. jj.next_id)
  -- the collection index
  Collection.init(dir, Store)
  Store.put('/x/old.wav', (function()
    local od = Model.new('/x/old.wav', 50, 7)
    Model.add_mark(od, 3)
    return od
  end)())
  local entries = Collection.load(function() return Store.all_docs(ls) end)
  local found_old = Collection.find('/x/old.wav')
  local n_boot = #entries
  check('collection bootstrap', found_old and found_old.marks == 1 and found_old.dur == 50, #entries)
  Collection.update('/x/new.wav', { dur = 10, opened = 5 })
  Collection.update('/x/old.wav', { opened = 9 })
  Collection.save()
  Collection.init(dir, Store)
  check('collection reload', Collection.find('/x/new.wav') ~= nil and #Collection.entries() == n_boot + 1)
  local sorted = Collection.sorted('recent')
  check('collection recent', sorted[1].path == '/x/old.wav', sorted[1].path)
  check('collection name', Collection.sorted('name')[1].path == '/x/new.wav')
  Collection.rename('/x/old.wav', '/y/old.wav')
  check('collection rename', Collection.find('/y/old.wav') and not Collection.find('/x/old.wav'))
  check('store move', Store.move('/x/old.wav', '/y/old.wav') and Store.peek('/y/old.wav') ~= nil
    and Store.peek('/x/old.wav') == nil)
  -- the overview strip reads only the coarsest level
  local pk = dir .. 'p.peaks'
  local n0, n1, n2 = 512, 32, 4
  local recs = {}
  for i = 1, n0 + n1 do recs[i] = string.char(0, 0, 0, 0) end
  for i = 1, n2 do recs[#recs + 1] = string.char(0, 0, i == 1 and 50 or 100, 0) end
  f = io.open(pk, 'wb')
  f:write('AURPK2\0\0' .. string.pack('<I4I4I4I4I8I4I4', 960, 48000, 1, n0, n0 * 960, n1, n2) .. table.concat(recs))
  f:close()
  local strip = Collection.strip(pk, 4)
  check('strip coarse level', strip and #strip == 4 and math.abs(strip[1] - 0.5) < 1e-9 and strip[4] == 1,
    strip and table.concat(strip, ','))
  local strip2 = Collection.strip(pk, 8) -- wider than level 2: level 1 (all zero)
  check('strip finer level', strip2 and strip2[1] == 0)
  -- export with a start time
  local ed = Model.new('/x/talk.wav', 4000, 1)
  ed.tape.origin = Wall.parse('2025-08-03 14:00:00')
  Model.add_mark(ed, 100)
  local emd = Export.markdown(ed, { now = 0, parts = { '/x/a.wav', '/x/b.wav' } })
  check('md wall heading', emd:find('## 0:01:40 (14:01:40)', 1, true) ~= nil)
  check('md recorded', emd:find('- recorded: 2025-08-03 14:00:00 – 2025-08-03 15:06:40 (set by hand)', 1, true) ~= nil)
  check('md parts', emd:find('  - part 2: `/x/b.wav`', 1, true) ~= nil)
  check('md wall meta', emd:find('mark 0:01:40.000 · 2025-08-03 14:01:40', 1, true) ~= nil)

  print(string.format('model_test: %d passed, %d failed', passes, fails))
  if fails == 0 then rm_rf(dir) end
  return fails
end

if not on_norns then
  os.exit(T.run() == 0 and 0 or 1)
end
return T

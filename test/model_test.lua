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

  -- phase 9: JSON
  local Json = include 'lib/json'
  local jv = Json.decode('{"a": [1, 2.5, -3e2, true, false, null], "s": "x\\"\\u00e4\\ud83d\\ude00\\n", "o": {}}')
  check('json decode', jv and jv.a[1] == 1 and math.type(jv.a[1]) == 'integer' and jv.a[2] == 2.5 and jv.a[3] == -300
    and jv.a[4] == true and jv.a[5] == false and jv.a[6] == Json.null and next(jv.o) == nil)
  check('json string', jv and jv.s == 'x"ä😀\n', jv and jv.s)
  check('json errors', Json.decode('{"a": }') == nil and Json.decode('[1,') == nil and Json.decode('1 2') == nil
    and Json.decode('"abc') == nil)
  check('json null val', Json.val(Json.null) == nil and Json.val(0) == 0)
  -- SHA-256 and PKCE (RFC 7636 appendix B)
  local Pkce = include 'lib/pkce'
  check('sha256 empty', Pkce.hex(Pkce.sha256('')) == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
  check('sha256 abc', Pkce.hex(Pkce.sha256('abc')) == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
  check('sha256 two blocks', Pkce.hex(Pkce.sha256(('a'):rep(1000))) ==
    '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3')
  local rfc = string.char(116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77,
    105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121)
  check('pkce verifier', Pkce.verifier(rfc) == 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', Pkce.verifier(rfc))
  check('pkce challenge', Pkce.challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')
    == 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
  check('b64url padding', Pkce.b64url('f') == 'Zg' and Pkce.b64url('fo') == 'Zm8' and Pkce.b64url('foo') == 'Zm9v')
  -- requests, names, headers, types
  local Source = include 'lib/source'
  local r1 = Source.parse_request(' freesound:12345 ')
  check('req freesound', r1 and r1.kind == 'freesound' and r1.id == 12345)
  check('req digits', Source.parse_request('678').id == 678)
  check('req link', Source.parse_request('https://freesound.org/people/someone/sounds/4321/').id == 4321)
  check('req short link', Source.parse_request('https://freesound.org/s/99/').id == 99)
  local r2 = Source.parse_request('https://example.org/a%20b.wav?x=1')
  check('req url', r2 and r2.kind == 'url' and r2.url == 'https://example.org/a%20b.wav?x=1')
  check('req bad', Source.parse_request('ftp://x/y') == nil and Source.parse_request('# c') == nil
    and Source.parse_request('http://a b') == nil and Source.parse_request('file:///etc/passwd') == nil)
  check('name from url', Source.name_from({}, 'https://example.org/dir/a%20b.wav?x=1') == 'a b.wav')
  check('name from cd', Source.name_from({ ['content-disposition'] = 'attachment; filename="rec 1.WAV"' }, 'https://x/y')
    == 'rec 1.WAV')
  check('name from cd*', Source.name_from({ ['content-disposition'] = "attachment; filename*=UTF-8''h%C3%A4.flac" },
    'https://x/y') == 'hä.flac')
  check('name cd path stripped', Source.name_from({ ['content-disposition'] = 'attachment; filename="../../x.wav"' }, '')
    == 'x.wav')
  check('name none', Source.name_from({}, 'https://example.org/') == nil)
  check('safe', Source.safe('../hä llo!.wav') == 'h_llo_.wav', Source.safe('../hä llo!.wav'))
  check('split ext', select(2, Source.split_ext('a.b.WAV')) == 'wav' and Source.split_ext('noext') == 'noext')
  local taken = { ['/d/x.wav'] = true, ['/d/x-2.wav'] = true }
  check('unique', Source.unique('/d/', 'x', 'wav', function(p) return taken[p] end) == '/d/x-3.wav')
  local hh = Source.parse_headers('HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\nHTTP/2 200\r\ncontent-type: audio/wav\r\n'
    .. 'Last-Modified: Tue, 01 Jan 2030 00:00:00 GMT\r\n\r\n')
  check('headers last response', hh.status == 200 and hh['content-type'] == 'audio/wav' and hh.location == nil
    and hh['last-modified'] == 'Tue, 01 Jan 2030 00:00:00 GMT')
  check('sniff', Source.sniff('RIFF\0\0\0\0WAVEfmt ') == 'wav' and Source.sniff('fLaC\0\0') == 'flac'
    and Source.sniff('OggS\0\2') == 'ogg' and Source.sniff('ID3\4\0') == 'mp3' and Source.sniff('\255\251\144\0') == 'mp3'
    and Source.sniff('\0\0\0\24ftypM4A ') == 'm4a' and Source.sniff('FORM\0\0\0\0AIFF') == 'aiff'
    and Source.sniff('  <!DOCTYPE html>') == 'html' and Source.sniff('{"detail"') == 'json' and Source.sniff('abcd') == nil)
  check('how', Source.how('wav') == 'keep' and Source.how('ogg') == 'sox' and Source.how('mp3') == 'ffmpeg'
    and Source.how('html') == nil)
  check('license names', Source.license_name('http://creativecommons.org/licenses/by/4.0/') == 'Attribution 4.0'
    and Source.license_name('https://creativecommons.org/licenses/by-nc/3.0/') == 'Attribution NonCommercial 3.0'
    and Source.license_name('http://creativecommons.org/publicdomain/zero/1.0/') == 'Creative Commons 0')
  check('license short', Source.license_short('Attribution NonCommercial 4.0') == 'CC BY-NC 4.0'
    and Source.license_short('Attribution 3.0') == 'CC BY 3.0' and Source.license_short('Creative Commons 0') == 'CC0'
    and Source.license_short('Sampling+') == 'Sampling+')
  check('noncommercial', Source.noncommercial('Attribution NonCommercial 4.0') and not Source.noncommercial('Attribution 4.0'))
  -- a Freesound sound instance (as the API returns it) -> source
  local fixture = Json.decode([[{"id": 12345, "url": "https://freesound.org/people/fieldrec/sounds/12345/",
    "name": "harbour wind.wav", "tags": ["wind", "harbour", "field-recording"],
    "description": "Wind at the <a href=\"x\">harbour</a>.<br />Zoom H5 &amp; windjammer.",
    "geotag": "60.15 24.95", "created": "2024-03-01T10:20:30", "license": "http://creativecommons.org/licenses/by/4.0/",
    "type": "wav", "channels": 2, "filesize": 5292044, "bitrate": 0, "bitdepth": 16, "duration": 30.0,
    "samplerate": 44100, "username": "fieldrec", "pack": null, "md5": "abc123",
    "previews": {"preview-hq-ogg": "https://cdn.freesound.org/previews/12/12345_1-hq.ogg"}}]])
  local src = Source.from_freesound(fixture, 'preview-hq-ogg', 1700000000, Json.null)
  check('fs source', src.kind == 'freesound' and src.author == 'fieldrec' and src.license == 'Attribution 4.0'
    and src.freesound.id == 12345 and src.freesound.pack == nil and src.freesound.original.samplerate == 44100
    and #src.freesound.tags == 3)
  check('fs description plain', src.freesound.description == 'Wind at the harbour.\nZoom H5 & windjammer.',
    src.freesound.description)
  check('credit', Source.credit(src) == '"harbour wind.wav" by fieldrec (https://freesound.org/s/12345/), Attribution 4.0',
    Source.credit(src))
  check('credit url', Source.credit({ kind = 'url', url = 'https://x/y.wav' }) == 'https://x/y.wav, license unknown',
    Source.credit({ kind = 'url', url = 'https://x/y.wav' }))
  check('title', Source.title('wind.WAV') == 'wind' and Source.title('Dr. Smith') == 'Dr. Smith' and Source.title('v1.2') == 'v1.2')
  check('stem', Source.freesound_stem(src.freesound) == '12345-fieldrec-harbour_wind', Source.freesound_stem(src.freesound))
  local side = Source.sidecar(src)
  check('sidecar', side:find('^"harbour wind.wav" by fieldrec') and side:find('freesound file: preview-hq-ogg', 1, true)
    and side:find('tags: wind harbour field-recording', 1, true) and side:find('original: wav, 44100 Hz, 2 ch', 1, true))
  local label, note, ftags = Source.first_note(src)
  check('first note', label == 'harbour wind.wav' and note:find('^Wind at the harbour') and not note:find('tags:', 1, true)
    and table.concat(ftags, ',') == table.concat(src.freesound.tags, ',') and ftags ~= src.freesound.tags
    and note:find('Attribution 4.0', 1, true))
  -- validate keeps the source, drops a bad one
  local sd = Model.new('/x/fs.flac', 30, 1)
  sd.tape.source = src
  local vd = Model.validate(load('return ' .. Store.serialise_value(sd))())
  check('validate source', vd.tape.source and vd.tape.source.freesound.id == 12345
    and vd.tape.source.freesound.tags[2] == 'harbour' and vd.tape.source.author == 'fieldrec')
  sd.tape.source = { kind = 'freesound', freesound = { id = 'x' } }
  check('validate bad source', Model.validate(sd).tape.source == nil)
  sd.tape.source = nil
  Model.set_source(sd, 'author', 'someone')
  check('set_source', sd.tape.source.kind == 'url' and sd.tape.source.author == 'someone')
  -- export credits it
  sd.tape.source = Source.clean(src)
  local smd = Export.markdown(sd, { now = 0 })
  check('md source', smd:find('- source: "harbour wind.wav" by fieldrec (https://freesound.org/s/12345/), Attribution 4.0',
    1, true) and smd:find("Freesound's preview-hq-ogg, not the original", 1, true))
  -- the collection carries author and license
  local ce = Collection.from_doc(sd)
  check('collection author', ce.author == 'fieldrec' and ce.license == 'Attribution 4.0')
  -- Freesound credentials and tokens
  local FS = include 'lib/freesound'
  FS.init(dir, Store)
  check('fs no key', FS.state(0) == 'no key')
  FS.set('api_key', 'KEY')
  FS.set('client_id', 'CID')
  check('fs key only', FS.state(0) == 'key only' and FS.can_login())
  local mode = io.popen("stat -c %a '" .. FS.path() .. "'"):read('l')
  check('fs file private', mode == '600', mode)
  local rnd = function(n) return ('\1'):rep(n) end
  local url = FS.login_start(1000, rnd)
  check('fs authorize url', url and url:find('client_id=CID', 1, true) and url:find('code_challenge_method=S256', 1, true)
    and url:find('code_challenge=' .. Pkce.challenge(Pkce.verifier(('\1'):rep(32))), 1, true), url)
  check('fs pending', FS.state(1000 + 599) == 'waiting for code' and FS.state(1000 + 601) == 'key only')
  check('fs login file', io.open(FS.login_path()) ~= nil)
  check('fs clean code', FS.clean_code(' abc ') == 'abc'
    and FS.clean_code('https://freesound.org/x/?code=XyZ&state=1') == 'XyZ')
  local conf = FS.curl_config({ url = 'https://a/b', headers = { 'Authorization: Token K"\\' }, data = { { 'code', 'a b' } } })
  check('fs curl config', conf == 'url = "https://a/b"\nheader = "Authorization: Token K\\"\\\\"\ndata-urlencode = "code=a b"\n',
    conf)
  check('fs bad token', not FS.take_token({ error = 'invalid_grant' }, 1000))
  check('fs take token', FS.take_token({ access_token = 'A1', refresh_token = 'R1', expires_in = 86400 }, 1000)
    and FS.state(1000) == 'logged in' and FS.cfg.pending == nil and io.open(FS.login_path()) == nil)
  check('fs token valid', FS.token_valid(FS.cfg, 1000 + 86000) and not FS.needs_refresh(FS.cfg, 1000 + 86000))
  check('fs needs refresh', FS.needs_refresh(FS.cfg, 1000 + 86400))
  FS.take_token({ access_token = 'A2', refresh_token = 'R2', expires_in = 86400 }, 90000)
  FS.load()
  check('fs refresh saved', FS.cfg.refresh_token == 'R2' and FS.cfg.access_token == 'A2')
  local rr = FS.refresh_request()
  check('fs refresh request', rr.data[3][2] == 'refresh_token' and rr.data[4][2] == 'R2' and rr.data[2][2] == 'KEY')
  FS.set('api_key', 'KEY')
  check('fs same key keeps login', FS.logged_in())
  FS.clear_tokens()
  check('fs cleared', FS.state(0) == 'key only')

  -- arranger (lib/arrange.lua): sequencer, editing, validation
  do
    local Arr = include 'lib/arrange'
    local ad = Model.new('/x/arr.wav', 100, 1)
    local ma = Model.add_mark(ad, 10)   -- m1: 10 -> 12 (next region start)
    local ra = Model.add_region(ad, 12, 14) -- r2
    local mb = Model.add_mark(ad, 20)   -- m3: 20 -> 30 (next mark)
    local mc = Model.add_mark(ad, 30)   -- m4: 30 -> 100 (the end)
    local function run(rows, from, max)
      local s = Arr.start(rows, ad, from or 1)
      local out = {}
      for _ = 1, max or 50 do
        local sp = Arr.step(s)
        if not sp then break end
        out[#out + 1] = string.format('%g-%g@%g', sp.a, sp.b, sp.rate)
      end
      return table.concat(out, ' '), s
    end
    check('arr mark span', select(2, Arr.item_span(ad, ma)) == 12 and select(2, Arr.item_span(ad, mb)) == 30
      and select(2, Arr.item_span(ad, mc)) == 100)
    local r = run({ { k = 'play', id = 'r2', rep = 2, rate = 1 }, { k = 'play', id = 'm3', rep = 1, rate = -2 } })
    check('arr rep + rate', r == '12-14@1 12-14@1 20-30@-2', r)
    r = run({ { k = 'play', id = 'r2', rep = 1, rate = 1 }, { k = 'halt' }, { k = 'play', id = 'm1', rep = 1, rate = 1 } })
    check('arr halt', r == '12-14@1', r)
    r = run({ { k = 'play', id = 'r2', rep = 1, rate = 1 }, { k = 'play', id = 'm1', rep = 1, rate = 1 } }, 2)
    check('arr from row', r == '10-12@1', r)
    -- loop: rows 0-1 three times in all, then row 3
    r = run({ { k = 'play', id = 'm1', rep = 1, rate = 1 }, { k = 'play', id = 'r2', rep = 1, rate = 1 },
      { k = 'loop', to = 0, n = 3 }, { k = 'play', id = 'm3', rep = 1, rate = 1 } })
    check('arr loop n', r == '10-12@1 12-14@1 10-12@1 12-14@1 10-12@1 12-14@1 20-30@1', r)
    -- nested: inner (row 1) x2 inside outer (rows 0-2) x2: A B B A B B C
    r = run({ { k = 'play', id = 'm1', rep = 1, rate = 1 }, { k = 'play', id = 'r2', rep = 1, rate = 1 },
      { k = 'loop', to = 1, n = 2 }, { k = 'loop', to = 0, n = 2 }, { k = 'play', id = 'm3', rep = 1, rate = 1 } })
    check('arr nested loops', r == '10-12@1 12-14@1 12-14@1 10-12@1 12-14@1 12-14@1 20-30@1', r)
    -- forever
    r = run({ { k = 'play', id = 'r2', rep = 1, rate = 1 }, { k = 'loop', to = 0, n = 0 } }, 1, 5)
    check('arr loop forever', r == '12-14@1 12-14@1 12-14@1 12-14@1 12-14@1', r)
    r = run({ { k = 'jump', to = 2 }, { k = 'play', id = 'm1', rep = 1, rate = 1 }, { k = 'rem', text = 'x' },
      { k = 'play', id = 'r2', rep = 1, rate = 1 } })
    check('arr jump + rem', r == '12-14@1', r)
    -- STOP and WAIT: timed spans; a loop of only a WAIT is not a zero-time loop
    local function run2(rws, max)
      local st2 = Arr.start(rws, ad, 1)
      local out = {}
      for _ = 1, max or 50 do
        local sp = Arr.step(st2)
        if not sp then break end
        out[#out + 1] = sp.kind and (sp.kind .. sp.secs) or string.format('%g-%g@%g', sp.a, sp.b, sp.rate)
      end
      return table.concat(out, ' '), st2
    end
    r = run2({ { k = 'play', id = 'r2', rep = 1, rate = 1 }, { k = 'stop', secs = 0.5 }, { k = 'wait', secs = 2 },
      { k = 'play', id = 'm1', rep = 1, rate = 1 } })
    check('arr stop + wait', r == '12-14@1 stop0.5 wait2 10-12@1', r)
    r = run2({ { k = 'wait', secs = 1 }, { k = 'loop', to = 0, n = 0 } }, 3)
    check('arr wait loop', r == 'wait1 wait1 wait1', r)
    -- a deleted item is skipped
    r = run({ { k = 'play', id = 'r99', rep = 1, rate = 1 }, { k = 'play', id = 'm3', rep = 1, rate = 1 } })
    check('arr missing item', r == '20-30@1', r)
    -- zero-time guard: a jump to itself, an empty loop
    local s2
    r, s2 = run({ { k = 'jump', to = 0 } })
    check('arr guard jump', r == '' and s2.err == 'NO PLAY ROW', s2.err)
    r, s2 = run({ { k = 'rem', text = '' }, { k = 'loop', to = 0, n = 0 } })
    check('arr guard loop', r == '' and s2.err == 'NO PLAY ROW', s2.err)
    r, s2 = run({ { k = 'play', id = 'r99', rep = 1, rate = 1 }, { k = 'loop', to = 0, n = 0 } })
    check('arr guard missing', r == '' and s2.err == 'NO PLAY ROW', s2.err)
    -- short spans are lengthened to MIN_SPAN of playing time
    local tiny = Model.add_region(ad, 50, 50.06)
    r = run({ { k = 'play', id = tiny.id, rep = 1, rate = 4 } })
    check('arr min span', r == '50-50.2@4', r)
    -- editing: targets follow their rows
    local rows = Model.arr_rows(ad)
    Model.arr_insert(ad, 1, Arr.new_row(rows, 1, 'play', 'm1'))
    Model.arr_insert(ad, 2, Arr.new_row(rows, 2, 'play', 'r2'))
    Model.arr_insert(ad, 3, Arr.new_row(rows, 3, 'loop'))
    check('arr loop default to', rows[3].to == 0)
    Model.arr_insert(ad, 4, Arr.new_row(rows, 4, 'play', 'm3'))
    Model.arr_insert(ad, 5, Arr.new_row(rows, 5, 'loop'))
    check('arr loop default after loop', rows[5].to == 3, rows[5].to)
    Model.arr_insert(ad, 1, Arr.new_row(rows, 1, 'rem'))
    check('arr insert shifts', rows[4].to == 1 and rows[6].to == 4, rows[4].to .. ' ' .. rows[6].to)
    Model.arr_delete(ad, 1)
    check('arr delete shifts', rows[3].to == 0 and rows[5].to == 3)
    local s3 = Arr.start(rows, ad, 1)
    Arr.step(s3) -- row 1 played, next is row 2
    Arr.shift(s3, 1, 1)
    check('arr shift', s3.row == 3 and s3.cur == 2, s3.row .. ' ' .. tostring(s3.cur))
    Model.arr_set(ad, 2, 'rate', -0.5)
    Model.remove(ad, ra) -- the row stays, pointing at nothing
    check('arr row survives delete', rows[2].id == 'r2')
    -- validation: a round trip, malformed rows dropped, values clamped
    local copy = Model.validate({ version = 1, tape = { path = '/x/arr.wav', dur = 100 }, next_id = 9,
      marks = { { id = 'm1', t = 10, tags = {} } }, regions = {},
      arr = { rows = { { k = 'play', id = 'r2', rep = 999, rate = -0.6 }, { k = 'loop', to = 40, n = -3 },
        { k = 'bogus' }, 'x', { k = 'play', id = 7 }, { k = 'rem', text = 'hi' }, { k = 'jump', to = 1.4 },
        { k = 'halt' }, { k = 'stop', secs = 0.6 }, { k = 'wait' } } } })
    local cr = copy.arr.rows
    check('arr validate stop/wait', cr[6].secs == 0.5 and cr[7].k == 'wait' and cr[7].secs == 1)
    check('arr validate', #cr == 7 and cr[1].rep == 64 and cr[1].rate == -0.5 and cr[2].to == 6 and cr[2].n == 0
      and cr[3].text == 'hi' and cr[4].to == 1 and cr[5].k == 'halt', #cr)
    check('arr no arr', Model.validate({ version = 1, marks = {}, regions = {} }).arr == nil)
    -- through the store
    local p2 = '/x/arr store.wav'
    local sd = Store.open(p2, 100, 5)
    Model.add_mark(sd, 1)
    Model.arr_insert(sd, 1, Arr.new_row(Model.arr_rows(sd), 1, 'play', 'm1'))
    Model.arr_insert(sd, 2, { k = 'rem', text = 'a "quoted"\nremark' })
    Store.flush()
    Store.close()
    local back = Store.open(p2, 100, 5)
    check('arr store round trip', back.arr and #back.arr.rows == 2 and back.arr.rows[2].text == 'a "quoted"\nremark')
    Store.close()
  end

  print(string.format('model_test: %d passed, %d failed', passes, fails))
  if fails == 0 then rm_rf(dir) end
  return fails
end

if not on_norns then
  os.exit(T.run() == 0 and 0 or 1)
end
return T

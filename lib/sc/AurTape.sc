// AurTape: a long sound file played through a RAM ring window.
//
// The file is read in chunks of `chunkSecs` into a ring buffer of `slots`
// chunks. The voice plays the ring with PlayBuf (double-precision phase, any
// rate) and keeps a parallel Phasor in file frames for bookkeeping. A small
// `valid` buffer holds, per slot, the file chunk it contains (-1 = none); the
// voice mutes itself when the chunk under the playhead is not in its slot.
// sclang keeps the chunks along the path of travel loaded (it follows the
// loop when the playhead is inside one), one read in flight at a time.
//
// Transport, all inside the synth so it is sample-accurate and click-free:
// - rate glide (spin up / spin down), any rate in -64..64;
// - jog: nudges push the tape and friction slows it down (MultiTape model);
// - jumps: fade out, jump in a short hold of silence, fade in (`fade` each way);
// - loop: fade out before the seam, wrap, fade in after it. A loop is only
//   entered by crossing its edge, so a seek past the loop escapes it.
//
// Proxies (phase 2): decimated mono copies of the file held whole in RAM,
// P1 (rate / 8) and P2 (rate / 64), played in sync with the ring. They are
// the cue sound at speed (at 8x, P1 has the real 8x spectrum, without the
// aliasing of the full-resolution file) and cover a playhead that reaches a
// chunk that isn't loaded: the tape plays muffled, then comes into focus when
// the chunk arrives. sclang loads them in pieces between ring reads, so
// loading never starves the ring. Above the speed where a proxy takes over,
// the ring stops streaming.
// Cue: above 2x the output goes through the lifter (head contact): quieter,
// band-limited and slightly driven as the tape is lifted off the head.
//
// Frame positions are float32 on the server. Every position the server is
// given is a multiple of `quant` frames, so it is exact up to 2^30 frames
// (6.2 h at 48 kHz) and the ring offset computed here matches it.

AurTape {
	classvar <chunkSecs = 4, <quant = 64, <decim = #[8, 64], <pieceFrames = 524288;

	var <server, <target, <outBus, <ringSecs, <id;
	var <path, <numFrames = 0, <fileChannels = 2, <fileRate = 48000;
	var <ring, <valid, <synth, <slots, <chunkFrames, <ringFrames, <numChunks = 0;
	var slotChunk, inflight, loading = false, holdChunk, holdUntil = 0;
	var <pos = 0, <actualRate = 0, <targetRate = 0, <ok = 0, <jogging = false;
	var <loopOn = false, <loopStart = 0, <loopEnd = 0, loopReq;
	var queued;
	var <amp = 1, <jogStop = 0.5, <fade = 0.008, parked = false, nudgeTotal = 0;
	var <lifter = 0.5, <focus = 0.15, <proxyShare = 0;
	var <proxies, proxyReqs, pinflight;
	var posFunc, okFunc, doneFunc, failFunc, jgFunc;
	var <st, jumpTime, phaseName = "start", phaseStart;
	var <>reportPath;

	*new { |server, target, outBus = 0, ringSecs = 64, id = 0|
		^super.newCopyArgs(server, target, outBus, ringSecs, id).prInit
	}

	*addDefs {
		SynthDef(\aurTape, { |out = 0, ring = 0, valid = 0, chunkFrames = 192000, slots = 16,
			fileFrames = 1, rateScale = 1, rate = 0, rateLag = 0.1, amp = 1, fade = 0.008,
			t_jump = 0, jumpFile = 0, jumpRing = 0, id = 0,
			jog = 0, nudgeSum = 0, t_jogZero = 0, jogStop = 0.5,
			loopOn = 0, loopStart = 0, loopEnd = 1, loopStartRing = 0, loopBackFile = 0, loopBackRing = 0,
			p1buf = 0, p2buf = 0, hasP1 = 0, hasP2 = 0, p1Ratio = 0.125, p2Ratio = 0.015625,
			p1Nyq = 2700, p2Nyq = 337, lifter = 0.5, focus = 0.15, maxRate = 64|
			// previous blocks: [kpos(n-1), kpos(n-2), jumped(n-1)]
			var fb = LocalIn.kr(3);
			var lp = fb[0], lpp = fb[1], jumpedPrev = fb[2];
			// jog: an integrator with friction; t_jogZero resets it to the nudge.
			// nudges arrive as a running total, so several in one block add up
			var nudge = nudgeSum - Delay1.kr(nudgeSum);
			var jogRate = Integrator.kr(nudge, exp(ControlDur.ir.neg / jogStop) * (1 - t_jogZero)).clip(-64, 64);
			var sp, up, u1, u2, wFull, f, gap, w1, w2, p1, p2, full, prox, inFile, mix, cue, cueAmt, contact, drive;
			// lag time 0 while jogging, so leaving jog glides from the jog rate
			var ru = Lag.kr(Select.kr(jog, [rate, jogRate]), rateLag * (1 - jog)).clip(maxRate.neg, maxRate);
			var r = ru * rateScale;
			var speed = r.abs * SampleRate.ir; // file frames per second
			// user jump: fade out, hold silence, fade in; the jump lands in the
			// middle of the hold
			var hold = ControlDur.ir * 4;
			var jumpGain = EnvGen.kr(Env([1, 0, 0, 1], [fade, hold, fade]), t_jump);
			var userJump = TDelay.kr(t_jump, fade + (hold * 0.5));
			// loop wrap when the previous block crossed an edge in the direction of travel
			var notJumped = 1 - jumpedPrev;
			var fwdWrap = loopOn * (r > 0) * (lpp < loopEnd) * (lp >= loopEnd) * notJumped;
			var revWrap = loopOn * (r < 0) * (lpp >= loopStart) * (lp < loopStart) * notJumped;
			var trig = (userJump + fwdWrap + revWrap) > 0;
			var isUser = userJump > 0;
			var resetFile = Select.kr(isUser, [Select.kr(fwdWrap, [loopBackFile, loopStart]), jumpFile]);
			var resetRing = Select.kr(isUser, [Select.kr(fwdWrap, [loopBackRing, loopStartRing]), jumpRing]);
			var sig = PlayBuf.ar(2, ring, r, trig, resetRing, loop: 1);
			// proxies follow the file position (not the ring), reset by the same triggers
			var p1raw = PlayBuf.ar(1, p1buf, r * p1Ratio, trig, resetFile * p1Ratio, loop: 1);
			var p2raw = PlayBuf.ar(1, p2buf, r * p2Ratio, trig, resetFile * p2Ratio, loop: 1);
			// wide range so it never wraps; the edges of the file are muted below
			var filePos = Phasor.ar(trig, r, -1e9, 1e10, resetFile);
			var kpos = A2K.kr(filePos);
			// fade out before a loop seam, stay silent past it until the wrap
			var fadeF = (fade * speed).max(1);
			var over = fadeF + (ControlDur.ir * 4 * speed);
			var dEnd = loopEnd - kpos, dStart = kpos - loopStart;
			var gEnd = 1 - (loopOn * (r > 0) * (dEnd < fadeF) * (dEnd > over.neg) * (1 - (dEnd / fadeF).clip(0, 1)));
			var gStart = 1 - (loopOn * (r < 0) * (dStart < fadeF) * (dStart > over.neg) * (1 - (dStart / fadeF).clip(0, 1)));
			// fade in after a loop wrap (Sweep restarts from 0 on every trigger)
			var wrapUp = Sweep.kr((fwdWrap + revWrap) > 0, 1 / fade).min(1);
			var gain = gEnd * gStart * jumpGain * wrapUp;
			var chunk = (kpos / chunkFrames).floor;
			var held = BufRd.kr(1, valid, chunk % slots, 0, 1);
			// (`==` on UGens is object identity in sclang, hence the explicit op)
			var okk = (held >= 0) * BinaryOpUGen('==', held, chunk) * (kpos >= 0) * (kpos < fileFrames);
			LocalOut.kr([kpos, lp, trig]);
			// which source plays: by speed, a proxy takes over over one octave
			// around its decimation factor (|rate| >= decimation)
			sp = ru.abs;
			up = { |thr| ((sp.max(0.001) / thr).log2 + 0.5).clip(0, 1) };
			u1 = up.(8) * hasP1;
			u2 = up.(64) * hasP2;
			wFull = (1 - u1) * (1 - u2);
			// full resolution when its chunk is there: drops out in 4 ms, comes
			// back over `focus` (a linear crossfade from the proxy) when one covers
			f = Slew.kr(okk, 1 / Select.kr((hasP1 + hasP2) > 0, [0.004, focus]), 250);
			// what the full resolution can't play goes to the best proxy
			gap = wFull * (1 - f);
			w1 = (u1 * (1 - u2)) + (gap * hasP1);
			w2 = u2 + (gap * (1 - hasP1) * hasP2);
			// the proxies are band-limited; filter the interpolation images
			p1 = LPF.ar(p1raw, (p1Nyq * sp).clip(20, 20000));
			p2 = LPF.ar(p2raw, (p2Nyq * sp).clip(20, 20000));
			inFile = Lag.kr((kpos >= 0) * (kpos < fileFrames), 0.004);
			prox = ((p1 * w1) + (p2 * w2)) * inFile;
			mix = (sig * K2A.ar(wFull * f)) + [prox, prox];
			// cue: the lifter lifts the tape off the head above 2x (fully at 4x)
			cueAmt = ((sp - 2) / 2).clip(0, 1);
			contact = 1 - Lag.kr(lifter, 0.1);
			drive = 1 + ((1 - contact) * 3);
			cue = HPF.ar(LPF.ar(mix, 800 + (contact.squared * 15000)), 40 + ((1 - contact) * 400));
			cue = (cue * drive).tanh / drive * contact;
			mix = XFade2.ar(mix, cue, cueAmt * 2 - 1);
			SendReply.kr(Impulse.kr(25), '/aur/pos', [kpos, ru, w1 + w2], id);
			SendReply.kr(Changed.kr(okk), '/aur/ok', [okk, kpos, ru], id);
			// gain when a jump or wrap lands (the previous block's, which K2A
			// starts the jump block from): should be 0 (jump_gain in the report)
			SendReply.kr(trig, '/aur/jg', [Delay1.kr(gain)], id);
			Out.ar(out, mix * K2A.ar(gain) * Lag.kr(amp, 0.05));
		}).add;
	}

	prInit {
		reportPath = "~/dust/data/aurotate/transport_report.txt".standardizePath;
		this.resetStats;
		posFunc = OSCFunc({ |msg|
			if(this.prMine(msg)) {
				// until a jump has happened, reports still carry the old position
				if(Main.elapsedTime >= holdUntil) { pos = msg[3] };
				actualRate = msg[4];
				proxyShare = msg[5];
				this.prSampleCpu;
				this.prEdges;
				this.service;
			}
		}, '/aur/pos');
		okFunc = OSCFunc({ |msg| if(this.prMine(msg)) { this.prOk(msg[3], msg[4], msg[5]) } }, '/aur/ok');
		jgFunc = OSCFunc({ |msg|
			if(this.prMine(msg)) { st.jumpGain = max(st.jumpGain, msg[3]) }
		}, '/aur/jg');
		proxies = [nil, nil];
		proxyReqs = [nil, nil];
		doneFunc = OSCFunc({ |msg|
			if(msg[1] == '/b_readChannel' and: { ring.notNil and: { msg[2] == ring.bufnum } }) {
				this.prReadDone(true)
			};
			if(msg[1] == '/b_read' and: { pinflight.notNil and: { msg[2] == pinflight.buf.bufnum } }) {
				this.prPieceDone(true)
			}
		}, '/done');
		failFunc = OSCFunc({ |msg|
			if(msg[1] == '/b_readChannel' and: { inflight.notNil }) {
				("AurTape: read failed " ++ msg).postln; this.prReadDone(false)
			};
			if(msg[1] == '/b_read' and: { pinflight.notNil }) {
				("AurTape: proxy read failed " ++ msg).postln; this.prPieceDone(false)
			};
			if(msg[1] == '/b_alloc') {
				proxies.do { |p, i|
					if(p.notNil and: { p.buf.bufnum == msg[3] }) {
						("AurTape: no memory for proxy P" ++ (i + 1)).postln;
						this.prDropProxy(i)
					}
				}
			}
		}, '/fail');
	}

	prMine { |msg| ^synth.notNil and: { msg[1] == synth.nodeID } and: { msg[2] == id } }

	resetStats {
		st = (reads: 0, readSum: 0, readMax: 0, misses: 0,
			seeks: 0, seekSum: 0, seekMax: 0, seekN: 0, bytes: 0,
			cpuSum: 0, cpuN: 0, cpuPeak: 0, jumpGain: 0, covers: 0, proxyMax: 0);
		phaseStart = Main.elapsedTime;
	}

	prSampleCpu {
		st.cpuSum = st.cpuSum + server.avgCPU;
		st.cpuN = st.cpuN + 1;
		st.cpuPeak = max(st.cpuPeak, server.peakCPU);
		st.proxyMax = max(st.proxyMax, proxyShare);
	}

	q { |frame| ^(frame / quant).round * quant }

	// open a file; requests made while one is loading are queued (last wins)
	open { |argPath, startSecs = 0|
		// a new tape starts stopped; rate commands sent while it loads still count
		targetRate = 0; jogging = false;
		this.prOpen(argPath, startSecs);
	}

	prOpen { |argPath, startSecs|
		if(loading) { queued = [argPath, startSecs]; ^this };
		loading = true;
		fork {
			this.load(argPath, startSecs);
			loading = false;
			if(queued.notNil) { var q = queued; queued = nil; this.prOpen(*q) };
		}
	}

	// call from a Routine; use `open` otherwise
	load { |argPath, startSecs = 0|
		var startFrame, sf = SoundFile.openRead(argPath.standardizePath);
		if(sf.isNil) { ("AurTape: can't open " ++ argPath).postln; ^false };
		if(sf.path != path) { 2.do { |i| this.prDropProxy(i) } };
		path = sf.path; numFrames = sf.numFrames; fileChannels = sf.numChannels; fileRate = sf.sampleRate;
		sf.close;
		startFrame = (startSecs * fileRate).clip(0, numFrames - 1);
		this.prFreeServer;
		server.sync;
		chunkFrames = (chunkSecs * fileRate).round.asInteger;
		slots = (ringSecs / chunkSecs).ceil.asInteger.max(4);
		ringFrames = chunkFrames * slots;
		this.prLoopFrames;
		numChunks = (numFrames / chunkFrames).ceil.asInteger;
		slotChunk = Array.fill(slots, -1);
		inflight = nil;
		ring = Buffer.alloc(server, ringFrames, 2);
		valid = Buffer.alloc(server, slots, 1);
		server.sync;
		valid.fill(0, slots, -1);
		server.sync;
		synth = Synth(\aurTape, [
			\out, outBus, \ring, ring, \valid, valid, \chunkFrames, chunkFrames,
			\slots, slots, \fileFrames, numFrames, \id, id,
			\rateScale, fileRate / (server.sampleRate ? 48000),
			\rate, targetRate, \amp, amp, \jogStop, jogStop, \fade, fade, \lifter, lifter, \focus, focus
		] ++ this.prLoopArgs ++ this.prProxyArgs, target);
		pos = startFrame; actualRate = 0; parked = false; nudgeTotal = 0;
		("AurTape: % (% s, % ch, % Hz), ring % s in % slots"
			.format(path, (numFrames / fileRate).round(0.1), fileChannels, fileRate, ringSecs, slots)).postln;
		this.jump(startFrame);
		2.do { |i| this.prApplyProxy(i) };
		^true
	}

	// change the ring size; reopens the current file at the current position
	setRing { |secs, reopen = true|
		if(secs == ringSecs) { ^this };
		ringSecs = secs;
		if(reopen and: { path.notNil }) { jogging = false; this.prOpen(path, pos / fileRate) }
	}

	duration { ^numFrames / fileRate }
	posSecs { ^pos / fileRate }

	maxRate { ^if(this.hasProxy(1)) { 256 } { 64 } }

	setRate { |r, lag = 0.1|
		targetRate = r.clip(this.maxRate.neg, this.maxRate);
		parked = false;
		if(jogging) {
			jogging = false;
			synth !? { synth.set(\rate, targetRate, \rateLag, lag, \jog, 0) };
		} {
			synth !? { synth.set(\rate, targetRate, \rateLag, lag) };
		}
	}

	setAmp { |a| amp = a; synth !? { synth.set(\amp, a) } }
	setFade { |s| fade = s.clip(0.001, 0.1); synth !? { synth.set(\fade, fade) } }
	setJogStop { |s| jogStop = s.clip(0.02, 5); synth !? { synth.set(\jogStop, jogStop) } }
	setLifter { |x| lifter = x.clip(0, 1); synth !? { synth.set(\lifter, lifter) } }
	setFocus { |s| focus = s.clip(0.004, 2); synth !? { synth.set(\focus, focus) } }

	// push the tape. The first push enters jog mode: the tape keeps its
	// current speed
	nudge { |dv|
		parked = false;
		if(jogging.not) {
			jogging = true;
			targetRate = 0;
			nudgeTotal = nudgeTotal + actualRate + dv;
			synth !? { synth.set(\jog, 1, \nudgeSum, nudgeTotal, \t_jogZero, 1) };
		} {
			nudgeTotal = nudgeTotal + dv;
			synth !? { synth.set(\nudgeSum, nudgeTotal) };
		}
	}

	// kept in seconds, so it survives (and is re-clamped by) opening a file
	setLoop { |on, startSecs, endSecs|
		loopReq = [on.asBoolean, startSecs, endSecs];
		this.prLoopFrames;
		synth !? { synth.set(*this.prLoopArgs) };
		this.service;
	}

	prLoopFrames {
		var on, s, e;
		if(loopReq.isNil or: { numFrames <= 0 }) { loopOn = false; ^this };
		#on, s, e = loopReq;
		s = this.q(s * fileRate).max(0);
		e = this.q(e * fileRate).min(this.q(numFrames));
		loopOn = on and: { e - s >= (quant * 4) };
		loopStart = s; loopEnd = e;
	}

	prLoopArgs {
		var rf = ringFrames ? 1;
		var back = (loopEnd - quant).max(loopStart);
		^[\loopOn, loopOn.binaryValue, \loopStart, loopStart, \loopEnd, loopEnd,
			\loopStartRing, loopStart % rf, \loopBackFile, back, \loopBackRing, back % rf]
	}

	jumpSecs { |s| this.jump(s * fileRate) }

	jump { |frame|
		if(synth.isNil) { ^this };
		frame = this.q(frame.clip(0, numFrames - 1));
		// the synth plays the old position during the fade-out: keep its chunk
		holdChunk = (pos / chunkFrames).floor.asInteger;
		holdUntil = Main.elapsedTime + fade + 0.1;
		pos = frame;
		parked = false;
		st.seeks = st.seeks + 1;
		if(this.prResident(frame) or: { this.prStream.not }) {
			// the playhead won't go silent: the seek takes the fade time
			jumpTime = nil;
			st.seekN = st.seekN + 1;
			st.seekSum = st.seekSum + fade;
			st.seekMax = max(st.seekMax, fade);
		} {
			jumpTime = Main.elapsedTime;
		};
		synth.set(\jumpFile, frame, \jumpRing, frame % ringFrames, \t_jump, 1);
		this.service;
	}

	prResident { |frame|
		var w = (frame / chunkFrames).floor.asInteger;
		^slotChunk.notNil and: { slotChunk[w % slots] == w }
	}

	// the chunk after `w` along the path of travel
	prNext { |w, dir, inLoop, ls, le|
		if(inLoop) {
			if(dir > 0 and: { w >= le }) { ^ls };
			if(dir < 0 and: { w <= ls }) { ^le };
		};
		^w + dir
	}

	// the speed above which a proxy replaces the full resolution
	prFullLimit {
		if(this.hasProxy(0)) { ^8 * 2.sqrt };
		if(this.hasProxy(1)) { ^64 * 2.sqrt };
		^inf
	}

	// stream the ring unless a proxy plays at both the current and target speed
	prStream { ^jogging or: { min(actualRate.abs, targetRate.abs) < this.prFullLimit } }

	service {
		if(numChunks <= 0 or: { inflight.notNil } or: { pinflight.notNil } or: { synth.isNil }) { ^this };
		if(this.prStream and: { this.prServiceRing }) { ^this };
		this.prProxyPiece;
	}

	// returns true when a read was started
	prServiceRing {
		var c, dir, ahead, behind, order, claimed, ls, le, inLoop, w;
		c = (pos / chunkFrames).floor.asInteger;
		dir = if((actualRate ? 0) < 0 or: { targetRate < 0 }) { -1 } { 1 };
		ahead = (slots * 0.75).floor.asInteger.max(1);
		behind = slots - 1 - ahead;
		ls = (loopStart / chunkFrames).floor.asInteger;
		le = ((loopEnd - 1).max(0) / chunkFrames).floor.asInteger;
		inLoop = loopOn and: { pos >= loopStart } and: { pos < loopEnd };
		order = List[c];
		w = c;
		ahead.do { w = this.prNext(w, dir, inLoop, ls, le); order.add(w) };
		w = c;
		behind.do { w = this.prNext(w, dir.neg, inLoop, ls, le); order.add(w) };
		claimed = Array.newClear(slots);
		if(holdChunk.notNil and: { Main.elapsedTime < holdUntil }) {
			claimed[holdChunk % slots] = holdChunk
		};
		order.do { |w|
			var slot;
			if(w >= 0 and: { w < numChunks }) {
				slot = w % slots;
				if(claimed[slot].isNil) {
					claimed[slot] = w;
					if(slotChunk[slot] != w) { this.prRead(this.prPair(w, c, dir, claimed)); ^true };
				}
			}
		};
		^false
	}

	// After a seek just before a chunk boundary, the next chunk would arrive
	// too late if it were read separately: read both in one request.
	// Returns [first chunk, count].
	prPair { |w, c, dir, claimed|
		var off, near, w2, lo, speed;
		if(w != c) { ^[w, 1] };
		speed = max(1, max(actualRate.abs, targetRate.abs));
		off = pos - (c * chunkFrames);
		near = (if(dir > 0) { chunkFrames - off } { off }) < (chunkFrames * 0.25 * speed);
		w2 = c + dir;
		if(near.not or: { w2 < 0 } or: { w2 >= numChunks }) { ^[w, 1] };
		if(slotChunk[w2 % slots] == w2 or: { claimed[w2 % slots].notNil }) { ^[w, 1] };
		lo = min(c, w2);
		// the two slots must be adjacent in the ring
		if((lo % slots) == (slots - 1)) { ^[w, 1] };
		claimed[w2 % slots] = w2;
		^[lo, 2]
	}

	// read `count` consecutive chunks from `w` into adjacent slots
	prRead { |wc|
		var w = wc[0], count = wc[1];
		var slot = w % slots;
		var start = w * chunkFrames;
		var n = min(chunkFrames * count, numFrames - start);
		var chans = if(fileChannels == 1) { [0, 0] } { [0, 1] };
		var chunks = (w .. w + count - 1);
		var setValid = [\b_set, valid.bufnum] ++ chunks.collect { |c, i| [slot + i, c] }.flatten;
		chunks.do { |c, i| slotChunk[slot + i] = -2; server.sendMsg(\b_set, valid.bufnum, slot + i, -1) };
		inflight = (chunks: chunks, slot: slot, t: Main.elapsedTime, n: n);
		// the last chunk is partial: silence the rest of its slot (sample indices are interleaved)
		if(n < (chunkFrames * count)) {
			server.sendMsg(\b_fill, ring.bufnum, (slot * chunkFrames + n) * 2, (chunkFrames * count - n) * 2, 0)
		};
		server.listSendMsg([\b_readChannel, ring.bufnum, path, start, n, slot * chunkFrames, 0]
			++ chans ++ [setValid]);
	}

	prReadDone { |okRead|
		var dt;
		if(inflight.isNil) { ^this };
		dt = Main.elapsedTime - inflight.t;
		inflight.chunks.do { |c, i| slotChunk[inflight.slot + i] = if(okRead) { c } { -1 } };
		st.reads = st.reads + 1;
		st.readSum = st.readSum + dt;
		st.readMax = max(st.readMax, dt);
		st.bytes = st.bytes + (inflight.n * fileChannels * 2);
		inflight = nil;
		this.service;
	}

	prOk { |k, kpos, r|
		var dt;
		ok = k;
		if(k > 0) {
			if(jumpTime.notNil) {
				dt = Main.elapsedTime - jumpTime;
				st.seekN = st.seekN + 1;
				st.seekSum = st.seekSum + dt;
				st.seekMax = max(st.seekMax, dt);
				jumpTime = nil;
			}
		} {
			// a mute while moving that a jump didn't cause is a dropout
			if(jumpTime.isNil and: { r.abs > 0.001 } and: { r.abs < this.prFullLimit }
				and: { kpos > 0 } and: { kpos < (numFrames - 1) }) {
				var w = (kpos / chunkFrames).floor.asInteger;
				// a proxy covers it: heard as a short loss of focus
				if(this.hasProxy(0) or: { this.hasProxy(1) }) { st.covers = st.covers + 1; ^this };
				st.misses = st.misses + 1;
				"AurTape miss: kpos % (chunk %, slot % holds %) pos % rate % target % jog % inflight % loop % %-%"
				.format(kpos, w, w % slots, slotChunk[w % slots], pos, r.round(0.01), targetRate, jogging,
					inflight !? { |i| i.chunks }, loopOn, loopStart, loopEnd).postln;
			}
		}
	}

	// stop and park at the ends of the file
	prEdges {
		var moving = if(jogging) { actualRate } { targetRate };
		if(parked.not) {
			if(pos >= (numFrames - quant) and: { moving > 0 }) { this.prPark(numFrames - quant) };
			if(pos <= 0 and: { moving < 0 }) { this.prPark(0) };
		}
	}

	prPark { |frame|
		targetRate = 0;
		synth.set(\rate, 0, \rateLag, 0, \t_jogZero, 1);
		this.jump(frame);
		parked = true;
	}

	//// proxies

	hasProxy { |i| ^proxies[i].notNil and: { proxies[i].complete } }

	// level 1 (P1) or 2 (P2): `proxyPath` is the proxy of `tapePath` ("" drops
	// it). Ignored unless `tapePath` is (or is about to be) the open file
	setProxy { |level, tapePath, proxyPath|
		var i = level - 1;
		if(i < 0 or: { i > 1 }) { ^this };
		proxyReqs[i] = [tapePath.standardizePath, proxyPath.standardizePath];
		if(loading.not) { this.prApplyProxy(i) }
	}

	prApplyProxy { |i|
		var req = proxyReqs[i], cur = proxies[i], sf, buf;
		if(req.isNil or: { req[0] != path } or: { req[1].isEmpty }) { ^this.prDropProxy(i) };
		if(cur.notNil and: { cur.file == req[1] }) { ^this };
		this.prDropProxy(i);
		sf = SoundFile.openRead(req[1]);
		if(sf.isNil) { ("AurTape: can't open proxy " ++ req[1]).postln; ^this };
		sf.close;
		if(sf.numChannels != 1) { ("AurTape: proxy must be mono: " ++ req[1]).postln; ^this };
		buf = Buffer.alloc(server, sf.numFrames.max(1), 1);
		// (keys that aren't Object methods: `next`, `rate`, `path` would be)
		proxies[i] = (file: req[1], buf: buf, nFrames: sf.numFrames, sr: sf.sampleRate,
			loadedTo: 0, complete: false, t0: Main.elapsedTime);
		this.service;
	}

	prDropProxy { |i|
		var p = proxies[i];
		if(p.isNil) { ^this };
		proxies[i] = nil;
		if(pinflight.notNil and: { pinflight === p }) { pinflight = nil };
		synth !? { synth.set(*this.prProxyArgs) };
		// let the synth leave the buffer before it is freed
		SystemClock.sched(0.2, { p.buf.free; nil });
	}

	// load the next piece of a proxy that isn't complete (P2 first: it is small)
	prProxyPiece {
		var p = [1, 0].collect { |i| proxies[i] }.detect { |p| p.notNil and: { p.complete.not } };
		var n;
		if(p.isNil) { ^this };
		n = min(pieceFrames, p.nFrames - p.loadedTo);
		pinflight = p;
		server.sendMsg(\b_read, p.buf.bufnum, p.file, p.loadedTo, n, p.loadedTo, 0);
	}

	prPieceDone { |okRead|
		var p = pinflight, i;
		pinflight = nil;
		if(p.isNil) { ^this };
		if(okRead.not) { i = proxies.indexOf(p); i !? { this.prDropProxy(i) }; ^this };
		p.loadedTo = p.loadedTo + pieceFrames;
		if(p.loadedTo >= p.nFrames) {
			p.complete = true;
			"AurTape: P% loaded (% s of audio at % Hz, % s)".format(
				proxies.indexOf(p) + 1, (p.nFrames / p.sr).round(0.1), p.sr,
				(Main.elapsedTime - p.t0).round(0.01)).postln;
			synth !? { synth.set(*this.prProxyArgs) };
		};
		this.service;
	}

	prProxyArgs {
		// a valid mono buffer for an unloaded proxy (its weight is 0)
		var dummy = if(valid.notNil) { valid.bufnum } { 0 };
		var args = [];
		2.do { |i|
			var p = proxies[i], k = i + 1, on = this.hasProxy(i);
			var rate = if(on) { p.sr } { fileRate / decim[i] };
			args = args ++ [
				("p" ++ k ++ "buf").asSymbol, if(on) { p.buf.bufnum } { dummy },
				("hasP" ++ k).asSymbol, on.binaryValue,
				("p" ++ k ++ "Ratio").asSymbol, rate / fileRate,
				("p" ++ k ++ "Nyq").asSymbol, rate * 0.45
			]
		};
		^args ++ [\maxRate, this.maxRate]
	}

	// close the current measurement phase, write it to the report, start `name`
	phase { |name|
		var dur = Main.elapsedTime - phaseStart;
		var line = ("% dur=%s reads=% MB/s=% read_avg_ms=% read_max_ms=% misses=% seeks=% "
			++ "seek_avg_ms=% seek_max_ms=% cpu_avg=% cpu_peak=% jump_gain=% covers=% proxy_max=% p1=% p2=%")
		.format(phaseName, dur.round(0.1), st.reads,
			(st.bytes / 1e6 / dur.max(0.001)).round(0.01),
			(st.readSum / st.reads.max(1) * 1000).round(0.1), (st.readMax * 1000).round(0.1),
			st.misses, st.seeks,
			(st.seekSum / st.seekN.max(1) * 1000).round(0.1), (st.seekMax * 1000).round(0.1),
			(st.cpuSum / st.cpuN.max(1)).round(0.1), st.cpuPeak.round(0.1), st.jumpGain.round(0.001),
			st.covers, st.proxyMax.round(0.01), this.hasProxy(0).binaryValue, this.hasProxy(1).binaryValue);
		var f;
		line.postln;
		File.mkdir(reportPath.dirname);
		f = File(reportPath, "a");
		f.write(line ++ "\n");
		f.close;
		phaseName = name;
		this.resetStats;
	}

	prFreeServer {
		synth !? { synth.free }; synth = nil;
		ring !? { ring.free }; ring = nil;
		valid !? { valid.free }; valid = nil;
	}

	free {
		[posFunc, okFunc, doneFunc, failFunc, jgFunc].do { |f| f !? { f.free } };
		this.prFreeServer;
		proxies.do { |p| p !? { p.buf.free } };
		proxies = [nil, nil];
	}
}

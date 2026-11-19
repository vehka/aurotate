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
// Frame positions are float32 on the server. Every position the server is
// given is a multiple of `quant` frames, so it is exact up to 2^30 frames
// (6.2 h at 48 kHz) and the ring offset computed here matches it.

AurTape {
	classvar <chunkSecs = 4, <quant = 64;

	var <server, <target, <outBus, <ringSecs, <id;
	var <path, <numFrames = 0, <fileChannels = 2, <fileRate = 48000;
	var <ring, <valid, <synth, <slots, <chunkFrames, <ringFrames, <numChunks = 0;
	var slotChunk, inflight, loading = false, holdChunk, holdUntil = 0;
	var <pos = 0, <actualRate = 0, <targetRate = 0, <ok = 0, <jogging = false;
	var <loopOn = false, <loopStart = 0, <loopEnd = 0, loopReq;
	var queued;
	var <amp = 1, <jogStop = 0.5, <fade = 0.008, parked = false, nudgeTotal = 0;
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
			loopOn = 0, loopStart = 0, loopEnd = 1, loopStartRing = 0, loopBackFile = 0, loopBackRing = 0|
			// previous blocks: [kpos(n-1), kpos(n-2), jumped(n-1)]
			var fb = LocalIn.kr(3);
			var lp = fb[0], lpp = fb[1], jumpedPrev = fb[2];
			// jog: an integrator with friction; t_jogZero resets it to the nudge.
			// nudges arrive as a running total, so several in one block add up
			var nudge = nudgeSum - Delay1.kr(nudgeSum);
			var jogRate = Integrator.kr(nudge, exp(ControlDur.ir.neg / jogStop) * (1 - t_jogZero)).clip(-64, 64);
			// lag time 0 while jogging, so leaving jog glides from the jog rate
			var ru = Lag.kr(Select.kr(jog, [rate, jogRate]), rateLag * (1 - jog));
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
			SendReply.kr(Impulse.kr(25), '/aur/pos', [kpos, ru], id);
			SendReply.kr(Changed.kr(okk), '/aur/ok', [okk, kpos, ru], id);
			// gain when a jump or wrap lands (the previous block's, which K2A
			// starts the jump block from): should be 0 (jump_gain in the report)
			SendReply.kr(trig, '/aur/jg', [Delay1.kr(gain)], id);
			Out.ar(out, sig * K2A.ar(gain) * Lag.kr(okk, 0.004) * Lag.kr(amp, 0.05));
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
				this.prSampleCpu;
				this.prEdges;
				this.service;
			}
		}, '/aur/pos');
		okFunc = OSCFunc({ |msg| if(this.prMine(msg)) { this.prOk(msg[3], msg[4], msg[5]) } }, '/aur/ok');
		jgFunc = OSCFunc({ |msg|
			if(this.prMine(msg)) { st.jumpGain = max(st.jumpGain, msg[3]) }
		}, '/aur/jg');
		doneFunc = OSCFunc({ |msg|
			if(msg[1] == '/b_readChannel' and: { ring.notNil and: { msg[2] == ring.bufnum } }) {
				this.prReadDone(true)
			}
		}, '/done');
		failFunc = OSCFunc({ |msg|
			if(msg[1] == '/b_readChannel' and: { inflight.notNil }) {
				("AurTape: read failed " ++ msg).postln; this.prReadDone(false)
			}
		}, '/fail');
	}

	prMine { |msg| ^synth.notNil and: { msg[1] == synth.nodeID } and: { msg[2] == id } }

	resetStats {
		st = (reads: 0, readSum: 0, readMax: 0, misses: 0,
			seeks: 0, seekSum: 0, seekMax: 0, seekN: 0, bytes: 0,
			cpuSum: 0, cpuN: 0, cpuPeak: 0, jumpGain: 0);
		phaseStart = Main.elapsedTime;
	}

	prSampleCpu {
		st.cpuSum = st.cpuSum + server.avgCPU;
		st.cpuN = st.cpuN + 1;
		st.cpuPeak = max(st.cpuPeak, server.peakCPU);
	}

	q { |frame| ^(frame / quant).round * quant }

	// open a file; requests made while one is loading are queued (last wins)
	open { |argPath, startSecs = 0|
		if(loading) { queued = [argPath, startSecs]; ^this };
		loading = true;
		fork {
			this.load(argPath, startSecs);
			loading = false;
			if(queued.notNil) { var q = queued; queued = nil; this.open(*q) };
		}
	}

	// call from a Routine; use `open` otherwise
	load { |argPath, startSecs = 0|
		var startFrame, sf = SoundFile.openRead(argPath.standardizePath);
		if(sf.isNil) { ("AurTape: can't open " ++ argPath).postln; ^false };
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
			\amp, amp, \jogStop, jogStop, \fade, fade
		] ++ this.prLoopArgs, target);
		pos = startFrame; targetRate = 0; actualRate = 0; jogging = false; parked = false; nudgeTotal = 0;
		("AurTape: % (% s, % ch, % Hz), ring % s in % slots"
			.format(path, (numFrames / fileRate).round(0.1), fileChannels, fileRate, ringSecs, slots)).postln;
		this.jump(startFrame);
		^true
	}

	// change the ring size; reopens the current file at the current position
	setRing { |secs, reopen = true|
		if(secs == ringSecs) { ^this };
		ringSecs = secs;
		if(reopen and: { path.notNil }) { this.open(path, pos / fileRate) }
	}

	duration { ^numFrames / fileRate }
	posSecs { ^pos / fileRate }

	setRate { |r, lag = 0.1|
		targetRate = r.clip(-64, 64);
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
		if(this.prResident(frame)) {
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

	service {
		var c, dir, ahead, behind, order, claimed, ls, le, inLoop, w;
		if(numChunks <= 0 or: { inflight.notNil } or: { synth.isNil }) { ^this };
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
					if(slotChunk[slot] != w) { ^this.prRead(this.prPair(w, c, dir, claimed)) };
				}
			}
		}
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
			if(jumpTime.isNil and: { r.abs > 0.001 } and: { kpos > 0 } and: { kpos < (numFrames - 1) }) {
				var w = (kpos / chunkFrames).floor.asInteger;
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

	// close the current measurement phase, write it to the report, start `name`
	phase { |name|
		var dur = Main.elapsedTime - phaseStart;
		var line = ("% dur=%s reads=% MB/s=% read_avg_ms=% read_max_ms=% misses=% seeks=% "
			++ "seek_avg_ms=% seek_max_ms=% cpu_avg=% cpu_peak=% jump_gain=%")
		.format(phaseName, dur.round(0.1), st.reads,
			(st.bytes / 1e6 / dur.max(0.001)).round(0.01),
			(st.readSum / st.reads.max(1) * 1000).round(0.1), (st.readMax * 1000).round(0.1),
			st.misses, st.seeks,
			(st.seekSum / st.seekN.max(1) * 1000).round(0.1), (st.seekMax * 1000).round(0.1),
			(st.cpuSum / st.cpuN.max(1)).round(0.1), st.cpuPeak.round(0.1), st.jumpGain.round(0.001));
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
	}
}

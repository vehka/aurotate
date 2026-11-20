// AurOut: a voice's output stage (docs/PLAN.md §2.4, §3)
//
//   voice bus -> tone (tilt EQ) -> pan (balance) -> gain -+-> dry    -> main out
//                                                         +-> send A -> fx send a
//                                                         +-> send B -> fx send b
//
// The settings come from the regions under the voice's position. Lua turns
// the regions into a list of segments, each with one combined set of
// settings (lib/sound.lua); sclang keeps the list as a partition of the
// whole tape (neutral between segments). The synth holds three sets: the
// segment the playhead is in (`cur`, between `a` and `b`), the one before
// and the one after. Crossing a boundary switches set inside the synth, so
// the change starts on the control block where it happens; the synth then
// asks sclang (SendReply) to re-centre on the new segment. Every change
// glides over `glide` seconds.
//
// A jump or a loop wrap (the tape's position bus carries a trigger for both)
// lands somewhere else: the synth asks for a re-centre and takes whatever
// arrives in the next 30 ms without a glide, since a jump lands in silence.
//
// Sends: the fx mod's buses (`FxSetup.sendA/B`, v1 and v2), looked up every
// 2 s; while there is no mod (or no rack yet) the sends write to a private
// bus nobody reads.

AurOut {
	// dry, send A, send B, gain (amplitude), pan, tone
	classvar <neutral = #[1, 0, 0, 1, 0, 0];

	var <server, <group, <inBus, <posBus, <outBus, <id;
	var <synth, <segs, dummy, <sendA = -1, <sendB = -1, <fxState = 0;
	var replyFunc, checker, <glide = 0.05, lastT = 0, <recentres = 0;

	*new { |server, group, inBus, posBus, outBus, id = 0|
		^super.newCopyArgs(server, group, inBus, posBus, outBus, id).prInit
	}

	*addDefs {
		SynthDef(\aurOut, { |in = 0, pos = 0, out = 0, sendA = 0, sendB = 0,
			a = -1e9, b = 1e9, glide = 0.05, id = 0|
			var cur = \cur.kr(neutral), prv = \prv.kr(neutral), nxt = \nxt.kr(neutral);
			var p = In.kr(pos, 2), t = p[0], jumped = p[1] > 0;
			// -1 before the current segment, 0 inside, 1 after
			var side = (t >= b) - (t < a);
			var away = side.abs > 0;
			var tgt = neutral.size.collect { |k| Select.kr(side + 1, [prv[k], cur[k], nxt[k]]) };
			var snap = Trig1.kr(jumped, 0.03);
			var v = Lag.kr(tgt, glide * (1 - snap));
			var dry = v[0], sa = v[1], sb = v[2], gain = v[3], pan = v[4], tone = v[5];
			var sig = In.ar(in, 2);
			// tilt: ±9 dB at the ends, pivot around 800 Hz; flat at 0
			sig = BHiShelf.ar(BLowShelf.ar(sig, 250, 1, tone * -9), 2500, 1, tone * 9);
			// balance, unity in the middle
			sig = sig * [(1 - pan).min(1), (1 + pan).min(1)] * gain;
			Out.ar(out, sig * dry);
			Out.ar(sendA, sig * sa);
			Out.ar(sendB, sig * sb);
			// re-centre: on leaving the segment, after a jump, and while still
			// outside it (a lost reply, or two boundaries in one go)
			SendReply.kr(((Changed.kr(side) * away) + jumped + (Impulse.kr(8) * away)) > 0,
				'/aur/seg', [t], id);
		}).add;
	}

	prInit {
		dummy = Bus.audio(server, 2);
		segs = [[-1e9, 1e9, neutral]];
		this.prResolve(false);
		synth = Synth(\aurOut, [\in, inBus, \pos, posBus, \out, outBus, \sendA, sendA, \sendB, sendB,
			\id, id, \glide, glide], group, \addToTail);
		replyFunc = OSCFunc({ |msg|
			if(synth.notNil and: { msg[1] == synth.nodeID } and: { msg[2] == id }) { this.recentre(msg[3]) };
		}, '/aur/seg', server.addr);
		checker = Routine { loop { 2.wait; this.prResolve } }.play(SystemClock);
	}

	prBusIndex { |b| ^if(b.isNumber) { b.asInteger } { b.index } }

	// the fx mod's send buses, or the private bus
	prResolve { |apply = true|
		var fx = \FxSetup.asClass, ba, bb, ia, ib;
		ba = fx !? { fx.sendA };
		bb = fx !? { fx.sendB };
		ia = this.prBusIndex(ba ? dummy);
		ib = this.prBusIndex(bb ? dummy);
		fxState = ba.notNil.binaryValue + (2 * bb.notNil.binaryValue);
		if((ia != sendA) or: { ib != sendB }) {
			sendA = ia; sendB = ib;
			if(apply) { synth !? { synth.set(\sendA, ia, \sendB, ib) } };
			("AurOut %: sends a % b %%".format(id, ba !? { ia } ? "-", bb !? { ib } ? "-",
				if(fx.isNil) { " (no fx mod)" } { "" })).postln;
		};
	}

	setGlide { |s| glide = s.clip(0, 2); synth !? { synth.set(\glide, glide) } }

	// list: [t0, t1, dry, sendA, sendB, gain dB, pan, tone] per segment, in
	// seconds, sorted and not overlapping
	setSegs { |list|
		var out = List.new, last = -1e9;
		list.do { |s|
			var vals = [s[2], s[3], s[4], if(s[5] <= -60) { 0 } { s[5].dbamp }, s[6], s[7]];
			if(s[1] > s[0] and: { s[0] >= last }) {
				if(s[0] > last) { out.add([last, s[0], neutral]) };
				out.add([s[0], s[1], vals]);
				last = s[1];
			};
		};
		out.add([last, 1e9, neutral]);
		segs = out.asArray;
		this.recentre(lastT);
	}

	// the segment holding t becomes the current one
	recentre { |t|
		var n = segs.size, lo = 0, hi = n - 1, mid, s;
		lastT = t;
		recentres = recentres + 1;
		// the last segment starting at or before t
		while { lo < hi } {
			mid = (lo + hi + 1) div: 2;
			if(segs[mid][0] <= t) { lo = mid } { hi = mid - 1 };
		};
		s = segs[lo];
		synth !? {
			server.makeBundle(nil, {
				synth.set(\a, s[0], \b, s[1]);
				synth.setn(\cur, s[2],
					\prv, if(lo > 0) { segs[lo - 1][2] } { neutral },
					\nxt, if(lo < (n - 1)) { segs[lo + 1][2] } { neutral });
			});
		};
	}

	free {
		checker !? { checker.stop }; checker = nil;
		replyFunc !? { replyFunc.free }; replyFunc = nil;
		synth !? { synth.free }; synth = nil;
		dummy !? { dummy.free }; dummy = nil;
	}
}

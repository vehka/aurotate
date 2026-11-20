// Engine_Aurotate: long-file tape playback
//
// commands (times in seconds, rates in ×, levels as amplitude)
//   open s f f     path, start position, ring window length
//   ring f         ring window length; reopens the file at the current position
//   rate f f       transport rate (-64..64; -256..256 with P2 loaded), glide time; leaves jog mode
//   jog_nudge f    push the tape (enters jog mode at the current speed)
//   jog_stop f     jog friction: time constant of the coast down
//   jump f         seek
//   loop i f f     on/off, in, out
//   amp f
//   fade f         jump / loop seam fade time
//   proxy i s s    level (1 = P1, 2 = P2), tape path, proxy path ("" drops it);
//                  ignored unless the tape is the open file
//   lifter f       0 = full head contact at speed, 1 = lifted (silent cue)
//   focus f        crossfade time from a proxy to full resolution
//   phase s        close a measurement phase (test/transport.lua)
//   snd_clear i    start a new list of region sound segments (i: how many follow)
//   snd_seg ffffffff  one segment: t0, t1 (s), dry, send A, send B (0..1),
//                  gain (dB, -60 = off), pan (-1..1), tone (-1..1)
//   snd_commit i   use the list (only if i segments arrived since snd_clear)
//   snd_glide f    glide time for region sound changes (s)
// polls: aur_pos, aur_rate, aur_ok (chunk under the playhead loaded), aur_misses,
//   aur_dur, aur_proxies (bit 1: P1 loaded, bit 2: P2), aur_proxy_share (0..1,
//   how much of the sound comes from the proxies), aur_fx (bit 1: fx send a
//   found, bit 2: send b)
//
// node order in context.xg: one group per voice, the tape at its head writing
// to the voice bus, the output stage (AurOut) at its tail

Engine_Aurotate : CroneEngine {
	var group, voiceBus, tape, out, staging;

	*new { |context, doneCallback| ^super.new(context, doneCallback) }

	alloc {
		AurTape.addDefs;
		AurOut.addDefs;
		context.server.sync;
		group = Group.new(context.xg);
		voiceBus = Bus.audio(context.server, 2);
		tape = AurTape(context.server, group, voiceBus.index, 64, 0);
		out = AurOut(context.server, group, voiceBus.index, tape.posBus.index, context.out_b.index, 0);
		staging = List.new;

		// never name a command `load`: it collides with Lua's engine.load
		this.addCommand(\open, "sff", { |msg|
			tape.setRing(msg[3], false);
			tape.open(msg[1].asString, msg[2])
		});
		this.addCommand(\ring, "f", { |msg| tape.setRing(msg[1]) });
		this.addCommand(\rate, "ff", { |msg| tape.setRate(msg[1], msg[2]) });
		this.addCommand(\jog_nudge, "f", { |msg| tape.nudge(msg[1]) });
		this.addCommand(\jog_stop, "f", { |msg| tape.setJogStop(msg[1]) });
		this.addCommand(\jump, "f", { |msg| tape.jumpSecs(msg[1]) });
		this.addCommand(\loop, "iff", { |msg| tape.setLoop(msg[1] > 0, msg[2], msg[3]) });
		this.addCommand(\amp, "f", { |msg| tape.setAmp(msg[1]) });
		this.addCommand(\fade, "f", { |msg| tape.setFade(msg[1]) });
		this.addCommand(\proxy, "iss", { |msg| tape.setProxy(msg[1], msg[2].asString, msg[3].asString) });
		this.addCommand(\lifter, "f", { |msg| tape.setLifter(msg[1]) });
		this.addCommand(\focus, "f", { |msg| tape.setFocus(msg[1]) });
		this.addCommand(\phase, "s", { |msg| tape.phase(msg[1].asString) });
		this.addCommand(\snd_clear, "i", { |msg| staging = List.new });
		this.addCommand(\snd_seg, "ffffffff", { |msg| staging.add(msg[1..8]) });
		this.addCommand(\snd_commit, "i", { |msg|
			if(staging.size == msg[1]) { out.setSegs(staging) } {
				("AurOut: % of % segments arrived; kept the old list".format(staging.size, msg[1])).postln
			}
		});
		this.addCommand(\snd_glide, "f", { |msg| out.setGlide(msg[1]) });

		this.addPoll(\aur_pos, { tape.posSecs });
		this.addPoll(\aur_rate, { tape.actualRate });
		this.addPoll(\aur_ok, { tape.ok });
		this.addPoll(\aur_misses, { tape.st.misses });
		this.addPoll(\aur_dur, { tape.duration });
		this.addPoll(\aur_proxies, { tape.hasProxy(0).binaryValue + (2 * tape.hasProxy(1).binaryValue) });
		this.addPoll(\aur_proxy_share, { tape.proxyShare });
		this.addPoll(\aur_fx, { out.fxState });
	}

	free {
		out !? { out.free };
		tape !? { tape.free };
		voiceBus !? { voiceBus.free };
		group !? { group.free };
	}
}

// Engine_Aurotate: long-file tape playback
//
// commands (times in seconds, rates in ×, levels as amplitude)
//   open s f f     path, start position, ring window length
//   ring f         ring window length; reopens the file at the current position
//   rate f f       transport rate (-64..64), glide time; leaves jog mode
//   jog_nudge f    push the tape (enters jog mode at the current speed)
//   jog_stop f     jog friction: time constant of the coast down
//   jump f         seek
//   loop i f f     on/off, in, out
//   amp f
//   fade f         jump / loop seam fade time
//   phase s        close a measurement phase (test/transport.lua)
// polls: aur_pos, aur_rate, aur_ok (chunk under the playhead loaded), aur_misses,
//   aur_dur

Engine_Aurotate : CroneEngine {
	var tape;

	*new { |context, doneCallback| ^super.new(context, doneCallback) }

	alloc {
		AurTape.addDefs;
		context.server.sync;
		tape = AurTape(context.server, context.xg, context.out_b.index, 64, 0);

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
		this.addCommand(\phase, "s", { |msg| tape.phase(msg[1].asString) });

		this.addPoll(\aur_pos, { tape.posSecs });
		this.addPoll(\aur_rate, { tape.actualRate });
		this.addPoll(\aur_ok, { tape.ok });
		this.addPoll(\aur_misses, { tape.st.misses });
		this.addPoll(\aur_dur, { tape.duration });
	}

	free {
		tape !? { tape.free };
	}
}

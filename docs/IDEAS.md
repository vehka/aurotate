# "script" view

* A bit like octatrack's arranger, simple commands define how to "play" through track, like
	* repeat 2 times:
		* start from marker one
		* stop at marker two
		* rev at 2x speed to marker one
	* jump to region three
	* stop at end of region

# LFOs for regions

* e.g. linear slopes for params, from 0-100 or 100-0, from region start to end
* start at region or free-flowing, start from play, basic shapes. (my fork of ../less-concepts has these I think)

# Different modes / UI paradigms

* without keyboard: archipelagic listening (E. Glissant)
	* the idea is to listen to something, repeatedly, until our perpection of it differs
* with keyboard: audio ethnographer
	* keyboard shortcuts for cueing, adding marks & regions, annotating
		* after phase 4 hands-on (2026-11-20):
		* Up / Down: jump to the previous / next mark (or region start)
		* Left / Right: cue (REW / FF while held), Shift and Ctrl change the speed
		* Space for play / stop instead of Esc
		* conflicts to solve: in the note editor the arrows move the cursor and
		  Space types a space, and typing a letter on the tape page starts a
		  note. Maybe these keys only act outside the editor (Esc or a modifier
		  inside it), or a modifier combo everywhere
	* possibly integration with a transcription file, or not
	* maybe: add audio notes as annotations, then can be played back along the sound or not (with softcut maybe?)
	* notes-on-notes? allow stacking of notes, but gets tricky UI-wise
	* Zotero export?
* with grid
	* performance mode? unnecessary?

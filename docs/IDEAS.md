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
		* after phase 5 regions list (2026-11-20), on the regions page:
		* Enter: open the selected mark / region (now it jumps the tape there)
		  in the item popup (the editing one, not the reader); there Up / Down
		  pick the property (label, note, tags, times...) and Enter again edits
		  it: the note opens the note editor, the label text entry, etc.
		* Space: jump the tape to the selected item
		* note: Space is play / stop on the tape page in the idea above, so
		  Space would mean different things on the two pages
	* possibly integration with a transcription file, or not
	* maybe: add audio notes as annotations, then can be played back along the sound or not (with softcut maybe?)
	* notes-on-notes? allow stacking of notes, but gets tricky UI-wise
	* Zotero export?
* with grid
	* performance mode? unnecessary?

# tags

* filetag support (https://github.com/novoid/filetags) --> aurotate tags when adding files



# WNM-PGB1-firmware (multivoice/soundmodule fork)

Open-source pocket groovebox, originally created by [Wee Noise Makers](https://weenoisemakers.com) (Fabien Chouteau) — see [upstream](https://github.com/wee-noise-makers/WNM-PGB1-firmware). This fork's changes are by Joseph Wozniak ([woz.lol](https://woz.lol)).

## This fork

### Milestone: Chord polyphony + note-priority retrig (2026-09-28)

1. **Last-note-priority retrig on Bass, Lead, and the drum/sample tracks.** Hold a note, tap another one, then let go of the newer note — it now falls back to the note you're still holding instead of cutting out, the way an old analog mono synth remembers your held key. Trills and legato runs behave the way you'd expect instead of the voice dying the instant the newest key lifts. (Not applied to the Chord track, which is polyphonic — see below.)

2. **The Chord track is genuinely 4-voice polyphonic now.** Play up to 4 notes at once and each one sounds independently, releases independently, and fades out click-free. Play a 5th note while all 4 are busy and the oldest one gets voice-stolen instantly for the new note — but if you're still physically holding that stolen note's key, it comes back to life the moment a voice frees up instead of just being dropped, the way a real 4-voice poly synth's voice allocation works.

### Known limitations in this build (to revisit)

- The Bass/Lead "number of voices" setting doesn't do anything yet — polyphony for those tracks hasn't been implemented.
- Chord's Glide knob does nothing right now. An earlier glide implementation caused audio artifacts and was pulled back out; needs a proper redo.
- The Chord Mode setting (Generated / Direct Poly) is currently stuck on Direct Poly regardless of what it's set to — Generated mode isn't actually reachable yet, needs investigation.
- There's an intermittent, hard-to-reproduce crackle on the Chord track, roughly every few seconds while holding notes. It may be correlated with which menu screen is open (Track Settings vs. System Info) rather than pure CPU load, which stayed comfortably under 90% in testing — needs more investigation across screens.

---

Open-source pocket groovebox

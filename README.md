# WNM-PGB1-firmware (multivoice/soundmodule fork)

Open-source pocket groovebox, originally created by [Wee Noise Makers](https://weenoisemakers.com) (Fabien Chouteau), see [upstream](https://github.com/wee-noise-makers/WNM-PGB1-firmware). This fork's changes are by Joseph Wozniak ([woz.lol](https://woz.lol)).

## This fork

> **Build note.** One fix lives in a pinned dependency, which Alire keeps in
> the gitignored `device/alire/cache/` and which therefore does not survive a
> fresh checkout. After cloning, build once so Alire fetches the pins, then run
> `./patches/apply.sh` and build again. Without it the periodic click described
> below comes back.

### The periodic click, fixed (2026-09-29)

Every PGB-1 running stock firmware puts a periodic click into the output, a
couple of times a second, on headphones, on every instrument, at any volume.
It is audible on a single held note and it is not in the audio data at all.

The cause is a sample-rate mismatch. The RP2040's PIO generates the I2S clocks
by dividing the system clock, and the divider is 16.8 fixed point, so at 133
MHz the closest it can get to 32 kHz is 32,001.925 Hz. The codec meanwhile was
generating its own sample clock from its 24 MHz reference, landing on
31,999.80 Hz. Those two rates differ by about two hertz, so the codec slips
roughly twice a second, and every slip is a click. Nothing in the firmware's
audio path can fix that, because the samples were always correct.

The fix is to source the codec's PLL from the incoming bit clock instead of its
own reference, so its rate is defined by ours and cannot drift against it at
any system clock. For 32 kHz that is J=32, D=0, R=2, P=1, which is exact. That
is what `patches/apply.sh` applies.

How it was pinned down, in case it helps anyone chasing something similar:

- A bit-exact 500 Hz tone written straight into the output, bypassing every
  instrument and mix stage, still clicked. So it was not the DSP.
- The PIO's sticky `TXSTALL` flag stayed clear, so the output never starved,
  and the mixer's own dropped-buffer counter never moved, so the buffer queue
  never ran dry.
- A per-sample discontinuity detector watching the finished mix found nothing
  over ten seconds of a held note while the clicks were audible.
- Reading the PIO's clock divider register gave 32,001.925 Hz, and the
  arithmetic predicted the click rate that was actually being heard. Changing
  the system clock to 200 MHz, where the divider is exactly representable,
  changed the click rate as predicted, which confirmed the mechanism before
  the real fix went in.

One smaller thing came out of the same hunt and is also fixed: the
headphone-detect I2C poll ran every 250 ms and put a faint tick in the output
each time, audible against a quiet steady tone, so it now runs once a second.
Driving detection off the IO expander's interrupt line would remove it outright.

Noted but deliberately left alone: the codec's line input is summed into the
output on every buffer whether or not anything is plugged in, so its noise
floor is always present. Skipping it unconditionally would break live input
monitoring, so doing this properly means gating it on whether monitoring is
actually wanted.

### Milestone: Chord polyphony + note-priority retrig (2026-09-28)

1. **Last-note-priority retrig on Bass, Lead, and the drum/sample tracks.** Hold a note, tap another one, then let go of the newer note. It now falls back to the note you're still holding instead of cutting out, the way an old analog mono synth remembers your held key. Trills and legato runs behave the way you'd expect, instead of the voice dying the instant the newest key lifts. Each of these tracks has its own on/off tab for this, labeled "Last Note / Retrigger". Not applied to the Chord track, which has its own independent polyphony.

2. **The Chord track is polyphonic, up to 5 voices.** Play up to 5 notes at once and each one sounds independently, releases independently, and fades out click-free. Play another note while all voices are busy and the oldest one gets voice-stolen instantly for the new note. But if you're still physically holding that stolen note's key, it comes back to life the moment a voice frees up, instead of just being dropped, the way a real poly synth's voice allocation works. The Chord track's own tab (same position as the other tracks' Retrigger tab) shows the current voice count and lets you change it, from 1 to 5.

3. **Tab cycling wraps around.** On every track's settings screen, arrowing right past the last tab goes to the first, and arrowing left past the first goes to the last, instead of stopping at either end.

### Known limitations in this build (to revisit)

- Chord's voice count is capped at 5, not higher, because each voice carries its own independent envelope for click-free release, and that's what fits in RAM alongside everything else. Going higher would mean shrinking the envelope engine shared by every instrument, a separate change.
- The Bass/Lead "number of voices" setting doesn't do anything yet. Polyphony for those tracks hasn't been implemented.
- Chord's Glide knob does nothing right now. An earlier glide implementation caused audio artifacts and was pulled back out, needs a proper redo.
- The Chord Mode setting (Generated / Direct Poly) only affects programmed sequencer steps, a step with Note Mode "Chord" or "Note in Chord". It has no effect on live playing, in either mode, by design, matching stock behavior for the harmonized chord-progression feature itself.
- The "Arpeggiator notes" tab is hidden (commented out in `Valid_Setting`, not deleted) because its underlying setting, `Arp_Notes_Kind`, only has one possible value, so the tab had nothing to cycle to. Stock firmware behavior, not something this fork changed, just hidden until that setting grows more options.
- Waveforms are read on a 1024-point grid with band-limited copies per pitch zone, generated by `scripts/gen_chord_wavetables.py` into `common/generated/`. This removes the harmonics that would fold back as inharmonic fizz at high pitch on the genuinely bright waveforms, Sawtooth, both Pulses, Screech and Sine+Saw. It costs flash only, no RAM and no extra work per sample. The custom user waveform is drawn at run time so there is nothing precomputed for it and it reads the coarse table as before.
- The Chord params screen shows the current waveform's name instead of the word "Waveform". On Lead, the Buzz engine's first param is relabeled "Comb Brightness", because it slides across band-limited comb tables rather than selecting a named waveform.

---

Open-source pocket groovebox

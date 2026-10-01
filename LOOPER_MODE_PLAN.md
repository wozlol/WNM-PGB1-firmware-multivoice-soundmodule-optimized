# 4-Track Looper Mode, overnight build log

Working log for the looper mode build, kept honest as I go. Anything marked
DONE has been compiled against the release build. Nothing has been flashed
or heard, so bug hunting on hardware is the next step regardless of what is
marked done.

Reference: `/Users/woz/Projects/arpnmidi`, specifically
`arpnmidi os/arpnmidi_main_brain/src/four_track_looper.cpp` and `.h` for the
looper engine, treated as gospel for timing and edge cases per instruction.

## Spec, condensed

- New "Sequencer Mode" tab, second item in the root Menu (after Projects).
  Shows both choices side by side like the Projects icon tab: 4-Track Looper
  icon and label on the left, OG Sequencer icon (8x2 dot grid) and label on
  the right. A/B indicate and switch between them. Switching to Looper warns
  "Project sequences will be lost" and clears Steps/Patterns, because that
  RAM becomes the loop event pool.
- New Looper tab (5 columns: 4 loop tracks + AUT). Per track: icon
  (square/triangle/hollow circle/filled circle), bars 1-16, quantize
  off/8/16/32. AUT column: off/overdub/track/arm, defined in the spec.
  Left/right move columns, up/down change bars, A cycles quantize, B back.
- Step button, not held: LiveArp control surface. Buttons 1-6 pick arp style
  (retrigger turns it off), 7-8 toggle octave-down/octave-up range, standard
  division buttons 9-16. Chord track never arps, always plays held notes as
  a poly chord. Channel 10 (drums/samples) always arps in chord/trigger
  mode regardless of the global style, as an inseparable but independently
  divisible sidecar, so trap-style hat ratchets do not fight arp styles on
  other channels. Holding the current division and tapping another is a
  temporary override on channels 2,3,4,8,9,10 only, recorded into the loop
  as real CC/note data so the looped result keeps the ratchet.
- Step button, held: Stutter (1-8, arpnmidi's own divisions) and dub delay
  with 3 decaying repeats (9-16, standard divisions), global across tracks.
- Play/Edit/Song/Pattern/Copy button behavior changes, detailed below.
- Channel 10 special notes 36-50, detailed below.
- CC and pitch bend are recorded at a configurable resolution (new setting
  on the Live FX Preferences tab).
- Looper data and its settings persist with the project.

## RAM

Steps alone (not Patterns, see below) is the part of Project_Rec reused for
the loop pool. Its real size is 53248 bytes, read off a `-gnatR2` dump, not
the 34816 I first hand-counted from the field declarations (GNAT does not
bit-pack a record's own fields just because the record sits in a packed
array; only `with Pack` on the record itself does that, which Step_Rec
doesn't have). The `Steps_Storage_Bytes` constant in `wnm-project.ads` has
a `pragma Compile_Time_Error` next to it in the body checking it against
the real type, so if this number is ever wrong again the build fails
instead of the overlay quietly running past the end of Steps. Patterns is
left alone, small and not worth a second overlay.

SCRATCH_X and SCRATCH_Y (8K combined, shown as 0% used in every build
report) are NOT free: SCRATCH_X is core 1's entire stack, set directly in
`wnm_hal-synth_core.adb`'s `Stack_Pointer`, and SCRATCH_Y holds core 0's
stack per the stock linker script. The 0% in the build report is because
stack regions are not ordinary linker sections. Confirmed by reading the
linker script and the core 1 entry point, not guessed. Left alone.

The firmware had exactly 4 bytes of RAM to spare before tonight (258044
used of 258048 available). That is tight enough that even "the event pool
and its tiny bookkeeping all live in the Steps overlay, so it should cost
nothing" genuinely overflowed at first, by amounts from a few hundred bytes
down to as little as 4, through several rounds of fixes:

- Not just the event pool but ALL of `WNM.Looper`'s state (the per-track
  bookkeeping, the small held-note tables, every flag) is now inside one
  `Looper_Overlay` record on top of Steps. None of it meant anything
  outside Four_Track_Looper mode, so none of it should cost anything
  outside that mode either, and now it doesn't.
- The overlay is reached through a function that computes its address
  fresh on every call (`Overlay_Ptr`), not a package-level object with an
  `Address` aspect. The latter needs its own stored 4-byte pointer, and
  with only 4 bytes of slack to begin with, that pointer alone was the
  entire overflow in the final build. Confirmed by removing it and
  watching RAM return to exactly the pre-feature 258044.
- `Looper_Overlay` is declared `with Alignment => 1`. Without it, GNAT
  warned that the overlay (it has `UInt64` fields, wanting 8-byte
  alignment) was being pointed at Steps, which is only ever 1-byte
  aligned. This is an ARMv6-M core (Cortex-M0+), which faults on unaligned
  multi-byte access rather than tolerating it the way some ARM cores do.
  This was a real, live correctness bug caught by a compiler warning, not
  a guess, and is fixed, not just silenced.
- A `renames` for each field of the overlay was tried first, reasoning it
  would read everywhere in the body unchanged. Measured instead: each
  rename of a component of an `Import`/`Address` object costs its own
  stored address (another 4 bytes each, times roughly twenty names), which
  overflowed RAM by more than the consolidation was supposed to save.
  Every reference is `Overlay_Ptr.Field` instead; nothing is renamed.

Net effect: this whole engine, including its event pool (4300 events,
comfortably more than the reference engine's 3072), costs zero bytes of
permanent RAM over the pre-feature baseline. Verified by the build report,
not estimated.

## The step sequencer must not run at all in Looper mode

This was wrong in the first build of the Sequencer Mode tab, and it was a
real gap, not a hypothetical: the tab let you switch into Four_Track_Looper
mode, but nothing stopped WNM.Project.Step_Sequencer from continuing to
run, reading and writing Tracks/Patterns/Steps exactly as before, which in
that mode is the loop event pool's own storage. Decoding the pool's raw
bytes as Step_Rec enum values (Trigger_Kind, Note_Mode_Kind, ...) would hit
an out-of-range representation on close to the first LED refresh or
keypress and raise Constraint_Error. Found and fixed before any of this
reached hardware.

The fix is routing, not guards bolted onto Step_Sequencer's internals:
every place that currently calls into it was found (a handful of call
sites, all outside that package) and each now checks Sequencer_Mode before
calling, so in Four_Track_Looper mode the calls simply do not happen.
Step_Sequencer itself is untouched, with no awareness of Looper mode
anywhere inside it, exactly as it should be for two modes that are not
both live at once.

What is shared and was NOT touched: WNM.MIDI_Clock itself (BPM, start/
stop/continue, the tick) is the clock the whole transport runs on, and
Four_Track_Looper needs the exact same thing for its own quantize/bar
timing once it is wired in. Nothing about tempo or sync is mode-specific.

Found and routed:

- **The clock tick.** `WNM.MIDI_Clock`'s `Tick_Callback` pointed directly
  at `Step_Sequencer.MIDI_Clock_Tick`, which runs `Execute_Step` on every
  beat subdivision regardless of anything on screen. Re-pointed at a new
  `WNM.Project.MIDI_Clock_Tick_Dispatch`, which calls Step_Sequencer only
  in OG_Sequencer mode. In Looper mode this is `null` for now, since the
  Looper's own tick wiring is P4.
- **Keypad step entry (`On_Press`).** Writes `Step_Data.Note_Mode`/`.Note`/
  `.Trig` directly. Its one call site, in `wnm-ui.adb`, now only fires in
  OG_Sequencer mode.
- **The Copy feature.** Less obvious: Pattern_Button, Track_Button and
  Step_Button under the Func/Copy combo all start a copy that ends up
  writing `G_Project.Steps` (the one bound to Track_Button copies every
  step of every pattern for a track, not track engine settings, despite
  the name). All three gated at their call sites in `wnm-ui.adb`.
  Song_Button's copy (Song Parts, Chord Progressions) is untouched, it
  never reaches Steps.
- **Pattern_Menu and Step_Menu.** Both push screens
  (`wnm-gui-menu-pattern_settings.adb`, `wnm-gui-menu-step_settings.adb`)
  that read Steps through WNM.Project's "Step getters" (`Trigger`,
  `Note_Mode`, `Duration`, `Velocity`, `CC_Value`, ...). Opening either is
  now gated at the Pattern_Button/Step_Button handlers in `wnm-ui.adb`;
  pressing them in Looper mode just bounces back to the previous mode,
  same as if the screen had already been open. Track_Menu, Chord_Menu and
  Sample_Edit_Menu were checked too and confirmed to never touch Steps or
  Patterns, so they are untouched and still open normally in both modes.
- **LED drawing.** The least obvious of all of these, and the one most
  likely to actually fire, because it runs on every LED refresh rather
  than only on a deliberate button press: Track_Mode's and Step_Mode's LED
  code in `wnm-ui.adb` reads per-step trigger state (`Project.Set (Step =>
  ...)`) and per-track playhead state to light the step and trigger LEDs.
  Both call sites now check Sequencer_Mode directly and skip to a minimal
  safe fallback (just the track-select LED) in Looper mode, checked there
  directly rather than only relied on via the entry gates above, because
  `Current_Input_Mode` can already be Step_Mode or Track_Mode from before
  a mode switch and nothing resets it when Sequencer_Mode changes.

Swept for anything else by grepping the whole tree for every direct
`G_Project.Steps`/`G_Project.Patterns` reference and every caller of each
of WNM.Project's Step getters and WNM.Project.Step_Sequencer's public
subprograms: exactly the files above, nothing else found. Pattern_Mode's
LED code (chained-pattern display) reads `Patterns` (Has_Link), not Steps,
and Patterns itself is real, always-valid Pattern_Rec data in both modes
(only Steps is overlaid), so it is safe, just semantically stale in Looper
mode, a cosmetic gap for P6 rather than a safety one.

## Phase status

- [x] P1: Sequencer Mode setting, persisted, and the root menu tab.
      `Sequencer_Mode_Kind` (`OG_Sequencer`/`Four_Track_Looper`) lives on
      `Project_Rec`, saved/loaded as a new Global section token so it
      survives a reload (`wnm-project-storage.adb`). `Save` skips the
      Pattern and Sequence sections entirely while in Looper mode, since
      writing them would decode the loop pool's raw bytes as Step_Rec
      values, and an out-of-range enum representation in there would crash
      the save, not just produce garbage. `Load` always calls
      `Clear_Sequences` before reading a file, so a Looper-mode project
      (which has neither section) does not inherit whatever a previously
      loaded project left in that RAM.
      The tab itself is the second item in the root Menu, right after
      Projects: both icons shown side by side (the existing `loop_icon`,
      reused per the spec, and a new hand-generated 8x2 dot grid for "OG
      Sequencer"), a box around whichever is live. Left/Right still cycle
      root tabs as everywhere else; A requests Looper, B requests OG
      Sequencer, each confirming first (`Yes_No_Dialog`, same mechanism the
      existing DFU Mode item uses) if the side being abandoned holds real
      content. Compiles clean, builds, RAM unchanged from the pre-feature
      baseline (see RAM section above for how much chasing that took).
- [x] P2: `WNM.Looper` engine, ported from `four_track_looper.cpp`.
      `common/wnm-looper.ads/.adb`. Compiles clean. Pool_Size 4300 events
      (the reference engine's own pool is 3072), and the whole engine,
      pool and bookkeeping alike, costs zero permanent RAM (see RAM
      section). Not yet wired to anything outside the Sequencer Mode tab's
      Reset/Clear_All calls, and these pieces are stubbed or missing,
      flagged honestly:
      - `Set_Bars` stores the bar count but does not call `Resize_Track`
        itself (that needs a bars-to-microseconds conversion that depends
        on BPM, which lives in WNM.Project, so the caller does both steps).
      - No persistence functions yet (`Visit_Events`, `Restore_Event`,
        `Set_Restored_Track_State`, `Begin_Import`/`Import_Event`/
        `Finish_Import` from the reference engine): P10 still has to add
        these before loop content itself can survive a save/reload. Right
        now only the Sequencer_Mode flag survives a reload, not loop data.
- [x] P3: Looper tab UI (5 columns), wired to the engine. Not a separate
      pushed window (that costs its own ~10-byte singleton, which this
      firmware does not have): it is a third item on the root Menu
      (`Looper_Config`, right after Sequencer Mode), shown collapsed with
      the loop icon and "Press A to edit" until A is pressed, same
      convention the Live FX tab already uses for its Auto-Fill and
      Stutter Pattern screens. Once entered, Left/Right move between the 4
      track columns and the AUT column, Up/Down change the selected
      track's bar count (1-16), A cycles its quantize (Off/1-8/1-16/1-32)
      or the shared AUT setting on that column, B leaves the editor. Track
      icon is one of four hand-drawn glyphs (hollow square/filled
      triangle/hollow circle/filled circle) reflecting
      `WNM.Looper.Icon`'s live state. Compiles clean, RAM unchanged.
      `WNM.Looper.Img` added for `Quantize_Kind` and `Auto_Kind`, and
      `Auto_Next` alongside the existing `Quantize_Next`.
      Known gap carried from P2: `Up`/`Down` call `Set_Bars`, which does
      not yet resize a running engine, so changing bars here only takes
      effect for a track's next recording, not one already looping.
- [ ] P4: Wire the engine into the MIDI capture/playback path, replacing
      the step sequencer dispatch when in Looper mode.
- [ ] P5: LiveArp engine (styles, octave range, per-channel division,
      channel 10 sidecar, hold-to-ratchet recording).
- [ ] P6: Play/Edit/Song/Pattern/Copy button remap for Looper mode.
- [ ] P7: Stutter (rolling-history based, arpnmidi gospel) and dub delay
      (echo-engine based) sidecars under a held Step button.
- [ ] P8: Channel 10 special notes 36-50.
- [ ] P9: Multi-select-while-holding-a-track-button, hat REL-while-held
      trick, chromatic-pulse-while-held trick.
- [ ] P10: Persistence of loop event data and settings with the project
      (token format in `wnm-project-storage.adb`).

Each section below is updated as that phase is actually built. A phase with
no entry below has not been started: treat its line above as unchecked and
believe that over anything else.

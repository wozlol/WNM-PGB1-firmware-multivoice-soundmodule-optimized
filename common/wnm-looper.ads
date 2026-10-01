-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--    The loop recorder/player in this file is a port of the FourTrackLooper --
--    engine from the ARPnMIDI project (arpnmidi3::FourTrackLooper,          --
--    four_track_looper.cpp/.h), treated as the reference for every timing   --
--    and edge case decision there. Keep the two in step rather than         --
--    re-deriving behavior from scratch if either one changes.               --
--                                                                           --
--    The LiveArp engine further down is not from that reference, it is a   --
--    plain arpeggiator. It lives in this same file because its state has   --
--    to live in the same Steps overlay WNM.Looper's own state does (see    --
--    the RAM section of LOOPER_MODE_PLAN.md): there was no room for a      --
--    second, separately addressed overlay without a real risk of the two   --
--    overlapping, so it is a second section of the one overlay instead.    --
--                                                                           --
-------------------------------------------------------------------------------

with HAL; use HAL;
with MIDI;

package WNM.Looper is

   Track_Count : constant := 4;
   type Loop_Track is range 1 .. Track_Count;

   type MIDI_Event is record
      Status : UInt8 := 0;
      Data_1 : UInt8 := 0;
      Data_2 : UInt8 := 0;
   end record;
   --  A bare MIDI status/data1/data2 triplet, with no time of its own: time
   --  is a separate field everywhere this is used, same split as the
   --  reference engine's LoopMidiEvent.atUs plus status/data1/data2.

   function To_Loop_Event (Msg : MIDI.Message) return MIDI_Event;
   function To_MIDI_Message (Event : MIDI_Event) return MIDI.Message;
   --  MIDI.Message has an explicit representation clause matching the wire
   --  format byte for byte (status, data1, data2), the same layout
   --  MIDI_Event already is, so this is a straight reinterpretation, not a
   --  real conversion. Sys messages (clock, start/stop, ...) never reach
   --  here: nothing calls Capture with one, and nothing a looper track
   --  holds should ever need To_MIDI_Message to produce one.

   type Emit_Proc is access procedure (Track : Loop_Track;
                                       At_Us : UInt32;
                                       Event : MIDI_Event);
   type Release_Proc is access procedure (Track : Loop_Track);
   type Held_Note_Proc is access procedure (Track    : Loop_Track;
                                            Channel  : UInt8;
                                            Note     : UInt8;
                                            Velocity : UInt8);

   procedure Reset;

   procedure Select_Track (Track : Loop_Track);
   function Selected_Track return Loop_Track;

   function Track_Has_Content (Track : Loop_Track) return Boolean;

   procedure Arm_Record (Track           : Loop_Track;
                         Fixed_Length_Us : UInt32;
                         Overdub         : Boolean);
   --  Non-destructive: a cleared track keeps its undo material until the
   --  first captured event actually replaces it, so the armed target can
   --  move to another track without losing anything.

   function Begin_Armed_Recording (Now_Us : UInt64) return Boolean;
   --  Whether an armed target is a layer on top of existing audible content
   --  or a replacement is decided here, at the first note, not at arm time:
   --  the armed target may have moved onto a populated track by then.

   procedure Set_Record_Quantize_Us (Quantum_Us : UInt32);

   function Capture (Now_Us : UInt64; Event : MIDI_Event) return Boolean;

   function Finish_Recording (Now_Us : UInt64) return Boolean;
   --  True only if THIS pass captured at least one event. An overdub track
   --  already had content before the pass began, so a plain "track has
   --  content" check cannot tell a pass that added nothing from one that
   --  did not run at all.

   procedure Cancel_Recording;

   function Recording_Armed return Boolean;
   function Recording return Boolean;
   function Overdubbing return Boolean;
   function Recording_Track return Loop_Track;

   procedure Start (Now_Us : UInt64);
   procedure Pause (Now_Us : UInt64; Release : Release_Proc);
   procedure Resume (Now_Us : UInt64);
   procedure Stop (Release : Release_Proc);
   function Playing return Boolean;

   function Resize_Track (Track    : Loop_Track;
                          Length_Us : UInt32;
                          Now_Us    : UInt64;
                          Release   : Release_Proc) return Boolean;

   procedure Tick (Now_Us     : UInt64;
                   Emit       : Emit_Proc;
                   Release    : Release_Proc;
                   Max_Events : Positive := 96);

   procedure Safe_Clear (Track : Loop_Track; Release : Release_Proc);
   --  Non-destructive: hides the track's content rather than freeing it, so
   --  Undo_Clear can still bring it back. Only a later recording over the
   --  same track actually frees the old events.

   procedure Undo_Clear (Track : Loop_Track);
   procedure Permanently_Clear (Track : Loop_Track);
   procedure Clear_All (Release : Release_Proc);

   procedure Set_Muted (Track : Loop_Track; Muted : Boolean;
                        Release : Release_Proc);
   procedure Set_Solo (Track : Loop_Track; Solo : Boolean;
                       Release : Release_Proc);
   function Audible (Track : Loop_Track) return Boolean;

   procedure Collect_Held_Notes (Track : Loop_Track; Fn : Held_Note_Proc);
   --  A track's cursor keeps advancing through its own recorded events every
   --  tick regardless of audibility, so this replays everything the cursor
   --  has already stepped past in the current cycle and reports which notes
   --  are still sounding as of right now. Lets a track regaining audibility
   --  retrigger exactly what it should already be playing.

   function Used_Events return Natural;
   function Free_Events return Natural;
   function Overflow_Count return Natural;
   function Has_Any_Data return Boolean;
   --  True if any track holds content and is not hidden by Safe_Clear. This
   --  is what the Sequencer Mode tab asks before warning that switching
   --  away from Looper mode will lose it.

   function Oldest_Populated_Track return Loop_Track;
   function Newest_Populated_Track return Loop_Track;

   --  Saving and loading a project's loop content. Mirrors the reference
   --  engine's visitEvents/restoreEvent/setRestoredTrackState, minus the
   --  live-import variants (beginImport/importEvent/finishImport), which
   --  exist there to bring in an external take while something may
   --  already be playing. Loading from project storage happens before
   --  anything is playing, so the simpler pair here is enough.

   function Track_Event_Count (Track : Loop_Track) return Natural;

   procedure Visit_Events (Track : Loop_Track; Visit : Emit_Proc);
   --  Calls Visit once per stored event on this track, in order. Reuses
   --  Emit_Proc's shape rather than a new callback type: a save routine
   --  visiting every event is exactly the same shape as the Tick callback
   --  that plays one, just always called.

   function Restore_Event (Track : Loop_Track; At_Us : UInt32;
                           Event : MIDI_Event) return Boolean;
   --  Inserts one event read back from storage. Call Reset first (this
   --  does not clear anything itself), then this once per saved event in
   --  any order (events are kept sorted internally regardless of
   --  insertion order), then Set_Restored_Track_State once per track to
   --  fill in everything an event list alone does not capture.

   procedure Set_Restored_Track_State (Track              : Loop_Track;
                                       Length_Us          : UInt32;
                                       Stored_Length_Us   : UInt32;
                                       Generation         : UInt16;
                                       Muted, Solo, Hidden : Boolean;
                                       Start_Offset_Us    : UInt32 := 0);

   --  The other half of the round trip: reading back everything
   --  Set_Restored_Track_State above takes, so a save routine can get it
   --  in the first place. Not needed for anything but saving, since
   --  playback only ever goes through Tick/Capture/the AUT-driven calls.
   function Track_Length_Us (Track : Loop_Track) return UInt32;
   function Track_Stored_Length_Us (Track : Loop_Track) return UInt32;
   function Track_Generation (Track : Loop_Track) return UInt16;
   function Track_Muted (Track : Loop_Track) return Boolean;
   function Track_Solo (Track : Loop_Track) return Boolean;
   function Track_Hidden (Track : Loop_Track) return Boolean;
   function Track_Start_Offset_Us (Track : Loop_Track) return UInt32;

   --  Icon state shown on the Looper tab, one per track. Matches the four
   --  shapes the UI draws: a hollow square for stopped-with-content, a
   --  filled triangle for playing, a hollow circle for armed, a filled
   --  circle for actively recording or overdubbing.
   type Track_Icon is (Empty, Stopped, Playing_Icon, Armed, Recording_Icon);
   function Icon (Track : Loop_Track) return Track_Icon;

   procedure Play_Tap (Now_Us           : UInt64;
                       Fixed_Length_Us  : UInt32;
                       Release          : Release_Proc;
                       Double_Window_Us : UInt32 := 350_000);
   --  The whole Play button for this mode, on the selected track, per the
   --  spec's state table:
   --
   --    cleared      -> arm
   --    armed        -> unarm
   --    stopped      -> play
   --    playing      -> start overdubbing
   --    overdubbing  -> stop overdubbing, keep playing
   --
   --  and on a second tap inside Double_Window_Us, on the same track:
   --
   --    was playing  -> stop
   --    was stopped  -> clear
   --    was cleared  -> undo the clear
   --
   --  The single tap's action happens immediately rather than being held
   --  back to see whether a second one is coming: waiting would put
   --  350ms of latency on every single tap, which is the one that has to
   --  feel instant. A second tap undoes whatever the first one did and
   --  then applies the double-tap action for the state the first tap saw,
   --  which lands on the same place either way. The state the first tap
   --  saw is remembered here (in the overlay, like everything else in
   --  this package) rather than by the caller.
   --
   --  A clear here is always Safe_Clear, so the double-tap-to-undo above
   --  can still bring it back until something records over it.

   type Bar_Count is range 1 .. 16;
   function Bars (Track : Loop_Track) return Bar_Count;
   procedure Set_Bars (Track : Loop_Track; Bars : Bar_Count; Now_Us : UInt64;
                       Release : Release_Proc);

   type Quantize_Kind is (Off, Q_8, Q_16, Q_32);
   function Quantize (Track : Loop_Track) return Quantize_Kind;
   procedure Set_Quantize (Track : Loop_Track; Q : Quantize_Kind);
   function Quantize_Next (Q : Quantize_Kind) return Quantize_Kind
   is (if Q = Quantize_Kind'Last then Quantize_Kind'First
       else Quantize_Kind'Succ (Q));
   function Img (Q : Quantize_Kind) return String
   is (case Q is
          when Off  => "Off",
          when Q_8  => "1/8",
          when Q_16 => "1/16",
          when Q_32 => "1/32");

   type Auto_Kind is (Auto_Off, Auto_Overdub, Auto_Track, Auto_Arm);
   --  Auto_Off: no automatic behavior when a recording pass auto-ends.
   --  Auto_Overdub: keep overdubbing the same track until it is unarmed.
   --  Auto_Track: switch to the next track when a pass auto-ends.
   --  Auto_Arm: switch to the next track and arm it for the next note.
   function Img (A : Auto_Kind) return String
   is (case A is
          when Auto_Off      => "Off",
          when Auto_Overdub  => "Overdub",
          when Auto_Track    => "Track",
          when Auto_Arm      => "Arm");
   function Auto_Next (A : Auto_Kind) return Auto_Kind
   is (if A = Auto_Kind'Last then Auto_Kind'First else Auto_Kind'Succ (A));

   Menu_Tab_Count : constant := 4;
   type Menu_Tab_Id is range 0 .. Menu_Tab_Count - 1;
   function Menu_Tab return Menu_Tab_Id;
   procedure Set_Menu_Tab (T : Menu_Tab_Id);

   type Menu_Column_Id is range 1 .. 5;
   function Menu_Column return Menu_Column_Id;
   procedure Set_Menu_Column (C : Menu_Column_Id);
   --  Which tab and which of the five columns the Looper menu is showing.
   --  Kept here, in the Steps overlay, instead of as fields on the menu
   --  window itself: a window's fields are permanent RAM whichever mode
   --  is live, and this firmware has none to spare. A plain index rather
   --  than the GUI's own enum so this package stays independent of it.

   function Auto_Setting return Auto_Kind;
   procedure Set_Auto_Setting (Setting : Auto_Kind);
   --  One setting shared by the whole looper, not per track, matching the
   --  single AUT column on the Looper tab. A function and procedure rather
   --  than a plain variable so this, like everything else in this package,
   --  can live in the Steps overlay instead of adding to the permanent RAM
   --  bill outside Looper mode.

   ------------------------------------------------------------------------
   --  LiveArp
   --
   --  A plain arpeggiator, one independent instance per MIDI channel.
   --  Not everything in the spec this was built from yet, by design, see
   --  LOOPER_MODE_PLAN.md: no channel 10 sidecar division, no hold-current-
   --  division-and-tap-another ratchet recorded into the loop, and no
   --  button wiring yet (Set_Style/Set_Division/etc exist to be driven by
   --  UI code that does not exist yet).
   ------------------------------------------------------------------------

   subtype Arp_Channel is MIDI.MIDI_Channel range 1 .. 8;
   --  Matches WNM.Synth's Kick_Channel .. Sample2_Channel, not named from
   --  there directly so this engine does not need to depend on WNM.Synth
   --  for a type alone. The spec says the Chord track never arps; that is
   --  enforced by callers simply never arming Chord_Channel's style, not
   --  by anything inside this engine refusing it.

   type Arp_Style_Kind is (Arp_Off,
                           Arp_Chord,
                           Arp_Up,
                           Arp_Down,
                           Arp_Up_Down_Exclusive,
                           Arp_Up_Down_Inclusive,
                           Arp_Random);
   --  Arp_Chord: every held note together, retriggered each step, not
   --  actually arpeggiated note by note (the spec calls this style
   --  "trigger/chord").
   --  Arp_Up_Down_Exclusive: ping-pongs without repeating the top or
   --  bottom note (for notes C E G: C E G E C E G E ...).
   --  Arp_Up_Down_Inclusive: ping-pongs repeating both ends
   --  (C E G G E C C E G G ...).

   function Img (S : Arp_Style_Kind) return String
   is (case S is
          when Arp_Off               => "Off",
          when Arp_Chord             => "Chord",
          when Arp_Up                => "Up",
          when Arp_Down              => "Down",
          when Arp_Up_Down_Exclusive => "Up/Down 1",
          when Arp_Up_Down_Inclusive => "Up/Down 2",
          when Arp_Random            => "Random");

   type Arp_Division_Kind is (D_1_4, D_1_2T, D_1_8, D_1_4T,
                              D_1_16, D_1_8T, D_1_32, D_1_64);
   --  "T" divisions are the triplet of the one before them (2/3 the
   --  straight duration: 3 of them fill the time 2 straight ones would),
   --  matching the spec's listed order.

   function Img (D : Arp_Division_Kind) return String
   is (case D is
          when D_1_4  => "1/4",
          when D_1_2T => "1/2t",
          when D_1_8  => "1/8",
          when D_1_4T => "1/4t",
          when D_1_16 => "1/16",
          when D_1_8T => "1/8t",
          when D_1_32 => "1/32",
          when D_1_64 => "1/64");

   function Division_Us (D : Arp_Division_Kind; Beat_Us : UInt32)
                         return UInt32;
   --  Beat_Us is one quarter note (what the rest of this firmware already
   --  calls Microseconds_Per_Beat).

   function Arp_Style (Channel : Arp_Channel) return Arp_Style_Kind;
   procedure Set_Arp_Style (Channel : Arp_Channel; S : Arp_Style_Kind);

   function Arp_Division (Channel : Arp_Channel) return Arp_Division_Kind;
   procedure Set_Arp_Division (Channel : Arp_Channel; D : Arp_Division_Kind);

   function Arp_Octave_Down (Channel : Arp_Channel) return Boolean;
   function Arp_Octave_Up (Channel : Arp_Channel) return Boolean;
   procedure Set_Arp_Octave_Down (Channel : Arp_Channel; On : Boolean);
   procedure Set_Arp_Octave_Up (Channel : Arp_Channel; On : Boolean);
   --  Each adds a second note sounding together with whatever the style
   --  would already be sounding, one octave down or up (clamped to the
   --  MIDI note range rather than wrapping).

   type Arp_Emit_Proc is access procedure (Channel  : Arp_Channel;
                                           Key      : MIDI.MIDI_Key;
                                           Velocity : MIDI.MIDI_Data;
                                           Note_On  : Boolean);

   procedure Arp_Note_On (Channel  : Arp_Channel;
                          Key      : MIDI.MIDI_Key;
                          Velocity : MIDI.MIDI_Data);
   procedure Arp_Note_Off (Channel : Arp_Channel; Key : MIDI.MIDI_Key;
                           Emit    : Arp_Emit_Proc := null);
   --  Feeds the held-note set the stepper below walks. Whether a given
   --  Note_On/Off even reaches here instead of going straight to the
   --  synth is the caller's decision (Arp_Style (Channel) /= Arp_Off),
   --  not this engine's: it has no opinion on anything but the channels
   --  that are actually armed.
   --
   --  Arp_Note_Off's Emit, if given, is called to silence whatever this
   --  channel was last sounding the instant its last held note is
   --  released, rather than leaving it ringing until Arp_Tick's next
   --  step happens to notice the held set emptied out (which could be a
   --  noticeable delay at a slow division). Passing null keeps the old
   --  behavior.

   procedure Arp_Reset (Channel : Arp_Channel;
                        Emit    : Arp_Emit_Proc := null);
   --  Drops all held notes and stops the stepper. Used when a style or
   --  channel selection changes out from under held notes. Emit, if
   --  given, sends the note-offs for whatever this channel was last
   --  sounding, which is the only way they go out at all: nothing
   --  outside this engine knows what the stepper picked. Passing null
   --  leaves them ringing.

   ------------------------------------------------------------------------
   --  Stutter and dub delay
   --
   --  Both are global, across all tracks at once, per the spec. The
   --  stutter is a port of ARPnMIDI's RollingHistory/HistoryRepeater
   --  (rolling_history.cpp): every note that actually sounds goes into a
   --  ring buffer, and starting the stutter snapshots the last N
   --  microseconds of that and loops it until released. The dub delay is
   --  not from that reference: each incoming note schedules three repeats
   --  at the chosen division with the velocity coming down each time.
   ------------------------------------------------------------------------

   type Event_Emit_Proc is access procedure (Event : MIDI_Event);

   procedure History_Push (Now_Us : UInt64; Event : MIDI_Event);
   --  Call for every event that actually reaches the synth, whatever
   --  produced it (live playing, loop playback, the arp). Not for the
   --  stutter's or the delay's own output, or they would feed back into
   --  what they are repeating.

   type Stutter_Division_Kind is (S_1, S_1_2, S_1_4, S_2T,
                                  S_1_8, S_4T, S_1_16, S_1_32);
   --  The spec's own list for the stutter's eight buttons, which is not
   --  the same list the arp and the delay use. S_1 is one bar; the
   --  reference engine's comment says a stutter never needs longer.

   function Img (D : Stutter_Division_Kind) return String
   is (case D is
          when S_1    => "1",
          when S_1_2  => "1/2",
          when S_1_4  => "1/4",
          when S_2T   => "2t",
          when S_1_8  => "1/8",
          when S_4T   => "4t",
          when S_1_16 => "1/16",
          when S_1_32 => "1/32");

   function Stutter_Length_Us (D : Stutter_Division_Kind; Beat_Us : UInt32)
                               return UInt32;

   function Stutter_Active return Boolean;

   procedure Stutter_Start (Now_Us  : UInt64;
                            D       : Stutter_Division_Kind;
                            Beat_Us : UInt32);
   --  Momentary: snapshots the history window ending now and starts
   --  looping it. Does nothing if that window holds no events (there is
   --  nothing to repeat), so holding a stutter button in silence is not a
   --  way to get stuck.

   procedure Stutter_Stop (Emit : Event_Emit_Proc);
   --  Releases anything the stutter still has sounding, so letting go of
   --  the button cannot leave a note on.

   procedure Stutter_Tick (Now_Us : UInt64; Emit : Event_Emit_Proc;
                           Max_Events : Positive := 48);

   function Delay_Active return Boolean;
   function Delay_Division return Arp_Division_Kind;
   procedure Set_Delay (D : Arp_Division_Kind; On : Boolean);
   --  Latching rather than momentary, per the spec. Uses the standard
   --  divisions, the same list the arp does.

   Delay_Repeats : constant := 3;

   procedure Delay_Note (Now_Us  : UInt64;
                         Event   : MIDI_Event;
                         Beat_Us : UInt32);
   --  Schedules this note's repeats, if the delay is on and this is a
   --  note on. Ignores anything else.

   procedure Delay_Tick (Now_Us : UInt64; Emit : Event_Emit_Proc);

   procedure Clear_Effects (Emit : Event_Emit_Proc);
   --  Silences and forgets both of the above. For leaving Looper mode or
   --  stopping the transport, so neither can keep playing into whatever
   --  comes next.

   procedure Arp_Tick (Now_Us : UInt64; Beat_Us : UInt32;
                       Emit   : Arp_Emit_Proc);
   --  Steps every channel whose style is not Arp_Off and whose division
   --  interval has elapsed since its last step: stops whatever that
   --  channel was sounding and starts the next note per its style. A
   --  channel with no held notes is silently skipped (nothing to step
   --  through), so this is safe to call unconditionally every tick.

private

   --  The event pool lives on top of the step sequencer's own Steps
   --  storage (G_Project.Steps, see WNM.Project), which this mode has no
   --  other use for. Active only while Sequencer_Mode is Four_Track_Looper;
   --  switching back to OG_Sequencer overwrites it with fresh step data, so
   --  the two can never be live at the same time. The Sequencer Mode menu
   --  enforces that by warning and clearing whichever side is about to be
   --  overwritten before the switch happens.

end WNM.Looper;

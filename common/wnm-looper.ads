-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--    This file is a port of the FourTrackLooper engine from the ARPnMIDI    --
--    project (arpnmidi3::FourTrackLooper, four_track_looper.cpp/.h),       --
--    treated as the reference for every timing and edge case decision      --
--    here. Keep the two in step rather than re-deriving behavior from      --
--    scratch if either one changes.                                        --
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

   function Auto_Setting return Auto_Kind;
   procedure Set_Auto_Setting (Setting : Auto_Kind);
   --  One setting shared by the whole looper, not per track, matching the
   --  single AUT column on the Looper tab. A function and procedure rather
   --  than a plain variable so this, like everything else in this package,
   --  can live in the Steps overlay instead of adding to the permanent RAM
   --  bill outside Looper mode.

private

   --  The event pool lives on top of the step sequencer's own Steps
   --  storage (G_Project.Steps, see WNM.Project), which this mode has no
   --  other use for. Active only while Sequencer_Mode is Four_Track_Looper;
   --  switching back to OG_Sequencer overwrites it with fresh step data, so
   --  the two can never be live at the same time. The Sequencer Mode menu
   --  enforces that by warning and clearing whichever side is about to be
   --  overwritten before the switch happens.

end WNM.Looper;

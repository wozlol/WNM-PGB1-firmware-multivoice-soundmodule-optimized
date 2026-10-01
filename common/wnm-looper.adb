-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--    Port of arpnmidi3::FourTrackLooper. See the spec in wnm-looper.ads.   --
--                                                                           --
-------------------------------------------------------------------------------

with Ada.Unchecked_Conversion;
with System;

with WNM.Project;

package body WNM.Looper is

   use type MIDI.MIDI_UInt8;

   -----------------
   -- Event pool  --
   -----------------

   Pool_Size : constant := 4000;
   --  The Steps overlay holds 4437 slots (53248 bytes / 12 bytes a slot,
   --  both read off a -gnatR2 dump rather than hand-counted). Sized below
   --  that deliberately: the rest of the room goes to the stutter's
   --  rolling history and the dub delay's pending events further down,
   --  which have nowhere else to live. Still 30% more loop capacity than
   --  the reference engine's own 3072. The assertion below catches a bad
   --  estimate either way instead of silently overlapping real data.

   type Slot_Ref is range 0 .. Pool_Size;
   subtype Slot_Index is Slot_Ref range 0 .. Pool_Size - 1;
   No_Slot : constant Slot_Ref := Pool_Size;

   type Loop_Slot is record
      At_Us : UInt32   := 0;
      Event : MIDI_Event;
      Next  : Slot_Ref := No_Slot;
   end record;

   type Slot_Array is array (Slot_Index) of Loop_Slot;

   ------------------
   -- Track state  --
   ------------------

   subtype Event_Count is Natural range 0 .. Pool_Size;

   type Track_State is record
      Head, Tail, Play_Cursor : Slot_Ref := No_Slot;
      Count              : Event_Count := 0;
      Length_Us          : UInt32  := 0;
      Stored_Length_Us   : UInt32  := 0;
      Generation         : UInt16  := 0;
      Cycle_Start_Us     : UInt64  := 0;
      Paused_Position_Us : UInt32  := 0;
      Start_Offset_Us    : UInt32  := 0;
      --  Where this track's own cycle begins inside the shared transport
      --  cycle. A layer started partway through the others keeps that
      --  relationship across stop, clear, undo and play again.
      Muted, Solo, Hidden : Boolean := False;
      Importing           : Boolean := False;
      Bars                : Bar_Count     := 1;
      Quant               : Quantize_Kind := Off;
   end record
     with Pack;
   --  Packed because there are only 4 of these, so the layout cost of
   --  tight bit-packing is paid once and the RAM saved (roughly a third,
   --  measured) goes straight to the one thing that actually scales with
   --  how much gets played: the event pool above.

   type Track_Array is array (Loop_Track) of Track_State;

   --  The track's own event count at the instant THIS pass actually started
   --  recording. A plain count-nonzero check is right for a replacement,
   --  which always starts from zero, but wrong for an overdub, where the
   --  track already had content before the pass began. (Comment kept with
   --  the type below since Record_Start_Count is now a field, not a plain
   --  variable.)

   --  A dense 16-channel by 128-note grid is the obvious way to track which
   --  notes are down, but costs 2048 bytes a copy and this needs two
   --  copies (one for the recording-time close-on-stop bookkeeping, one
   --  for Collect_Held_Notes's own scratch). Real polyphony is nowhere
   --  near 2048 notes at once, so a small bounded table of the actually-
   --  held notes does the same job in a sixteenth of the space.

   Max_Tracked_Notes : constant := 16;
   --  Generous for anything a groovebox's worth of live playing and loop
   --  tracks will actually hold down at once. If this is ever exceeded,
   --  the overflow note is simply not tracked (Held_Set below says so).

   type Held_Entry is record
      Channel  : UInt8    := 0;
      Note     : UInt8    := 0;
      Velocity : UInt8    := 0;
      Used     : Boolean  := False;
   end record;
   type Held_Table is array (1 .. Max_Tracked_Notes) of Held_Entry;

   procedure Held_Reset (Table : in out Held_Table) is
   begin
      Table := (others => <>);
   end Held_Reset;

   procedure Held_Set (Table : in out Held_Table; Channel, Note, Velocity : UInt8)
   is
   begin
      for E of Table loop
         if E.Used and then E.Channel = Channel and then E.Note = Note then
            E.Velocity := Velocity;
            return;
         end if;
      end loop;
      for E of Table loop
         if not E.Used then
            E := (Channel => Channel, Note => Note, Velocity => Velocity,
                 Used => True);
            return;
         end if;
      end loop;
      --  Table full: this note is not tracked. See Max_Tracked_Notes.
   end Held_Set;

   function Held_Is_Set (Table : Held_Table; Channel, Note : UInt8)
                         return Boolean
   is
   begin
      for E of Table loop
         if E.Used and then E.Channel = Channel and then E.Note = Note then
            return True;
         end if;
      end loop;
      return False;
   end Held_Is_Set;

   procedure Held_Clear (Table : in out Held_Table; Channel, Note : UInt8) is
   begin
      for E of Table loop
         if E.Used and then E.Channel = Channel and then E.Note = Note then
            E.Used := False;
            return;
         end if;
      end loop;
   end Held_Clear;

   --  Held_Scratch is reused by Collect_Held_Notes rather than put on the
   --  stack: it is not reentrant, matching the one call site this is meant
   --  for.

   ---------------------------------
   -- LiveArp's own state         --
   ---------------------------------

   Arp_Max_Notes : constant := 6;
   --  Smaller than Max_Tracked_Notes above on purpose: this is per
   --  channel, 8 of these, inside the same overlay as everything else
   --  here, and 6 simultaneously held notes on one channel during live
   --  arp play is already generous.

   type Arp_Note_Entry is record
      Key      : MIDI.MIDI_Key  := 0;
      Velocity : MIDI.MIDI_Data := 0;
      Used     : Boolean        := False;
   end record
     with Pack;
   type Arp_Note_Table is array (1 .. Arp_Max_Notes) of Arp_Note_Entry;

   procedure Arp_Table_Set (Table : in out Arp_Note_Table;
                           Key   :        MIDI.MIDI_Key;
                           Velocity : MIDI.MIDI_Data)
   is
   begin
      for E of Table loop
         if E.Used and then E.Key = Key then
            E.Velocity := Velocity;
            return;
         end if;
      end loop;
      for E of Table loop
         if not E.Used then
            E := (Key => Key, Velocity => Velocity, Used => True);
            return;
         end if;
      end loop;
      --  Table full: this note is not tracked. See Arp_Max_Notes.
   end Arp_Table_Set;

   procedure Arp_Table_Clear (Table : in out Arp_Note_Table;
                             Key   :        MIDI.MIDI_Key)
   is
   begin
      for E of Table loop
         if E.Used and then E.Key = Key then
            E.Used := False;
            return;
         end if;
      end loop;
   end Arp_Table_Clear;

   type Arp_Channel_State is record
      Style        : Arp_Style_Kind    := Arp_Off;
      Division     : Arp_Division_Kind := D_1_16;
      Octave_Down  : Boolean           := False;
      Octave_Up    : Boolean           := False;
      Held         : Arp_Note_Table    := (others => <>);
      Sounding     : Arp_Note_Table    := (others => <>);
      --  What this channel is sounding as of the last step, so the next
      --  step knows what to turn off before turning the next thing on.
      Step_Index   : Natural           := 0;
      Last_Step_Us : UInt64            := 0;
      Has_Stepped  : Boolean           := False;
      --  False until this channel's first step, so that first step
      --  happens immediately rather than waiting a full division.
   end record
     with Pack;

   type Arp_Channel_Array is array (Arp_Channel) of Arp_Channel_State;

   ---------------------------------
   -- Stutter and delay state     --
   ---------------------------------

   History_Capacity : constant := 128;
   --  The reference engine keeps 2048 of these. This has the Steps
   --  overlay's leftovers to work with instead, so it keeps the most
   --  recent 128 events and drops the oldest past that. A stutter window
   --  longer and busier than 128 events (a full bar of 1/32 arp across
   --  several channels) repeats only the newest 128 of it, which thins
   --  out rather than breaking.

   Delay_Pending_Capacity : constant := 48;
   --  Three repeats, each needing an on and an off, so this holds eight
   --  notes' worth of repeats in flight at once.

   type Timed_Event is record
      At_Us : UInt32 := 0;
      --  The low 32 bits of the microsecond clock, not the full 64. All
      --  this is ever used for is differences over a window of at most a
      --  bar or two, and unsigned subtraction stays correct across the
      --  wrap, so the top half is not worth the bytes.
      Event : MIDI_Event;
   end record
     with Pack;

   type History_Array is array (0 .. History_Capacity - 1) of Timed_Event;
   type Delay_Array is array (1 .. Delay_Pending_Capacity) of Timed_Event;

   type Delay_Slot_Used is array (1 .. Delay_Pending_Capacity) of Boolean
     with Pack;

   type Effects_State is record
      History       : History_Array;
      History_Next  : Natural;
      --  Where the next push goes, wrapping. Plain ring buffer with a
      --  count rather than the reference's monotonic sequence numbers and
      --  binary search: at 128 entries a linear scan is nothing, and it
      --  saves four bytes a slot.
      History_Count : Natural;

      Stutter_On         : Boolean;
      Stutter_Cursor     : Natural;
      --  How many of the captured window's events have been emitted in
      --  the current repeat, so a tick never re-emits what an earlier
      --  tick in the same repeat already did. The reference engine keeps
      --  a snapshot cursor for exactly this; relying on the sounding
      --  table instead does not work, because a note-on has to be able
      --  to retrigger a note that is already on.
      Stutter_Length_Us  : UInt32;
      Stutter_Cycle_Us   : UInt32;
      --  Start of the current repeat cycle, same clipped 32-bit clock.
      Stutter_Window_Us  : UInt32;
      --  Start of the captured window, so replay can turn each event's
      --  absolute stamp into an offset within the loop.
      Stutter_Sounding   : Held_Table;
      --  What the stutter currently has on, so a wrap or a release can
      --  put every one of them back down. Without this a repeating note
      --  on sticks forever, which is what the reference's own
      --  emitNoteSafe exists to prevent.

      Delay_On       : Boolean;
      Delay_Div      : Arp_Division_Kind;
      Delay_Pending  : Delay_Array;
      Delay_Used     : Delay_Slot_Used;
   end record
     with Pack;

   ---------------------------------
   -- The engine's whole overlay  --
   ---------------------------------

   --  Every byte of this engine's state, the event pool and its own small
   --  bookkeeping alike, lives on top of the step sequencer's storage
   --  rather than adding to the firmware's permanent RAM bill. None of it
   --  means anything outside Four_Track_Looper mode, so none of it should
   --  cost anything outside that mode either. WNM.Looper.Reset (always
   --  called by the Sequencer Mode menu before this mode becomes active)
   --  writes every field here before anything reads one, so starting from
   --  whatever garbage the overlaid memory happens to hold is safe.
   --
   --  Every reference past this point is Overlay_Ptr.Field rather than a
   --  bare name. A rename per field was tried first (more RAM than this
   --  consolidation was supposed to save) and then a single stored object
   --  pointer (still 4 bytes this firmware did not have), see the comment
   --  by Overlay_Ptr below for what this settled on.

   type Looper_Overlay is record
      Event_Pool : Slot_Array;

      Tracks : Track_Array;

      Free_Head          : Slot_Ref;
      Used_Count         : Event_Count;
      Overflow           : Natural;
      Generation_Counter : UInt16;

      Transport_Start_Us     : UInt64;
      Record_Start_Us        : UInt64;
      Record_Fixed_Length_Us : UInt32;
      Record_Quantize_Us     : UInt32;

      Selected      : Loop_Track;
      Recording_Trk : Loop_Track;

      Is_Playing, Is_Paused            : Boolean;
      Is_Recording_Armed, Is_Recording : Boolean;
      Is_Overdubbing                   : Boolean;
      Record_Start_Count               : Event_Count;

      Record_Held  : Held_Table;
      Held_Scratch : Held_Table;

      Auto_Setting : Auto_Kind;

      --  Play button double-tap memory, see Play_Tap. Here rather than in
      --  the caller because this is the one place with RAM to spare.
      Play_Tap_Us    : UInt64;
      Play_Tap_Track : Loop_Track;
      Play_Tap_Icon  : Track_Icon;
      Play_Tap_Valid : Boolean;

      Arp       : Arp_Channel_Array;
      Arp_Seed  : UInt32;

      FX : Effects_State;
      --  A plain LCG seed for Arp_Random, not anything cryptographic:
      --  just needs to not repeat obviously over a few bars.
   end record
     with Volatile, Alignment => 1;
   --  All_Steps_Arr itself is only 1-byte aligned (it is a packed array, so
   --  it offers no stronger guarantee), and this overlays onto it. Without
   --  forcing this down from the 8 its UInt64 fields would otherwise ask
   --  for, the compiler assumes an 8-byte-aligned source and this is on an
   --  ARMv6-M core, which faults on unaligned multi-byte access rather than
   --  quietly handling it the way some other ARM cores do. Relaxing this
   --  makes the compiler emit alignment-safe access code for every field
   --  instead of trusting that Steps happens to land on an 8-byte boundary.

   pragma Compile_Time_Error
     (Looper_Overlay'Size > WNM.Project.Steps_Storage_Bytes * 8,
      "Looper_Overlay does not fit the Steps overlay, shrink Pool_Size");

   type Looper_Overlay_Access is access all Looper_Overlay;

   --  Not a package-level object with an Address aspect: that needs its own
   --  stored pointer (4 bytes), and this firmware had only 4 bytes of RAM
   --  to spare before this engine existed at all. Computing the address
   --  fresh from the already-static Steps_Storage_Address on every call
   --  costs nothing in RAM, trading a handful of flash bytes and one extra
   --  instruction per access for it. Every reference past this point reads
   --  Overlay_Ptr.Field where Overlay.Field used to be.

   function Overlay_Ptr return not null Looper_Overlay_Access is
      function To_Access is new Ada.Unchecked_Conversion
        (System.Address, Looper_Overlay_Access);
   begin
      return To_Access (WNM.Project.Steps_Storage_Address);
   end Overlay_Ptr;

   --  No renames here: GNAT materializes a stored address for each rename
   --  of a component of an Import/Address object (one 4-byte pointer per
   --  name), rather than reusing Overlay's own address with a static
   --  offset the way a plain Overlay_Ptr.Field access does. Measured: renaming
   --  all of these the obvious way cost more RAM than this whole engine's
   --  bookkeeping was supposed to save. Every reference below is written
   --  as Overlay_Ptr.Field instead.

   --------------------
   -- To_Loop_Event  --
   --------------------

   function To_Loop_Event (Msg : MIDI.Message) return MIDI_Event is
      function Convert is new Ada.Unchecked_Conversion
        (MIDI.Message, MIDI_Event);
   begin
      return Convert (Msg);
   end To_Loop_Event;

   ---------------------
   -- To_MIDI_Message --
   ---------------------

   function To_MIDI_Message (Event : MIDI_Event) return MIDI.Message is
      function Convert is new Ada.Unchecked_Conversion
        (MIDI_Event, MIDI.Message);
   begin
      return Convert (Event);
   end To_MIDI_Message;

   function Status_Type (Status : UInt8) return UInt8
   is (Status and 16#F0#);
   function Status_Channel (Status : UInt8) return UInt8
   is (Status and 16#0F#);

   procedure Free_Slot (Slot : Slot_Ref);
   procedure Capture_Track_Phase (Track : Loop_Track);
   procedure Seek_Track_To (State               : in out Track_State;
                           Now_Us               :        UInt64;
                           Position_Us          :        UInt32;
                           Skip_Events_At_Position : Boolean);
   procedure Reset_Playback_Cursors (Now_Us : UInt64);
   procedure Close_Held_Recording_Notes (Boundary_Us : UInt32);
   function Insert_Event (Track : Loop_Track; At_Us : UInt32;
                          Event : MIDI_Event) return Boolean;
   procedure Release_If_Audibility_Changed (Track      : Loop_Track;
                                           Was_Audible : Boolean;
                                           Release     : Release_Proc);

   -----------
   -- Reset --
   -----------

   procedure Reset is
   begin
      for I in Slot_Index loop
         Overlay_Ptr.Event_Pool (I) := (At_Us => 0,
                            Event => (others => <>),
                            Next  => (if I < Slot_Index'Last
                                      then I + 1 else No_Slot));
      end loop;
      Overlay_Ptr.Tracks := (others => (others => <>));
      Overlay_Ptr.Free_Head := 0;
      Overlay_Ptr.Used_Count := 0;
      Overlay_Ptr.Overflow := 0;
      Overlay_Ptr.Generation_Counter := 0;
      Overlay_Ptr.Transport_Start_Us := 0;
      Overlay_Ptr.Record_Start_Us := 0;
      Overlay_Ptr.Record_Fixed_Length_Us := 0;
      Overlay_Ptr.Record_Quantize_Us := 0;
      Overlay_Ptr.Selected := Loop_Track'First;
      Overlay_Ptr.Recording_Trk := Loop_Track'First;
      Overlay_Ptr.Is_Playing := False;
      Overlay_Ptr.Is_Paused := False;
      Overlay_Ptr.Is_Recording_Armed := False;
      Overlay_Ptr.Is_Recording := False;
      Overlay_Ptr.Is_Overdubbing := False;
      Overlay_Ptr.Record_Start_Count := 0;
      Overlay_Ptr.Auto_Setting := Auto_Off;
      Overlay_Ptr.Play_Tap_Us := 0;
      Overlay_Ptr.Play_Tap_Track := Loop_Track'First;
      Overlay_Ptr.Play_Tap_Icon := Empty;
      Overlay_Ptr.Play_Tap_Valid := False;
      Held_Reset (Overlay_Ptr.Record_Held);
      Overlay_Ptr.Arp := (others => (others => <>));
      Overlay_Ptr.Arp_Seed := 12345;

      Overlay_Ptr.FX.History_Next := 0;
      Overlay_Ptr.FX.History_Count := 0;
      Overlay_Ptr.FX.Stutter_On := False;
      Overlay_Ptr.FX.Stutter_Cursor := 0;
      Overlay_Ptr.FX.Stutter_Length_Us := 0;
      Overlay_Ptr.FX.Stutter_Cycle_Us := 0;
      Overlay_Ptr.FX.Stutter_Window_Us := 0;
      Held_Reset (Overlay_Ptr.FX.Stutter_Sounding);
      Overlay_Ptr.FX.Delay_On := False;
      Overlay_Ptr.FX.Delay_Div := D_1_8;
      Overlay_Ptr.FX.Delay_Used := (others => False);
      --  History contents are left alone: every slot past History_Count
      --  is unreachable, and the ones inside it are overwritten before
      --  they are read.
   end Reset;

   -------------------
   -- Allocate_Slot --
   -------------------

   function Allocate_Slot return Slot_Ref is
      Slot : Slot_Ref;
   begin
      if Overlay_Ptr.Free_Head = No_Slot then
         Overlay_Ptr.Overflow := Overlay_Ptr.Overflow + 1;
         return No_Slot;
      end if;
      Slot := Overlay_Ptr.Free_Head;
      Overlay_Ptr.Free_Head := Overlay_Ptr.Event_Pool (Slot).Next;
      Overlay_Ptr.Event_Pool (Slot).Next := No_Slot;
      Overlay_Ptr.Used_Count := Overlay_Ptr.Used_Count + 1;
      return Slot;
   end Allocate_Slot;

   ---------------
   -- Free_Slot --
   ---------------

   procedure Free_Slot (Slot : Slot_Ref) is
   begin
      if Slot = No_Slot then
         return;
      end if;
      Overlay_Ptr.Event_Pool (Slot) := (At_Us => 0, Event => (others => <>),
                            Next => Overlay_Ptr.Free_Head);
      Overlay_Ptr.Free_Head := Slot;
      if Overlay_Ptr.Used_Count > 0 then
         Overlay_Ptr.Used_Count := Overlay_Ptr.Used_Count - 1;
      end if;
   end Free_Slot;

   ------------------
   -- Insert_Event --
   ------------------

   function Insert_Event (Track : Loop_Track; At_Us : UInt32;
                          Event : MIDI_Event) return Boolean
   is
      Slot : constant Slot_Ref := Allocate_Slot;
      State : Track_State renames Overlay_Ptr.Tracks (Track);
   begin
      if Slot = No_Slot then
         return False;
      end if;
      Overlay_Ptr.Event_Pool (Slot).At_Us := At_Us;
      Overlay_Ptr.Event_Pool (Slot).Event := Event;
      Overlay_Ptr.Event_Pool (Slot).Next := No_Slot;

      if State.Head = No_Slot then
         State.Head := Slot;
         State.Tail := Slot;
      elsif Overlay_Ptr.Event_Pool (State.Tail).At_Us <= At_Us then
         Overlay_Ptr.Event_Pool (State.Tail).Next := Slot;
         State.Tail := Slot;
      elsif At_Us < Overlay_Ptr.Event_Pool (State.Head).At_Us then
         Overlay_Ptr.Event_Pool (Slot).Next := State.Head;
         State.Head := Slot;
      else
         declare
            Prev : Slot_Ref := State.Head;
         begin
            while Overlay_Ptr.Event_Pool (Prev).Next /= No_Slot
              and then Overlay_Ptr.Event_Pool (Overlay_Ptr.Event_Pool (Prev).Next).At_Us <= At_Us
            loop
               Prev := Overlay_Ptr.Event_Pool (Prev).Next;
            end loop;
            Overlay_Ptr.Event_Pool (Slot).Next := Overlay_Ptr.Event_Pool (Prev).Next;
            Overlay_Ptr.Event_Pool (Prev).Next := Slot;
         end;
      end if;
      State.Count := State.Count + 1;
      return True;
   end Insert_Event;

   ------------------
   -- Select_Track --
   ------------------

   procedure Select_Track (Track : Loop_Track) is
   begin
      Overlay_Ptr.Selected := Track;
   end Select_Track;

   function Selected_Track return Loop_Track is (Overlay_Ptr.Selected);

   ------------------------
   -- Track_Has_Content  --
   ------------------------

   function Track_Has_Content (Track : Loop_Track) return Boolean
   is (Overlay_Ptr.Tracks (Track).Count > 0 and then not Overlay_Ptr.Tracks (Track).Hidden);

   -----------------
   -- Arm_Record  --
   -----------------

   procedure Arm_Record (Track           : Loop_Track;
                         Fixed_Length_Us : UInt32;
                         Overdub         : Boolean)
   is
   begin
      Overlay_Ptr.Recording_Trk := Track;
      Overlay_Ptr.Selected := Track;
      Overlay_Ptr.Record_Fixed_Length_Us := Fixed_Length_Us;
      Overlay_Ptr.Is_Recording_Armed := not Overdub;
      Overlay_Ptr.Is_Recording := Overdub;
      Overlay_Ptr.Is_Overdubbing := Overdub;
      Overlay_Ptr.Record_Start_Us := (if Overdub then Overlay_Ptr.Transport_Start_Us else 0);
      if Overdub then
         Overlay_Ptr.Record_Start_Count := Overlay_Ptr.Tracks (Track).Count;
      end if;
      Held_Reset (Overlay_Ptr.Record_Held);
      if Overdub then
         Overlay_Ptr.Generation_Counter := Overlay_Ptr.Generation_Counter + 1;
         Overlay_Ptr.Tracks (Track).Generation := Overlay_Ptr.Generation_Counter;
      end if;
   end Arm_Record;

   ----------------------------
   -- Begin_Armed_Recording  --
   ----------------------------

   function Begin_Armed_Recording (Now_Us : UInt64) return Boolean is
      State : Track_State renames Overlay_Ptr.Tracks (Overlay_Ptr.Recording_Trk);
   begin
      if not Overlay_Ptr.Is_Recording_Armed then
         return False;
      end if;
      Overlay_Ptr.Is_Recording_Armed := False;
      Overlay_Ptr.Is_Recording := True;
      Overlay_Ptr.Is_Overdubbing := Overlay_Ptr.Is_Playing and then State.Length_Us > 0
        and then State.Count > 0 and then not State.Hidden;
      if Overlay_Ptr.Is_Overdubbing then
         Overlay_Ptr.Record_Start_Us := Overlay_Ptr.Transport_Start_Us;
         Overlay_Ptr.Record_Start_Count := State.Count;
      else
         Overlay_Ptr.Record_Start_Us := Now_Us;
         Permanently_Clear (Overlay_Ptr.Recording_Trk);
         Overlay_Ptr.Record_Start_Count := 0;
      end if;
      Overlay_Ptr.Generation_Counter := Overlay_Ptr.Generation_Counter + 1;
      Overlay_Ptr.Tracks (Overlay_Ptr.Recording_Trk).Generation := Overlay_Ptr.Generation_Counter;
      return True;
   end Begin_Armed_Recording;

   ----------------------------
   -- Set_Record_Quantize_Us --
   ----------------------------

   procedure Set_Record_Quantize_Us (Quantum_Us : UInt32) is
   begin
      Overlay_Ptr.Record_Quantize_Us := Quantum_Us;
   end Set_Record_Quantize_Us;

   -------------
   -- Capture --
   -------------

   function Capture (Now_Us : UInt64; Event : MIDI_Event) return Boolean is
      Note_On : constant Boolean :=
        Status_Type (Event.Status) = 16#90# and then Event.Data_2 > 0;
      At_Us : UInt32;
   begin
      if Overlay_Ptr.Is_Recording_Armed then
         if not Note_On then
            return False;
         end if;
         if not Begin_Armed_Recording (Now_Us) then
            return False;
         end if;
      end if;
      if not Overlay_Ptr.Is_Recording then
         return False;
      end if;

      declare
         State : Track_State renames Overlay_Ptr.Tracks (Overlay_Ptr.Recording_Trk);
      begin
         if Overlay_Ptr.Is_Overdubbing and then Overlay_Ptr.Is_Playing and then State.Length_Us > 0
         then
            At_Us := UInt32 ((Now_Us - State.Cycle_Start_Us)
                             mod UInt64 (State.Length_Us));
         else
            declare
               Elapsed : constant UInt64 := Now_Us - Overlay_Ptr.Record_Start_Us;
            begin
               if Overlay_Ptr.Record_Fixed_Length_Us > 0
                 and then Elapsed >= UInt64 (Overlay_Ptr.Record_Fixed_Length_Us)
               then
                  return False;
               end if;
               At_Us := UInt32 (Elapsed);
            end;
         end if;

         if Overlay_Ptr.Record_Quantize_Us > 0 then
            At_Us := UInt32 ((UInt64 (At_Us) + UInt64 (Overlay_Ptr.Record_Quantize_Us) / 2)
                             / UInt64 (Overlay_Ptr.Record_Quantize_Us))
                     * Overlay_Ptr.Record_Quantize_Us;
            declare
               Limit : constant UInt32 :=
                 (if Overlay_Ptr.Is_Overdubbing then State.Length_Us
                  else Overlay_Ptr.Record_Fixed_Length_Us);
            begin
               if Limit > 0 and then At_Us >= Limit then
                  At_Us := Limit - 1;
               end if;
            end;
         end if;

         if not Insert_Event (Overlay_Ptr.Recording_Trk, At_Us, Event) then
            return False;
         end if;

         if Status_Type (Event.Status) = 16#90#
           or else Status_Type (Event.Status) = 16#80#
         then
            if Note_On then
               Held_Set (Overlay_Ptr.Record_Held, Status_Channel (Event.Status),
                        Event.Data_1, Event.Data_2);
            else
               Held_Clear (Overlay_Ptr.Record_Held, Status_Channel (Event.Status),
                          Event.Data_1);
            end if;
         end if;
         return True;
      end;
   end Capture;

   --------------------------------
   -- Close_Held_Recording_Notes --
   --------------------------------

   procedure Close_Held_Recording_Notes (Boundary_Us : UInt32) is
   begin
      for E of Overlay_Ptr.Record_Held loop
         if E.Used then
            declare
               Dummy : constant Boolean :=
                 Insert_Event (Overlay_Ptr.Recording_Trk, Boundary_Us,
                              (Status => 16#80# + E.Channel,
                               Data_1 => E.Note,
                               Data_2 => 0));
            begin
               null;
            end;
         end if;
      end loop;
      Held_Reset (Overlay_Ptr.Record_Held);
   end Close_Held_Recording_Notes;

   -----------------------
   -- Finish_Recording  --
   -----------------------

   function Finish_Recording (Now_Us : UInt64) return Boolean is
      State : Track_State renames Overlay_Ptr.Tracks (Overlay_Ptr.Recording_Trk);
      Close_At_Us : UInt32;
   begin
      if not Overlay_Ptr.Is_Recording and then not Overlay_Ptr.Is_Recording_Armed then
         return False;
      end if;
      if Overlay_Ptr.Is_Recording_Armed then
         Overlay_Ptr.Is_Recording_Armed := False;
         return False;
      end if;

      if not Overlay_Ptr.Is_Overdubbing then
         declare
            Elapsed : constant UInt64 := Now_Us - Overlay_Ptr.Record_Start_Us;
         begin
            State.Length_Us :=
              (if Overlay_Ptr.Record_Fixed_Length_Us > 0 then Overlay_Ptr.Record_Fixed_Length_Us
               elsif Elapsed > UInt64 (UInt32'Last) then UInt32'Last
               else UInt32 (Elapsed));
         end;
         if Overlay_Ptr.Is_Playing then
            --  The take begins where the performer began it, which is
            --  usually not the top of the transport cycle. That offset is
            --  the track's phase from now on, restored every time playback
            --  starts again.
            State.Cycle_Start_Us := Now_Us;
            State.Play_Cursor := State.Head;
            Capture_Track_Phase (Overlay_Ptr.Recording_Trk);
         else
            State.Start_Offset_Us := 0;
         end if;
      end if;
      if State.Length_Us = 0 then
         State.Length_Us := 1;
      end if;
      if not Overlay_Ptr.Is_Overdubbing then
         State.Stored_Length_Us := State.Length_Us;
      end if;
      Close_At_Us := State.Length_Us - 1;
      if Overlay_Ptr.Is_Overdubbing and then Overlay_Ptr.Is_Playing then
         Close_At_Us := UInt32 ((Now_Us - State.Cycle_Start_Us)
                                mod UInt64 (State.Length_Us));
      end if;
      Close_Held_Recording_Notes (Close_At_Us);
      Overlay_Ptr.Is_Recording := False;
      Overlay_Ptr.Is_Overdubbing := False;
      Held_Reset (Overlay_Ptr.Record_Held);
      return State.Count > Overlay_Ptr.Record_Start_Count;
   end Finish_Recording;

   -----------------------
   -- Cancel_Recording  --
   -----------------------

   procedure Cancel_Recording is
   begin
      Overlay_Ptr.Is_Recording_Armed := False;
      Overlay_Ptr.Is_Recording := False;
      Overlay_Ptr.Is_Overdubbing := False;
      Held_Reset (Overlay_Ptr.Record_Held);
   end Cancel_Recording;

   function Recording_Armed return Boolean is (Overlay_Ptr.Is_Recording_Armed);
   function Recording return Boolean is (Overlay_Ptr.Is_Recording);
   function Overdubbing return Boolean is (Overlay_Ptr.Is_Overdubbing);
   function Recording_Track return Loop_Track is (Overlay_Ptr.Recording_Trk);
   function Playing return Boolean is (Overlay_Ptr.Is_Playing);

   --------------------------
   -- Capture_Track_Phase  --
   --------------------------

   --  Where a track sits inside the shared transport cycle. Overlay_Ptr.Tracks may
   --  begin at different points, and that relationship has to survive a
   --  stop or a clear and undo, so it is stored rather than recomputed
   --  from zero.
   procedure Capture_Track_Phase (Track : Loop_Track) is
      State : Track_State renames Overlay_Ptr.Tracks (Track);
   begin
      if State.Length_Us = 0 then
         State.Start_Offset_Us := 0;
         return;
      end if;
      if State.Cycle_Start_Us >= Overlay_Ptr.Transport_Start_Us then
         State.Start_Offset_Us :=
           UInt32 ((State.Cycle_Start_Us - Overlay_Ptr.Transport_Start_Us)
                   mod UInt64 (State.Length_Us));
      else
         declare
            Behind : constant UInt32 :=
              UInt32 ((Overlay_Ptr.Transport_Start_Us - State.Cycle_Start_Us)
                      mod UInt64 (State.Length_Us));
         begin
            State.Start_Offset_Us :=
              (if Behind = 0 then 0 else State.Length_Us - Behind);
         end;
      end if;
   end Capture_Track_Phase;

   -------------------
   -- Seek_Track_To --
   -------------------

   --  Resume continues a cycle that was already running, so an event
   --  sitting exactly on the resume point has been played and is skipped.
   --  Starting a cycle places the transport on that point, so an event
   --  there is still due.
   procedure Seek_Track_To (State                   : in out Track_State;
                           Now_Us                  :        UInt64;
                           Position_Us              :        UInt32;
                           Skip_Events_At_Position : Boolean)
   is
   begin
      State.Cycle_Start_Us := Now_Us - UInt64 (Position_Us);
      State.Play_Cursor := State.Head;
      while State.Play_Cursor /= No_Slot loop
         declare
            At_Us : constant UInt32 := Overlay_Ptr.Event_Pool (State.Play_Cursor).At_Us;
         begin
            exit when At_Us > Position_Us
              or else (At_Us = Position_Us and then not Skip_Events_At_Position);
            State.Play_Cursor := Overlay_Ptr.Event_Pool (State.Play_Cursor).Next;
         end;
      end loop;
   end Seek_Track_To;

   -----------------------------
   -- Reset_Playback_Cursors  --
   -----------------------------

   procedure Reset_Playback_Cursors (Now_Us : UInt64) is
   begin
      Overlay_Ptr.Transport_Start_Us := Now_Us;
      for Track in Loop_Track loop
         declare
            State : Track_State renames Overlay_Ptr.Tracks (Track);
         begin
            if State.Length_Us = 0 then
               State.Play_Cursor := State.Head;
               State.Cycle_Start_Us := Now_Us;
            else
               --  Restore the track to the point in its own loop that
               --  belongs at the top of the transport cycle, so every
               --  track comes back in the alignment it had when recorded.
               declare
                  Offset : constant UInt32 :=
                    State.Start_Offset_Us mod State.Length_Us;
                  Position_Us : constant UInt32 :=
                    (if Offset = 0 then 0 else State.Length_Us - Offset);
               begin
                  Seek_Track_To (State, Now_Us, Position_Us, False);
               end;
            end if;
         end;
      end loop;
   end Reset_Playback_Cursors;

   -----------
   -- Start --
   -----------

   procedure Start (Now_Us : UInt64) is
   begin
      if not Has_Any_Data then
         return;
      end if;
      Overlay_Ptr.Is_Playing := True;
      Overlay_Ptr.Is_Paused := False;
      for Track in Loop_Track loop
         Overlay_Ptr.Tracks (Track).Paused_Position_Us := 0;
      end loop;
      Reset_Playback_Cursors (Now_Us);
   end Start;

   -----------
   -- Pause --
   -----------

   procedure Pause (Now_Us : UInt64; Release : Release_Proc) is
   begin
      if not Overlay_Ptr.Is_Playing then
         return;
      end if;
      if Release /= null then
         for Track in Loop_Track loop
            Release (Track);
         end loop;
      end if;
      for Track in Loop_Track loop
         declare
            State : Track_State renames Overlay_Ptr.Tracks (Track);
         begin
            State.Paused_Position_Us :=
              (if State.Length_Us > 0
               then UInt32 ((Now_Us - State.Cycle_Start_Us)
                            mod UInt64 (State.Length_Us))
               else 0);
            State.Play_Cursor := State.Head;
         end;
      end loop;
      Overlay_Ptr.Is_Playing := False;
      Overlay_Ptr.Is_Paused := True;
   end Pause;

   ------------
   -- Resume --
   ------------

   procedure Resume (Now_Us : UInt64) is
   begin
      if Overlay_Ptr.Is_Playing or else not Has_Any_Data then
         return;
      end if;
      if not Overlay_Ptr.Is_Paused then
         Start (Now_Us);
         return;
      end if;
      Overlay_Ptr.Is_Playing := True;
      Overlay_Ptr.Is_Paused := False;
      Overlay_Ptr.Transport_Start_Us := Now_Us;
      for Track in Loop_Track loop
         declare
            State : Track_State renames Overlay_Ptr.Tracks (Track);
         begin
            if State.Length_Us /= 0 then
               Seek_Track_To (State, Now_Us,
                             State.Paused_Position_Us mod State.Length_Us,
                             True);
               State.Paused_Position_Us := 0;
               --  Resume keeps absolute positions, so the stored phase is
               --  re-expressed against the new transport origin instead of
               --  drifting away from it.
               Capture_Track_Phase (Track);
            end if;
         end;
      end loop;
   end Resume;

   ----------
   -- Stop --
   ----------

   procedure Stop (Release : Release_Proc) is
   begin
      if Release /= null then
         for Track in Loop_Track loop
            Release (Track);
         end loop;
      end if;
      Overlay_Ptr.Is_Playing := False;
      Overlay_Ptr.Is_Paused := False;
      for Track in Loop_Track loop
         Overlay_Ptr.Tracks (Track).Play_Cursor := Overlay_Ptr.Tracks (Track).Head;
         Overlay_Ptr.Tracks (Track).Paused_Position_Us := 0;
      end loop;
   end Stop;

   ------------------
   -- Resize_Track --
   ------------------

   function Resize_Track (Track    : Loop_Track;
                          Length_Us : UInt32;
                          Now_Us    : UInt64;
                          Release   : Release_Proc) return Boolean
   is
      State : Track_State renames Overlay_Ptr.Tracks (Track);
   begin
      if Length_Us = 0 then
         return False;
      end if;
      if (Overlay_Ptr.Is_Recording or else Overlay_Ptr.Is_Recording_Armed)
        and then Overlay_Ptr.Recording_Trk = Track
      then
         return False;
      end if;
      if State.Count = 0 or else State.Length_Us = 0 then
         return True;
      end if;

      declare
         Stored_Length : constant UInt32 :=
           (if State.Stored_Length_Us > 0 then State.Stored_Length_Us
            else State.Length_Us);
      begin
         if Length_Us > Stored_Length then
            declare
               Required : Natural := 0;
               Offset : UInt32 := Stored_Length;
            begin
               while Offset < Length_Us loop
                  declare
                     Slot : Slot_Ref := State.Head;
                     Visited : Natural := 0;
                  begin
                     while Visited < State.Count and then Slot /= No_Slot loop
                        if UInt64 (Overlay_Ptr.Event_Pool (Slot).At_Us) + UInt64 (Offset)
                          < UInt64 (Length_Us)
                        then
                           Required := Required + 1;
                        end if;
                        Visited := Visited + 1;
                        Slot := Overlay_Ptr.Event_Pool (Slot).Next;
                     end loop;
                  end;
                  Offset := Offset + Stored_Length;
               end loop;

               if Required > Free_Events then
                  Overlay_Ptr.Overflow := Overlay_Ptr.Overflow + 1;
                  return False;
               end if;

               declare
                  Source_Count : constant Natural := State.Count;
               begin
                  Offset := Stored_Length;
                  while Offset < Length_Us loop
                     declare
                        Slot : Slot_Ref := State.Head;
                        Visited : Natural := 0;
                     begin
                        while Visited < Source_Count and then Slot /= No_Slot
                        loop
                           declare
                              Next_Slot : constant Slot_Ref :=
                                Overlay_Ptr.Event_Pool (Slot).Next;
                              Copy_Time : constant UInt64 :=
                                UInt64 (Overlay_Ptr.Event_Pool (Slot).At_Us)
                                  + UInt64 (Offset);
                           begin
                              if Copy_Time < UInt64 (Length_Us) then
                                 if not Insert_Event
                                   (Track, UInt32 (Copy_Time),
                                    Overlay_Ptr.Event_Pool (Slot).Event)
                                 then
                                    return False;
                                 end if;
                              end if;
                              Visited := Visited + 1;
                              Slot := Next_Slot;
                           end;
                        end loop;
                     end;
                     Offset := Offset + Stored_Length;
                  end loop;
               end;
               State.Stored_Length_Us := Length_Us;
            end;
         end if;
      end;

      declare
         Was_Audible : constant Boolean := Overlay_Ptr.Is_Playing and then Audible (Track);
         Old_Length_Us : constant UInt32 := State.Length_Us;
      begin
         State.Length_Us := Length_Us;
         if Overlay_Ptr.Is_Playing then
            declare
               Position_Us : UInt64 :=
                 (if Old_Length_Us > 0
                  then (Now_Us - State.Cycle_Start_Us) mod UInt64 (Old_Length_Us)
                  else 0);
            begin
               Position_Us := Position_Us mod UInt64 (Length_Us);
               if Was_Audible and then Release /= null then
                  Release (Track);
               end if;
               Seek_Track_To (State, Now_Us, UInt32 (Position_Us), True);
               Capture_Track_Phase (Track);
            end;
         else
            State.Play_Cursor := State.Head;
            State.Start_Offset_Us := State.Start_Offset_Us mod Length_Us;
         end if;
      end;
      return True;
   end Resize_Track;

   --------------
   -- Audible  --
   --------------

   function Audible (Track : Loop_Track) return Boolean is
      Any_Solo : Boolean := False;
   begin
      for T in Loop_Track loop
         Any_Solo := Any_Solo or else (Overlay_Ptr.Tracks (T).Solo and then not Overlay_Ptr.Tracks (T).Hidden);
      end loop;
      declare
         State : Track_State renames Overlay_Ptr.Tracks (Track);
      begin
         return (not State.Importing) and then (not State.Hidden)
           and then (not State.Muted) and then (not Any_Solo or else State.Solo);
      end;
   end Audible;

   -------------------------
   -- Collect_Held_Notes  --
   -------------------------

   procedure Collect_Held_Notes (Track : Loop_Track; Fn : Held_Note_Proc) is
      State : Track_State renames Overlay_Ptr.Tracks (Track);
   begin
      if Fn = null then
         return;
      end if;
      if State.Head = No_Slot or else State.Head = State.Play_Cursor then
         return;
      end if;

      Held_Reset (Overlay_Ptr.Held_Scratch);
      declare
         Slot : Slot_Ref := State.Head;
      begin
         while Slot /= No_Slot and then Slot /= State.Play_Cursor loop
            declare
               Ev : constant MIDI_Event := Overlay_Ptr.Event_Pool (Slot).Event;
               Kind : constant UInt8 := Status_Type (Ev.Status);
            begin
               if (Kind = 16#90# or else Kind = 16#80#)
                 and then Ev.Data_1 <= 127
               then
                  declare
                     Channel : constant UInt8 := Status_Channel (Ev.Status);
                     On : constant Boolean := Kind = 16#90# and then Ev.Data_2 > 0;
                  begin
                     if On then
                        Held_Set (Overlay_Ptr.Held_Scratch, Channel, Ev.Data_1, Ev.Data_2);
                     else
                        Held_Clear (Overlay_Ptr.Held_Scratch, Channel, Ev.Data_1);
                     end if;
                  end;
               end if;
            end;
            Slot := Overlay_Ptr.Event_Pool (Slot).Next;
         end loop;
      end;
      for E of Overlay_Ptr.Held_Scratch loop
         if E.Used then
            Fn (Track, E.Channel, E.Note, E.Velocity);
         end if;
      end loop;
   end Collect_Held_Notes;

   ----------
   -- Tick --
   ----------

   procedure Tick (Now_Us     : UInt64;
                   Emit       : Emit_Proc;
                   Release    : Release_Proc;
                   Max_Events : Positive := 96)
   is
      Processed : Natural := 0;
   begin
      if Overlay_Ptr.Is_Recording and then not Overlay_Ptr.Is_Overdubbing
        and then Overlay_Ptr.Record_Fixed_Length_Us > 0
        and then Now_Us - Overlay_Ptr.Record_Start_Us >= UInt64 (Overlay_Ptr.Record_Fixed_Length_Us)
      then
         declare
            Boundary : constant UInt64 :=
              Overlay_Ptr.Record_Start_Us + UInt64 (Overlay_Ptr.Record_Fixed_Length_Us);
            Dummy : constant Boolean := Finish_Recording (Boundary);
         begin
            if not Overlay_Ptr.Is_Playing then
               Start (Boundary);
            end if;
         end;
      end if;

      if not Overlay_Ptr.Is_Playing then
         return;
      end if;

      for Track in Loop_Track loop
         exit when Processed >= Max_Events;
         declare
            State : Track_State renames Overlay_Ptr.Tracks (Track);
         begin
            if State.Count /= 0 and then State.Length_Us /= 0 then
               if Now_Us - State.Cycle_Start_Us >= UInt64 (State.Length_Us)
               then
                  if Release /= null then
                     Release (Track);
                  end if;
                  declare
                     Cycles : constant UInt64 :=
                       (Now_Us - State.Cycle_Start_Us)
                         / UInt64 (State.Length_Us);
                  begin
                     State.Cycle_Start_Us :=
                       State.Cycle_Start_Us + Cycles * UInt64 (State.Length_Us);
                  end;
                  State.Play_Cursor := State.Head;
               end if;

               declare
                  Can_Emit : constant Boolean := Audible (Track);
                  Elapsed : constant UInt32 :=
                    UInt32 (Now_Us - State.Cycle_Start_Us);
               begin
                  while State.Play_Cursor /= No_Slot
                    and then Processed < Max_Events
                  loop
                     declare
                        Slot : Loop_Slot renames Overlay_Ptr.Event_Pool (State.Play_Cursor);
                     begin
                        exit when Slot.At_Us > Elapsed;
                        if Can_Emit and then Emit /= null then
                           Emit (Track, Slot.At_Us, Slot.Event);
                        end if;
                        State.Play_Cursor := Slot.Next;
                        Processed := Processed + 1;
                     end;
                  end loop;
               end;
            end if;
         end;
      end loop;
   end Tick;

   ------------------------------------
   -- Release_If_Audibility_Changed  --
   ------------------------------------

   procedure Release_If_Audibility_Changed (Track      : Loop_Track;
                                           Was_Audible : Boolean;
                                           Release     : Release_Proc)
   is
   begin
      if Was_Audible and then not Audible (Track) and then Release /= null then
         Release (Track);
      end if;
   end Release_If_Audibility_Changed;

   -----------------
   -- Safe_Clear  --
   -----------------

   procedure Safe_Clear (Track : Loop_Track; Release : Release_Proc) is
   begin
      --  A pending arm survives its own track being cleared: there is
      --  nothing captured yet, so tidying up old content is not a reason
      --  to abandon the take. An armed-and-recording pass is different, it
      --  already holds real captured events, so clearing its own track out
      --  from under it still aborts it.
      if Overlay_Ptr.Is_Recording and then Overlay_Ptr.Recording_Trk = Track then
         Cancel_Recording;
      end if;
      --  An empty track must never become hidden: undo could never bring
      --  it back, and a phantom hidden-but-empty track breaks every "is
      --  anything cleared" decision above it.
      if Overlay_Ptr.Tracks (Track).Count = 0 then
         if Release /= null then
            Release (Track);
         end if;
         return;
      end if;
      Overlay_Ptr.Tracks (Track).Hidden := True;
      if Release /= null then
         Release (Track);
      end if;
   end Safe_Clear;

   -----------------
   -- Undo_Clear  --
   -----------------

   procedure Undo_Clear (Track : Loop_Track) is
   begin
      if Overlay_Ptr.Tracks (Track).Count = 0 then
         return;
      end if;
      --  Bringing the old content back abandons whatever take was pending:
      --  undo and a fresh replacement are opposite choices, so choosing
      --  one cancels the other.
      if (Overlay_Ptr.Is_Recording or else Overlay_Ptr.Is_Recording_Armed) and then Overlay_Ptr.Recording_Trk = Track
      then
         Cancel_Recording;
      end if;
      Overlay_Ptr.Tracks (Track).Hidden := False;
   end Undo_Clear;

   -------------------------
   -- Permanently_Clear   --
   -------------------------

   procedure Permanently_Clear (Track : Loop_Track) is
      Slot : Slot_Ref := Overlay_Ptr.Tracks (Track).Head;
   begin
      while Slot /= No_Slot loop
         declare
            Next_Slot : constant Slot_Ref := Overlay_Ptr.Event_Pool (Slot).Next;
         begin
            Free_Slot (Slot);
            Slot := Next_Slot;
         end;
      end loop;
      Overlay_Ptr.Tracks (Track) := (others => <>);
   end Permanently_Clear;

   ----------------
   -- Clear_All  --
   ----------------

   procedure Clear_All (Release : Release_Proc) is
   begin
      if Release /= null then
         for Track in Loop_Track loop
            Release (Track);
         end loop;
      end if;
      for Track in Loop_Track loop
         Permanently_Clear (Track);
      end loop;
      Cancel_Recording;
      Overlay_Ptr.Is_Playing := False;
      Overlay_Ptr.Is_Paused := False;
   end Clear_All;

   ----------------
   -- Set_Muted  --
   ----------------

   procedure Set_Muted (Track : Loop_Track; Muted : Boolean;
                        Release : Release_Proc)
   is
      Was_Audible : constant Boolean := Audible (Track);
   begin
      Overlay_Ptr.Tracks (Track).Muted := Muted;
      Release_If_Audibility_Changed (Track, Was_Audible, Release);
   end Set_Muted;

   ---------------
   -- Set_Solo  --
   ---------------

   procedure Set_Solo (Track : Loop_Track; Solo : Boolean;
                       Release : Release_Proc)
   is
      Was_Audible : array (Loop_Track) of Boolean;
   begin
      for T in Loop_Track loop
         Was_Audible (T) := Audible (T);
      end loop;
      Overlay_Ptr.Tracks (Track).Solo := Solo;
      for T in Loop_Track loop
         Release_If_Audibility_Changed (T, Was_Audible (T), Release);
      end loop;
   end Set_Solo;

   --------------------
   -- Used/Free/etc  --
   --------------------

   function Used_Events return Natural is (Overlay_Ptr.Used_Count);
   function Free_Events return Natural is (Pool_Size - Overlay_Ptr.Used_Count);
   function Overflow_Count return Natural is (Overlay_Ptr.Overflow);

   function Has_Any_Data return Boolean is
   begin
      for T in Loop_Track loop
         if Overlay_Ptr.Tracks (T).Count > 0 and then not Overlay_Ptr.Tracks (T).Hidden then
            return True;
         end if;
      end loop;
      return False;
   end Has_Any_Data;

   -----------------------------
   -- Oldest_Populated_Track  --
   -----------------------------

   function Oldest_Populated_Track return Loop_Track is
      Result : Loop_Track := Overlay_Ptr.Selected;
      Oldest : UInt16 := UInt16'Last;
   begin
      for T in Loop_Track loop
         if Overlay_Ptr.Tracks (T).Count > 0 and then Overlay_Ptr.Tracks (T).Generation < Oldest then
            Oldest := Overlay_Ptr.Tracks (T).Generation;
            Result := T;
         end if;
      end loop;
      return Result;
   end Oldest_Populated_Track;

   -----------------------------
   -- Newest_Populated_Track  --
   -----------------------------

   --  The most recently recorded layer, cleared or not: stepping back to
   --  the last thing played is what a performer means by "previous layer".
   function Newest_Populated_Track return Loop_Track is
      Result : Loop_Track := Overlay_Ptr.Selected;
      Newest : UInt16 := 0;
      Found : Boolean := False;
   begin
      for T in Loop_Track loop
         if Overlay_Ptr.Tracks (T).Count /= 0 then
            if not Found or else Overlay_Ptr.Tracks (T).Generation >= Newest then
               Newest := Overlay_Ptr.Tracks (T).Generation;
               Result := T;
               Found := True;
            end if;
         end if;
      end loop;
      return Result;
   end Newest_Populated_Track;

   -------------------
   -- Visit_Events  --
   -------------------

   function Track_Event_Count (Track : Loop_Track) return Natural
   is (Overlay_Ptr.Tracks (Track).Count);

   procedure Visit_Events (Track : Loop_Track; Visit : Emit_Proc) is
      Slot : Slot_Ref := Overlay_Ptr.Tracks (Track).Head;
   begin
      if Visit = null then
         return;
      end if;
      while Slot /= No_Slot loop
         Visit (Track, Overlay_Ptr.Event_Pool (Slot).At_Us,
               Overlay_Ptr.Event_Pool (Slot).Event);
         Slot := Overlay_Ptr.Event_Pool (Slot).Next;
      end loop;
   end Visit_Events;

   --------------------
   -- Restore_Event  --
   --------------------

   function Restore_Event (Track : Loop_Track; At_Us : UInt32;
                           Event : MIDI_Event) return Boolean
   is (Insert_Event (Track, At_Us, Event));

   --------------------------------
   -- Set_Restored_Track_State  --
   --------------------------------

   procedure Set_Restored_Track_State (Track              : Loop_Track;
                                       Length_Us          : UInt32;
                                       Stored_Length_Us   : UInt32;
                                       Generation         : UInt16;
                                       Muted, Solo, Hidden : Boolean;
                                       Start_Offset_Us    : UInt32 := 0)
   is
      State : Track_State renames Overlay_Ptr.Tracks (Track);
   begin
      State.Start_Offset_Us :=
        (if Length_Us > 0 then Start_Offset_Us mod Length_Us else 0);
      State.Length_Us := Length_Us;
      State.Stored_Length_Us :=
        (if Stored_Length_Us >= Length_Us then Stored_Length_Us
         else Length_Us);
      State.Generation := Generation;
      State.Muted := Muted;
      State.Solo := Solo;
      State.Hidden := Hidden;
      if Generation > Overlay_Ptr.Generation_Counter then
         Overlay_Ptr.Generation_Counter := Generation;
      end if;
   end Set_Restored_Track_State;

   function Track_Length_Us (Track : Loop_Track) return UInt32
   is (Overlay_Ptr.Tracks (Track).Length_Us);

   function Track_Stored_Length_Us (Track : Loop_Track) return UInt32
   is (Overlay_Ptr.Tracks (Track).Stored_Length_Us);

   function Track_Generation (Track : Loop_Track) return UInt16
   is (Overlay_Ptr.Tracks (Track).Generation);

   function Track_Muted (Track : Loop_Track) return Boolean
   is (Overlay_Ptr.Tracks (Track).Muted);

   function Track_Solo (Track : Loop_Track) return Boolean
   is (Overlay_Ptr.Tracks (Track).Solo);

   function Track_Hidden (Track : Loop_Track) return Boolean
   is (Overlay_Ptr.Tracks (Track).Hidden);

   function Track_Start_Offset_Us (Track : Loop_Track) return UInt32
   is (Overlay_Ptr.Tracks (Track).Start_Offset_Us);

   ------------
   -- Icon   --
   ------------

   function Icon (Track : Loop_Track) return Track_Icon is
      State : Track_State renames Overlay_Ptr.Tracks (Track);
   begin
      if Overlay_Ptr.Is_Recording and then Overlay_Ptr.Recording_Trk = Track then
         return Recording_Icon;
      end if;
      if Overlay_Ptr.Is_Recording_Armed and then Overlay_Ptr.Recording_Trk = Track then
         return Armed;
      end if;
      if not Track_Has_Content (Track) then
         return Empty;
      end if;
      if Overlay_Ptr.Is_Playing and then Audible (Track) then
         return Playing_Icon;
      end if;
      return Stopped;
   end Icon;

   --------------
   -- Play_Tap --
   --------------

   procedure Play_Tap (Now_Us           : UInt64;
                       Fixed_Length_Us  : UInt32;
                       Release          : Release_Proc;
                       Double_Window_Us : UInt32 := 350_000)
   is
      T : constant Loop_Track := Overlay_Ptr.Selected;

      Is_Double : constant Boolean :=
        Overlay_Ptr.Play_Tap_Valid
          and then Overlay_Ptr.Play_Tap_Track = T
          and then Now_Us >= Overlay_Ptr.Play_Tap_Us
          and then Now_Us - Overlay_Ptr.Play_Tap_Us
                     <= UInt64 (Double_Window_Us);

      Dummy : Boolean;
   begin
      if Is_Double then
         --  Undo whatever the first tap just did, then apply the
         --  double-tap meaning for the state that first tap saw.
         case Overlay_Ptr.Play_Tap_Icon is
            when Empty =>
               --  First tap armed it. Double tap means undo the clear.
               Cancel_Recording;
               Undo_Clear (T);

            when Stopped =>
               --  First tap started it playing. Double tap means clear.
               Stop (Release);
               Safe_Clear (T, Release);

            when Playing_Icon =>
               --  First tap started an overdub. Double tap means stop.
               Cancel_Recording;
               Stop (Release);

            when Recording_Icon =>
               --  First tap finished the take. Double tap means stop.
               Stop (Release);

            when Armed =>
               --  First tap unarmed it, and the spec gives no double-tap
               --  meaning from armed. Leave it unarmed.
               null;
         end case;

         --  Consumed, so a third tap starts a fresh single tap rather
         --  than chaining off this one.
         Overlay_Ptr.Play_Tap_Valid := False;
         return;
      end if;

      Overlay_Ptr.Play_Tap_Icon := Icon (T);
      Overlay_Ptr.Play_Tap_Track := T;
      Overlay_Ptr.Play_Tap_Us := Now_Us;
      Overlay_Ptr.Play_Tap_Valid := True;

      case Overlay_Ptr.Play_Tap_Icon is
         when Empty =>
            Arm_Record (T, Fixed_Length_Us, Overdub => False);

         when Armed =>
            Cancel_Recording;

         when Stopped =>
            --  Resume falls back to Start on its own when there is
            --  nothing paused to resume.
            Resume (Now_Us);

         when Playing_Icon =>
            --  Overdub starts recording right away rather than waiting
            --  for a first note, so no fixed length: it runs until it is
            --  switched back off.
            Arm_Record (T, 0, Overdub => True);

         when Recording_Icon =>
            Dummy := Finish_Recording (Now_Us);
            if not Overlay_Ptr.Is_Playing then
               --  A fresh take rather than an overdub: finishing it is
               --  also what starts it looping.
               Start (Now_Us);
            end if;
      end case;
   end Play_Tap;

   -----------
   -- Bars  --
   -----------

   function Bars (Track : Loop_Track) return Bar_Count
   is (Overlay_Ptr.Tracks (Track).Bars);

   procedure Set_Bars (Track : Loop_Track; Bars : Bar_Count; Now_Us : UInt64;
                       Release : Release_Proc)
   is
      pragma Unreferenced (Now_Us, Release);
   begin
      Overlay_Ptr.Tracks (Track).Bars := Bars;
      --  Resize_Track needs a per-bar microsecond length, which depends on
      --  BPM and lives above this package (WNM.Project). The caller that
      --  owns tempo is expected to follow this with Resize_Track once it
      --  has computed that length; this just remembers the chosen bar
      --  count for the UI and for Resize_Track's length math next tick.
   end Set_Bars;

   ---------------
   -- Quantize  --
   ---------------

   function Quantize (Track : Loop_Track) return Quantize_Kind
   is (Overlay_Ptr.Tracks (Track).Quant);

   procedure Set_Quantize (Track : Loop_Track; Q : Quantize_Kind) is
   begin
      Overlay_Ptr.Tracks (Track).Quant := Q;
   end Set_Quantize;

   ------------------
   -- Auto_Setting --
   ------------------

   function Auto_Setting return Auto_Kind is (Overlay_Ptr.Auto_Setting);

   procedure Set_Auto_Setting (Setting : Auto_Kind) is
   begin
      Overlay_Ptr.Auto_Setting := Setting;
   end Set_Auto_Setting;

   ------------------------------------------------------------------------
   --  LiveArp
   ------------------------------------------------------------------------

   ------------------
   -- Division_Us  --
   ------------------

   function Division_Us (D : Arp_Division_Kind; Beat_Us : UInt32)
                         return UInt32
   is
      --  A "T" division is the triplet of the straight one named right
      --  before it: 2/3 its duration, since 3 of them fill the time 2
      --  straight ones would.
   begin
      case D is
         when D_1_4  => return Beat_Us;
         when D_1_2T => return (Beat_Us * 8) / 3;  -- 2 beats, 2/3 duration
         when D_1_8  => return Beat_Us / 2;
         when D_1_4T => return (Beat_Us * 2) / 3;
         when D_1_16 => return Beat_Us / 4;
         when D_1_8T => return Beat_Us / 3;
         when D_1_32 => return Beat_Us / 8;
         when D_1_64 => return Beat_Us / 16;
      end case;
   end Division_Us;

   ----------------
   -- Arp_Style  --
   ----------------

   function Arp_Style (Channel : Arp_Channel) return Arp_Style_Kind
   is (Overlay_Ptr.Arp (Channel).Style);

   procedure Set_Arp_Style (Channel : Arp_Channel; S : Arp_Style_Kind) is
   begin
      Overlay_Ptr.Arp (Channel).Style := S;
   end Set_Arp_Style;

   -------------------
   -- Arp_Division  --
   -------------------

   function Arp_Division (Channel : Arp_Channel) return Arp_Division_Kind
   is (Overlay_Ptr.Arp (Channel).Division);

   procedure Set_Arp_Division (Channel : Arp_Channel; D : Arp_Division_Kind)
   is
   begin
      Overlay_Ptr.Arp (Channel).Division := D;
   end Set_Arp_Division;

   -----------------------
   -- Arp_Octave_Down/Up --
   -----------------------

   function Arp_Octave_Down (Channel : Arp_Channel) return Boolean
   is (Overlay_Ptr.Arp (Channel).Octave_Down);

   function Arp_Octave_Up (Channel : Arp_Channel) return Boolean
   is (Overlay_Ptr.Arp (Channel).Octave_Up);

   procedure Set_Arp_Octave_Down (Channel : Arp_Channel; On : Boolean) is
   begin
      Overlay_Ptr.Arp (Channel).Octave_Down := On;
   end Set_Arp_Octave_Down;

   procedure Set_Arp_Octave_Up (Channel : Arp_Channel; On : Boolean) is
   begin
      Overlay_Ptr.Arp (Channel).Octave_Up := On;
   end Set_Arp_Octave_Up;

   -------------------
   -- Arp_Note_On   --
   -------------------

   procedure Arp_Note_On (Channel  : Arp_Channel;
                          Key      : MIDI.MIDI_Key;
                          Velocity : MIDI.MIDI_Data)
   is
   begin
      Arp_Table_Set (Overlay_Ptr.Arp (Channel).Held, Key, Velocity);
   end Arp_Note_On;

   --------------------
   -- Arp_Note_Off   --
   --------------------

   procedure Arp_Note_Off (Channel : Arp_Channel; Key : MIDI.MIDI_Key;
                           Emit    : Arp_Emit_Proc := null)
   is
      State : Arp_Channel_State renames Overlay_Ptr.Arp (Channel);
      Any_Held : Boolean := False;
   begin
      Arp_Table_Clear (State.Held, Key);

      if Emit = null then
         return;
      end if;

      for E of State.Held loop
         Any_Held := Any_Held or else E.Used;
      end loop;

      if not Any_Held then
         --  That was the last held note: silence it now rather than
         --  waiting for Arp_Tick's next step to notice.
         for E of State.Sounding loop
            if E.Used then
               Emit (Channel, E.Key, E.Velocity, False);
               E.Used := False;
            end if;
         end loop;
      end if;
   end Arp_Note_Off;

   ------------------
   -- Arp_Reset    --
   ------------------

   procedure Arp_Reset (Channel : Arp_Channel) is
      State : Arp_Channel_State renames Overlay_Ptr.Arp (Channel);
   begin
      State.Held := (others => <>);
      State.Sounding := (others => <>);
      State.Step_Index := 0;
      State.Has_Stepped := False;
   end Arp_Reset;

   ------------------
   -- Arp_Next_Rnd --
   ------------------

   function Arp_Next_Rnd return UInt32 is
   begin
      --  Plain linear congruential generator, parameters from Numerical
      --  Recipes. Not cryptographic, just needs to not repeat obviously
      --  over a few bars of random-style stepping.
      Overlay_Ptr.Arp_Seed := Overlay_Ptr.Arp_Seed * 1_664_525 + 1_013_904_223;
      return Overlay_Ptr.Arp_Seed;
   end Arp_Next_Rnd;

   ------------------------------------------------------------------------
   --  Stutter and dub delay
   ------------------------------------------------------------------------

   function Clock_32 (Now_Us : UInt64) return UInt32
   is (UInt32 (Now_Us and 16#FFFF_FFFF#));
   --  See Timed_Event.At_Us: only differences matter, and those stay
   --  correct across the 32-bit wrap.

   ------------------------
   -- Stutter_Length_Us  --
   ------------------------

   function Stutter_Length_Us (D : Stutter_Division_Kind; Beat_Us : UInt32)
                               return UInt32
   is
      Bar_Us : constant UInt32 := Beat_Us * UInt32 (Beats_Per_Bar);
   begin
      case D is
         when S_1    => return Bar_Us;
         when S_1_2  => return Bar_Us / 2;
         when S_1_4  => return Bar_Us / 4;
         when S_2T   => return (Bar_Us * 2) / 3;  -- half-bar triplet
         when S_1_8  => return Bar_Us / 8;
         when S_4T   => return Bar_Us / 3;        -- quarter-bar triplet
         when S_1_16 => return Bar_Us / 16;
         when S_1_32 => return Bar_Us / 32;
      end case;
   end Stutter_Length_Us;

   ------------------
   -- History_Push --
   ------------------

   procedure History_Push (Now_Us : UInt64; Event : MIDI_Event) is
      FX : Effects_State renames Overlay_Ptr.FX;
   begin
      if FX.Stutter_On then
         --  Frozen while a stutter is running, so the window it captured
         --  cannot be overwritten underneath it by whatever is still
         --  playing. The reference engine instead detects overwritten
         --  slots through monotonic sequence numbers and gives up on the
         --  repeat; not writing at all is cheaper and keeps the repeat
         --  intact, at the cost of the moment just before a release not
         --  being in history for an immediately following stutter.
         return;
      end if;

      FX.History (FX.History_Next) := (At_Us => Clock_32 (Now_Us),
                                       Event => Event);
      FX.History_Next := (FX.History_Next + 1) mod History_Capacity;
      if FX.History_Count < History_Capacity then
         FX.History_Count := FX.History_Count + 1;
      end if;
   end History_Push;

   --------------------
   -- Stutter_Active --
   --------------------

   function Stutter_Active return Boolean is (Overlay_Ptr.FX.Stutter_On);

   -------------------------
   -- Stutter_Release_All --
   -------------------------

   procedure Stutter_Release_All (Emit : Event_Emit_Proc) is
      FX : Effects_State renames Overlay_Ptr.FX;
   begin
      for E of FX.Stutter_Sounding loop
         if E.Used then
            if Emit /= null then
               Emit ((Status => 16#80# + E.Channel,
                     Data_1 => E.Note,
                     Data_2 => 0));
            end if;
            E.Used := False;
         end if;
      end loop;
   end Stutter_Release_All;

   -------------------
   -- Stutter_Start --
   -------------------

   procedure Stutter_Start (Now_Us  : UInt64;
                            D       : Stutter_Division_Kind;
                            Beat_Us : UInt32)
   is
      FX     : Effects_State renames Overlay_Ptr.FX;
      Length : constant UInt32 := Stutter_Length_Us (D, Beat_Us);
      Now_32 : constant UInt32 := Clock_32 (Now_Us);
      Found  : Boolean := False;
   begin
      if Length = 0 or else FX.History_Count = 0 then
         return;
      end if;

      --  Anything to repeat in that window? Same check as the
      --  reference's "snapshot.empty() -> do not activate": holding a
      --  stutter button during silence should do nothing rather than
      --  latch onto an empty loop.
      for I in 0 .. FX.History_Count - 1 loop
         declare
            Idx : constant Natural :=
              (FX.History_Next + History_Capacity - 1 - I) mod
                History_Capacity;
         begin
            exit when Now_32 - FX.History (Idx).At_Us > Length;
            Found := True;
         end;
      end loop;

      if not Found then
         return;
      end if;

      FX.Stutter_On := True;
      FX.Stutter_Length_Us := Length;
      FX.Stutter_Window_Us := Now_32 - Length;
      FX.Stutter_Cycle_Us := Now_32;
      FX.Stutter_Cursor := 0;
      Held_Reset (FX.Stutter_Sounding);
   end Stutter_Start;

   ------------------
   -- Stutter_Stop --
   ------------------

   procedure Stutter_Stop (Emit : Event_Emit_Proc) is
   begin
      if Overlay_Ptr.FX.Stutter_On then
         Stutter_Release_All (Emit);
      end if;
      Overlay_Ptr.FX.Stutter_On := False;
   end Stutter_Stop;

   ------------------
   -- Stutter_Tick --
   ------------------

   procedure Stutter_Tick (Now_Us : UInt64; Emit : Event_Emit_Proc;
                           Max_Events : Positive := 48)
   is
      FX      : Effects_State renames Overlay_Ptr.FX;
      Now_32  : constant UInt32 := Clock_32 (Now_Us);
      Emitted : Natural := 0;
      Seen    : Natural := 0;
      --  How many in-window events this pass has walked past, so it can
      --  be compared against the cursor to find where to resume.
   begin
      if not FX.Stutter_On or else FX.Stutter_Length_Us = 0
        or else Emit = null
      then
         return;
      end if;

      --  Wrapped into the next repeat: put down everything this cycle
      --  left sounding and start the window over, exactly as the
      --  reference does at its own cycle boundary.
      if Now_32 - FX.Stutter_Cycle_Us >= FX.Stutter_Length_Us then
         Stutter_Release_All (Emit);
         declare
            Cycles : constant UInt32 :=
              (Now_32 - FX.Stutter_Cycle_Us) / FX.Stutter_Length_Us;
         begin
            FX.Stutter_Cycle_Us :=
              FX.Stutter_Cycle_Us + Cycles * FX.Stutter_Length_Us;
         end;
         FX.Stutter_Cursor := 0;
      end if;

      declare
         Elapsed : constant UInt32 := Now_32 - FX.Stutter_Cycle_Us;
      begin
         --  The captured window, oldest first. History writes are frozen
         --  while this runs (see History_Push), so this enumeration is
         --  stable from tick to tick and the cursor below stays valid.
         for I in 0 .. FX.History_Count - 1 loop
            exit when Emitted >= Max_Events;

            declare
               Idx : constant Natural :=
                 (FX.History_Next + History_Capacity - FX.History_Count + I)
                   mod History_Capacity;
               Slot   : Timed_Event renames FX.History (Idx);
               Offset : constant UInt32 := Slot.At_Us - FX.Stutter_Window_Us;
               Kind   : constant UInt8 := Status_Type (Slot.Event.Status);
               Chan   : constant UInt8 := Status_Channel (Slot.Event.Status);
            begin
               --  Older than the window, or past its end.
               if Offset > FX.Stutter_Length_Us then
                  goto Next_Slot;
               end if;

               --  In the window and in time order, so once one is not due
               --  yet, neither is anything after it.
               exit when Offset > Elapsed;

               Seen := Seen + 1;
               if Seen <= FX.Stutter_Cursor then
                  --  Already emitted earlier in this same repeat.
                  goto Next_Slot;
               end if;

               if Kind = 16#90# and then Slot.Event.Data_2 > 0 then
                  if Held_Is_Set (FX.Stutter_Sounding, Chan,
                                 Slot.Event.Data_1)
                  then
                     --  Already sounding: retrigger rather than skip, the
                     --  way the reference's emitNoteSafe does. Skipping
                     --  would collapse repeated hits of the same drum
                     --  inside the window down to one, which is most of
                     --  what a stutter is for.
                     Emit ((Status => 16#80# + Chan,
                           Data_1 => Slot.Event.Data_1,
                           Data_2 => 0));
                     Emitted := Emitted + 1;
                  end if;

                  Held_Set (FX.Stutter_Sounding, Chan, Slot.Event.Data_1,
                           Slot.Event.Data_2);
                  Emit (Slot.Event);
                  Emitted := Emitted + 1;

               elsif Kind = 16#80#
                 or else (Kind = 16#90# and then Slot.Event.Data_2 = 0)
               then
                  --  A note-off for something this repeat never turned on
                  --  is dropped, so the window starting mid-note cannot
                  --  send a stray off into whatever else is playing that
                  --  note.
                  if Held_Is_Set (FX.Stutter_Sounding, Chan,
                                 Slot.Event.Data_1)
                  then
                     Held_Clear (FX.Stutter_Sounding, Chan,
                                Slot.Event.Data_1);
                     Emit ((Status => 16#80# + Chan,
                           Data_1 => Slot.Event.Data_1,
                           Data_2 => 0));
                     Emitted := Emitted + 1;
                  end if;
               end if;

               FX.Stutter_Cursor := Seen;
            end;
            <<Next_Slot>>
         end loop;
      end;
   end Stutter_Tick;

   ------------------
   -- Delay_Active --
   ------------------

   function Delay_Active return Boolean is (Overlay_Ptr.FX.Delay_On);

   function Delay_Division return Arp_Division_Kind
   is (Overlay_Ptr.FX.Delay_Div);

   ---------------
   -- Set_Delay --
   ---------------

   procedure Set_Delay (D : Arp_Division_Kind; On : Boolean) is
   begin
      Overlay_Ptr.FX.Delay_Div := D;
      Overlay_Ptr.FX.Delay_On := On;
   end Set_Delay;

   ----------------
   -- Delay_Note --
   ----------------

   procedure Delay_Note (Now_Us  : UInt64;
                         Event   : MIDI_Event;
                         Beat_Us : UInt32)
   is
      FX    : Effects_State renames Overlay_Ptr.FX;
      Step  : constant UInt32 := Division_Us (FX.Delay_Div, Beat_Us);
      Now_32 : constant UInt32 := Clock_32 (Now_Us);
      Gate  : constant UInt32 := (Step * 3) / 4;
      --  No note-off to correlate against at this point, so each repeat
      --  gets a gate of three quarters of the delay time. Long enough to
      --  sound like the original, short enough never to run into its own
      --  next repeat.

      Vel : UInt8 := Event.Data_2;

      procedure Schedule (At_32 : UInt32; E : MIDI_Event) is
      begin
         for I in FX.Delay_Pending'Range loop
            if not FX.Delay_Used (I) then
               FX.Delay_Pending (I) := (At_Us => At_32, Event => E);
               FX.Delay_Used (I) := True;
               return;
            end if;
         end loop;
         --  Full: this repeat is dropped rather than displacing one
         --  already scheduled. See Delay_Pending_Capacity.
      end Schedule;
   begin
      if not FX.Delay_On
        or else Step = 0
        or else Status_Type (Event.Status) /= 16#90#
        or else Event.Data_2 = 0
      then
         return;
      end if;

      for Repeat in 1 .. Delay_Repeats loop
         --  Down to roughly 60% each time, so three repeats land near
         --  60/36/21% of the original.
         Vel := UInt8 ((Natural (Vel) * 3) / 5);
         exit when Vel = 0;

         declare
            At_On : constant UInt32 := Now_32 + UInt32 (Repeat) * Step;
         begin
            Schedule (At_On, (Status => Event.Status,
                             Data_1 => Event.Data_1,
                             Data_2 => Vel));
            Schedule (At_On + Gate,
                     (Status => 16#80# + Status_Channel (Event.Status),
                      Data_1 => Event.Data_1,
                      Data_2 => 0));
         end;
      end loop;
   end Delay_Note;

   ----------------
   -- Delay_Tick --
   ----------------

   procedure Delay_Tick (Now_Us : UInt64; Emit : Event_Emit_Proc) is
      FX     : Effects_State renames Overlay_Ptr.FX;
      Now_32 : constant UInt32 := Clock_32 (Now_Us);
   begin
      if Emit = null then
         return;
      end if;

      for I in FX.Delay_Pending'Range loop
         if FX.Delay_Used (I) then
            --  Due when now has caught up to it. The subtraction is the
            --  32-bit-wrap-safe way round: a not-yet-due event gives a
            --  huge unsigned difference the other way.
            if Now_32 - FX.Delay_Pending (I).At_Us
                 < UInt32'Last / 2
            then
               Emit (FX.Delay_Pending (I).Event);
               FX.Delay_Used (I) := False;
            end if;
         end if;
      end loop;
   end Delay_Tick;

   --------------------
   -- Clear_Effects  --
   --------------------

   procedure Clear_Effects (Emit : Event_Emit_Proc) is
      FX : Effects_State renames Overlay_Ptr.FX;
   begin
      Stutter_Stop (Emit);

      --  Anything still scheduled gets its note-offs sent and the rest
      --  dropped, so nothing is left hanging.
      for I in FX.Delay_Pending'Range loop
         if FX.Delay_Used (I)
           and then Status_Type (FX.Delay_Pending (I).Event.Status) = 16#80#
           and then Emit /= null
         then
            Emit (FX.Delay_Pending (I).Event);
         end if;
         FX.Delay_Used (I) := False;
      end loop;
   end Clear_Effects;

   --------------
   -- Arp_Tick --
   --------------

   procedure Arp_Tick (Now_Us : UInt64; Beat_Us : UInt32;
                       Emit   : Arp_Emit_Proc)
   is
   begin
      if Emit = null then
         return;
      end if;

      for Channel in Arp_Channel loop
         declare
            State : Arp_Channel_State renames Overlay_Ptr.Arp (Channel);
         begin
            if State.Style = Arp_Off then
               goto Next_Channel;
            end if;

            if State.Has_Stepped
              and then Now_Us - State.Last_Step_Us <
                UInt64 (Division_Us (State.Division, Beat_Us))
            then
               goto Next_Channel;
            end if;

            --  Snapped to the division boundary rather than reset to
            --  Now_Us, so a tick arriving a little late does not push
            --  every following step later too (same reasoning as the loop
            --  engine's own cycle-wrap handling).
            State.Last_Step_Us :=
              (if State.Has_Stepped
               then State.Last_Step_Us
                 + UInt64 (Division_Us (State.Division, Beat_Us))
               else Now_Us);
            State.Has_Stepped := True;

            --  Stop whatever this channel was sounding.
            for E of State.Sounding loop
               if E.Used then
                  Emit (Channel, E.Key, E.Velocity, False);
                  E.Used := False;
               end if;
            end loop;

            --  Gather currently held notes, sorted ascending by key (a
            --  plain insertion sort: Arp_Max_Notes is small).
            declare
               Sorted : Arp_Note_Table := (others => <>);
               Count  : Natural := 0;
            begin
               for E of State.Held loop
                  if E.Used then
                     declare
                        Insert_At : Natural := Count + 1;
                     begin
                        while Insert_At > 1
                          and then Sorted (Insert_At - 1).Key > E.Key
                        loop
                           Sorted (Insert_At) := Sorted (Insert_At - 1);
                           Insert_At := Insert_At - 1;
                        end loop;
                        Sorted (Insert_At) := E;
                        Count := Count + 1;
                     end;
                  end if;
               end loop;

               if Count = 0 then
                  State.Step_Index := 0;
                  goto Next_Channel;
               end if;

               declare
                  procedure Sound (Idx : Natural) is
                     Key : constant MIDI.MIDI_Key := Sorted (Idx + 1).Key;
                     Vel : constant MIDI.MIDI_Data :=
                       Sorted (Idx + 1).Velocity;
                  begin
                     Arp_Table_Set (State.Sounding, Key, Vel);
                     Emit (Channel, Key, Vel, True);

                     if State.Octave_Down and then Integer (Key) >= 12 then
                        declare
                           Low : constant MIDI.MIDI_Key :=
                             MIDI.MIDI_Key (Integer (Key) - 12);
                        begin
                           Arp_Table_Set (State.Sounding, Low, Vel);
                           Emit (Channel, Low, Vel, True);
                        end;
                     end if;

                     if State.Octave_Up and then Integer (Key) <= 115 then
                        declare
                           High : constant MIDI.MIDI_Key :=
                             MIDI.MIDI_Key (Integer (Key) + 12);
                        begin
                           Arp_Table_Set (State.Sounding, High, Vel);
                           Emit (Channel, High, Vel, True);
                        end;
                     end if;
                  end Sound;

                  Idx : Natural;
               begin
                  case State.Style is
                     when Arp_Off => null;  --  unreachable, caught above

                     when Arp_Chord =>
                        for I in 0 .. Count - 1 loop
                           Sound (I);
                        end loop;

                     when Arp_Up =>
                        Idx := State.Step_Index mod Count;
                        Sound (Idx);
                        State.Step_Index := State.Step_Index + 1;

                     when Arp_Down =>
                        Idx := Count - 1 - (State.Step_Index mod Count);
                        Sound (Idx);
                        State.Step_Index := State.Step_Index + 1;

                     when Arp_Up_Down_Exclusive =>
                        if Count = 1 then
                           Idx := 0;
                        else
                           declare
                              Cycle : constant Natural := 2 * Count - 2;
                              Pos   : constant Natural :=
                                State.Step_Index mod Cycle;
                           begin
                              Idx := (if Pos < Count then Pos
                                     else Cycle - Pos);
                           end;
                        end if;
                        Sound (Idx);
                        State.Step_Index := State.Step_Index + 1;

                     when Arp_Up_Down_Inclusive =>
                        declare
                           Cycle : constant Natural := 2 * Count;
                           Pos   : constant Natural :=
                             State.Step_Index mod Cycle;
                        begin
                           Idx := (if Pos < Count then Pos
                                  else Cycle - 1 - Pos);
                        end;
                        Sound (Idx);
                        State.Step_Index := State.Step_Index + 1;

                     when Arp_Random =>
                        Idx := Natural (Arp_Next_Rnd mod UInt32 (Count));
                        Sound (Idx);
                        State.Step_Index := State.Step_Index + 1;
                  end case;
               end;
            end;
         end;
         <<Next_Channel>>
      end loop;
   end Arp_Tick;

end WNM.Looper;

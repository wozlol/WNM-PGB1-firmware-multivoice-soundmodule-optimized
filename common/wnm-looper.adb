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

   -----------------
   -- Event pool  --
   -----------------

   Pool_Size : constant := 4300;
   --  Picked with margin below the 4437 slots the Steps overlay actually
   --  holds (53248 bytes / 12 bytes a slot, both numbers read off a
   --  -gnatR2 dump rather than hand-counted), so a slightly different
   --  compiler layout still fits. The assertion below catches it either
   --  way instead of silently overlapping real data. For scale, the
   --  reference engine's own pool is 3072 events.

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
      Held_Reset (Overlay_Ptr.Record_Held);
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

end WNM.Looper;

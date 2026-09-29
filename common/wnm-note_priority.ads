-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
-------------------------------------------------------------------------------

with MIDI;

package WNM.Note_Priority is

   --  Last-note-priority mono retrig, modeled after the "legato" mode in
   --  the ARPnMIDI firmware: a monophonic voice always sounds the most
   --  recently pressed key, and when that key is released, if any other
   --  key is still physically held, the voice resumes that key instead of
   --  going silent. Releasing a held key that is not the one currently
   --  sounding has no audible effect. This makes trills (hold A, tap B
   --  repeatedly) work the way an analog mono synth's note priority does,
   --  instead of the voice dying the moment the newest key is released.

   Stack_Depth : constant := 4;

   type Instance is limited private;

   procedure Note_On (This     : in out Instance;
                      Key      :        MIDI.MIDI_Key;
                      Velocity :        MIDI.MIDI_Data);
   --  Record Key as held and as the currently sounding note. The caller
   --  still triggers the voice itself unconditionally, as before; this
   --  only updates the held-note bookkeeping used by Note_Off.

   type Off_Result_Kind is (No_Change, Silence, Retrigger);
   type Off_Result (Kind : Off_Result_Kind := No_Change) is record
      case Kind is
         when Retrigger =>
            Key      : MIDI.MIDI_Key;
            Velocity : MIDI.MIDI_Data;
         when No_Change | Silence =>
            null;
      end case;
   end record;

   procedure Note_Off (This   : in out Instance;
                       Key    :        MIDI.MIDI_Key;
                       Result :    out Off_Result);
   --  No_Change: Key was not the currently sounding note (or nothing was
   --             sounding), nothing for the caller to do.
   --  Silence:   Key was the currently sounding note and no other key is
   --             still held, the caller should send a real Note_Off.
   --  Retrigger: Key was the currently sounding note and another key is
   --             still held, the caller should retrigger the voice with
   --             Result.Key / Result.Velocity instead of releasing it.

private

   type Held_Entry is record
      Key      : MIDI.MIDI_Key    := 0;
      Velocity : MIDI.MIDI_Data   := 0;
   end record;

   type Held_Array is array (1 .. Stack_Depth) of Held_Entry;

   type Instance is record
      Held         : Held_Array := (others => <>);
      Count        : Natural range 0 .. Stack_Depth := 0;
      --  Held (1) is the oldest still-tracked key, Held (Count) the most
      --  recently pressed one.
      Sounding     : Boolean := False;
      Sounding_Key : MIDI.MIDI_Key := 0;
   end record;

end WNM.Note_Priority;

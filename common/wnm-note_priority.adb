-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
-------------------------------------------------------------------------------

package body WNM.Note_Priority is

   use type MIDI.MIDI_UInt8;

   procedure Remove (This : in out Instance; Key : MIDI.MIDI_Key);
   procedure Push (This : in out Instance; Key : MIDI.MIDI_Key;
                   Velocity : MIDI.MIDI_Data);

   ------------
   -- Remove --
   ------------

   procedure Remove (This : in out Instance; Key : MIDI.MIDI_Key) is
   begin
      for I in 1 .. This.Count loop
         if This.Held (I).Key = Key then
            if I < This.Count then
               This.Held (I .. This.Count - 1) :=
                 This.Held (I + 1 .. This.Count);
            end if;
            This.Count := This.Count - 1;
            return;
         end if;
      end loop;
   end Remove;

   ----------
   -- Push --
   ----------

   procedure Push (This : in out Instance; Key : MIDI.MIDI_Key;
                   Velocity : MIDI.MIDI_Data)
   is
   begin
      --  If already tracked (e.g. retriggered without an intervening
      --  Note_Off), drop it first so it moves back to the top.
      Remove (This, Key);

      if This.Count = Stack_Depth then
         --  Drop the oldest tracked key to make room.
         This.Held (1 .. Stack_Depth - 1) := This.Held (2 .. Stack_Depth);
         This.Count := This.Count - 1;
      end if;

      This.Count := This.Count + 1;
      This.Held (This.Count) := (Key => Key, Velocity => Velocity);
   end Push;

   -------------
   -- Note_On --
   -------------

   procedure Note_On (This     : in out Instance;
                      Key      :        MIDI.MIDI_Key;
                      Velocity :        MIDI.MIDI_Data)
   is
   begin
      Push (This, Key, Velocity);
      This.Sounding := True;
      This.Sounding_Key := Key;
   end Note_On;

   --------------
   -- Note_Off --
   --------------

   procedure Note_Off (This   : in out Instance;
                       Key    :        MIDI.MIDI_Key;
                       Result :    out Off_Result)
   is
   begin
      Remove (This, Key);

      if not This.Sounding or else This.Sounding_Key /= Key then
         --  Releasing a key that isn't the one currently sounding (either
         --  a shadowed held key, or a stray/duplicate Note_Off) has no
         --  audible effect.
         Result := (Kind => No_Change);
         return;
      end if;

      if This.Count = 0 then
         This.Sounding := False;
         Result := (Kind => Silence);
      else
         declare
            Top : constant Held_Entry := This.Held (This.Count);
         begin
            This.Sounding_Key := Top.Key;
            Result := (Kind     => Retrigger,
                       Key      => Top.Key,
                       Velocity => Top.Velocity);
         end;
      end if;
   end Note_Off;

end WNM.Note_Priority;

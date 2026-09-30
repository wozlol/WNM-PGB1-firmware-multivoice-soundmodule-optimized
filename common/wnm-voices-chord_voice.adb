-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--                     Copyright (C) 2023 Fabien Chouteau                    --
--                                                                           --
--    Wee Noise Maker is free software: you can redistribute it and/or       --
--    modify it under the terms of the GNU General Public License as         --
--    published by the Free Software Foundation, either version 3 of the     --
--    License, or (at your option) any later version.                        --
--                                                                           --
--    Wee Noise Maker is distributed in the hope that it will be useful,     --
--    but WITHOUT ANY WARRANTY; without even the implied warranty of         --
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU       --
--    General Public License for more details.                               --
--                                                                           --
--    You should have received a copy of the GNU General Public License      --
--    along with We Noise Maker. If not, see <http://www.gnu.org/licenses/>. --
--                                                                           --
-------------------------------------------------------------------------------

with Interfaces;

with Tresses.DSP;
with Tresses.Envelopes.AR; use Tresses.Envelopes.AR;
with Tresses.Resources; use Tresses.Resources;
with WNM.Synth;
with WNM.Voices.Chord_Wavetables;

package body WNM.Voices.Chord_Voice is

   use type Interfaces.Unsigned_16;

   subtype Wave_Range is Chord_Wavetables.Wave_Index;

   Wave_Count : constant Param_Range :=
     Param_Range (Wave_Range'Last) + 1;

   function Wave_Name (W : Wave_Range) return String
   is (case W is
          when 0  => "Sine",
          when 1  => "Sine Warp 1",
          when 2  => "Sine Warp 2",
          when 3  => "Sine Warp 3",
          when 4  => "Triangle",
          when 5  => "Sawtooth",
          when 6  => "Pulse 25%",
          when 7  => "Pulse 50%",
          when 8  => "Chip Triangle",
          when 9  => "Screech",
          when 10 => "Sine + Saw",
          when 11 => "Tri + Sine",
          when 12 => "Square + Sine");

   function Current_Wave (This : Instance) return Wave_Range;

   ------------------
   -- Current_Wave --
   ------------------

   function Current_Wave (This : Instance) return Wave_Range is
      Mod_Param : constant Param_Range :=
        This.Params (P_Waveform) / (Param_Range'Last / Wave_Count);
   begin
      return Wave_Range
        (Param_Range'Min (Mod_Param, Param_Range (Wave_Range'Last)));
   end Current_Wave;

   -----------------
   -- Param_Label --
   -----------------

   overriding
   function Param_Label (This : Instance; Id : Param_Id) return String
   is (case Id is
          when P_Waveform => (if This.Engine /= Custom_Waveform
                              then Wave_Name (Current_Wave (This))
                              else "-Unused-"),
          when P_Glide    => "Glide",
          when P_Attack   => "Attack",
          when P_Release  => "Release");

   ------------
   -- Engine --
   ------------

   function Engine (This : Instance) return Chord_Engine
   is (This.Engine);

   ----------------
   -- Set_Engine --
   ----------------

   procedure Set_Engine (This : in out Instance; E : Chord_Engine) is
   begin
      pragma Warnings (Off, "can only be True");
      if This.Engine /= E then
         This.Engine := E;
         This.Do_Init := True;
      end if;
      pragma Warnings (On, "can only be True");
   end Set_Engine;

   -----------------------
   -- Set_Active_Voices --
   -----------------------

   procedure Set_Active_Voices (This : in out Instance;
                                N    :        Positive)
   is
   begin
      This.Active_Voices := Voice_Id (N);
   end Set_Active_Voices;

   ----------
   -- Init --
   ----------

   procedure Init (This : in out Instance) is
   begin
      for V of This.Voices loop
         V.On := False;
         V.Phase := 0;
         V.Age := 0;
         V.Pending := False;
         V.Pending_Wait := 0;
         V.Drain := Drain_Count'Last;
         Envelopes.AR.Init (V.Env, Do_Hold => True);
      end loop;
      This.Next_Age := 0;
      This.Shadow_Count := 0;
   end Init;

   ---------------
   -- Bent_Incr --
   ---------------

   function Bent_Incr (Key : MIDI.MIDI_Key; Bend : Tresses.S16) return U32 is
      P : constant Integer :=
        Integer (Tresses.MIDI_Pitch (Key)) + Integer (Bend);
      Clamped : constant Integer :=
        Integer'Max (Integer (Tresses.Pitch_Range'First),
                     Integer'Min (Integer (Tresses.Pitch_Range'Last), P));
   begin
      return DSP.Compute_Phase_Increment (S16 (Clamped));
   end Bent_Incr;

   --------------
   -- Set_Bend --
   --------------

   procedure Set_Bend (This : in out Instance; Offset : Tresses.S16) is
      use type Interfaces.Integer_16;
   begin
      if Offset = This.Bend then
         return;
      end if;

      This.Bend := Offset;

      --  Retune what is already sounding. A voice still waiting on a
      --  pending reassignment is left alone, it picks the bend up when it
      --  resolves.
      for V of This.Voices loop
         if not V.Pending and then V.Drain /= Drain_Count'Last then
            V.Current_Phase_Incr := Bent_Incr (V.Note, Offset);
         end if;
      end loop;
   end Set_Bend;

   ----------------
   -- Voice_Wave --
   ----------------

   function Voice_Wave (This : Instance;
                        Wave_Select : Wave_Range;
                        V : Voice_Id)
                        return Chord_Wavetables.Table_Access
   is
      Mix_Sel : constant Wave_Range :=
        Wave_Range ((U32 (Wave_Select) + U32 (V)) mod
                      (U32 (Wave_Range'Last) + 1));

      --  Band-limited copy matching this voice's sounding pitch, so the
      --  harmonics that would fold back as inharmonic fizz are already
      --  gone.
      Zone : constant Chord_Wavetables.Zone_Index := This.Voices (V).Zone;
   begin
      return (if This.Engine = Mixed_Waveforms
              then Chord_Wavetables.Tables (Mix_Sel, Zone)
              else Chord_Wavetables.Tables (Wave_Select, Zone));
   end Voice_Wave;

   ---------------------
   -- Interpolate1024 --
   ---------------------

   function Interpolate1024 (T     : Chord_Wavetables.Table_1025_S16;
                             Phase :  U32)
                             return S16
   is
      --  Same two-point interpolation as Tresses does on its 257-point
      --  tables, just with 10 bits of index and 15 of the 22 remaining
      --  fraction bits. Four times the grid means a sixteenth of the
      --  interpolation error, which is where the extra purity comes from,
      --  and it costs no more work than the coarse version.
      P : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Phase / 2**22);
      A : constant S32 := S32 (T (P));
      B : constant S32 := S32 (T (P + 1));
      V : constant S32 := S32 ((Phase / 2**7) mod 2**15);
   begin
      return S16 (A + ((B - A) * V) / 2**15);
   end Interpolate1024;

   ------------
   -- Render --
   ------------

   procedure Render (This   : in out Instance;
                     Buffer :    out Tresses.Mono_Buffer)
   is

      Wave_Select : constant Wave_Range := Current_Wave (This);

      Bend_Now : constant Tresses.S16 := This.Bend;

      --  The user's own waveform is drawn at run time, so there is no
      --  precomputed fine-grained copy of it and it keeps reading the
      --  coarse table it always did.
      Custom : constant Boolean := This.Engine = Custom_Waveform;

      Voice_Waveform : array (Voice_Id) of Chord_Wavetables.Table_Access :=
        (others => Chord_Wavetables.Tables
           (Wave_Range'First, Chord_Wavetables.Zone_Index'First));

      Sample : S32;

      All_Dead : Boolean := True;

      function Voice_Sample (V : in out Voice; Raw : S16) return S32
      is
      begin
         --  Callers skip fully silent voices entirely, so reaching here
         --  means this voice still has something to contribute. If its
         --  envelope has reached Dead, keep counting down the samples the
         --  envelope's output smoother needs to finish decaying, otherwise
         --  the tail gets cut off mid-decay. See Drain.
         if not V.On and then not V.Pending
           and then Envelopes.AR.Current_Segment (V.Env) =
                      Envelopes.AR.Dead
         then
            V.Drain := V.Drain + 1;
         end if;

         --  A voice being reassigned (stolen, or revived from the shadow
         --  queue) can't just wait for its outgoing note to release, that
         --  would defeat the point of stealing. But switching pitch and
         --  re-triggering the envelope immediately can pop: the outgoing
         --  note could be at any waveform value and any envelope level. So
         --  instead the outgoing note keeps rendering completely normally
         --  until its own waveform comes near zero (Pending_Wait bounds how
         --  long we wait, in case an unusual waveform rarely comes near
         --  zero), and only then do we actually switch to the new pitch and
         --  trigger its envelope.
         if V.Pending then
            if abs Integer (Raw) <= Integer (Near_Zero)
              or else V.Pending_Wait >= Max_Pending_Wait
            then
               --  Glide was tried here (stepping toward the new pitch
               --  gradually) and pulled back out: it added per-sample cost
               --  to every voice and caused audible artifacts. Snap
               --  directly for now, revisit glide later as its own focused
               --  pass. Note/Velocity are already the new note's values,
               --  set by Request_Note the moment this voice was assigned.
               V.Current_Phase_Incr := Bent_Incr (V.Note, Bend_Now);
               V.Zone := Chord_Wavetables.Zone_Of_Key (V.Note);

               Envelopes.AR.On (V.Env, V.Velocity);
               V.Pending := False;
            else
               V.Pending_Wait := V.Pending_Wait + 1;
            end if;
         end if;

         Envelopes.AR.Render (V.Env);
         return (S32 (Raw) * Low_Pass (V.Env)) / 2**15;
      end Voice_Sample;

   begin

      if This.Do_Init then
         This.Do_Init := False;
         This.Init;
      end if;

      if not Custom then
         for I in Voice_Id loop
            Voice_Waveform (I) := Voice_Wave (This, Wave_Select, I);
         end loop;
      end if;

      for V of This.Voices loop
         Set_Attack (V.Env, This.Params (P_Attack));
         Set_Release (V.Env, This.Params (P_Release));
         --  Drain short of its limit is the one condition that means this
         --  voice can still contribute audio, and it covers every such
         --  case: Request_Note zeroes it for each new note, so a held,
         --  releasing, pending or still-draining voice all read as not
         --  dead, and only a voice that has finished draining reads as
         --  dead. Getting this wrong silences the whole buffer and so
         --  strands whatever still had to be rendered.
         if V.Drain /= Drain_Count'Last then
            All_Dead := False;
         end if;
      end loop;

      if All_Dead then
         Buffer := (others => 0);
      else
         for Elt of Buffer loop
            Sample := 0;
            for I in Voice_Id loop
               declare
                  V : Voice renames This.Voices (I);
               begin
                  V.Phase := V.Phase + V.Current_Phase_Incr;

                  --  Skip voices that have gone fully silent, so neither
                  --  the table read nor the envelope work is done for them.
                  if V.Drain /= Drain_Count'Last then
                     declare
                        Raw : constant S16 :=
                          (if Custom
                           then DSP.Interpolate824
                                  (WNM.Synth.User_Waveform, V.Phase)
                           else Interpolate1024
                                  (Voice_Waveform (I).all, V.Phase));
                     begin
                        Sample := Sample + Voice_Sample (V, Raw);
                     end;
                  end if;
               end;
            end loop;

            --  Fixed divisor rather than the configured voice count, so
            --  changing the voice count doesn't change how loud a single
            --  note is, and so one held note keeps its full resolution
            --  instead of being scaled down and then back up. Matches
            --  stock loudness. Clip_S16 covers the rare case of several
            --  voices peaking in phase together.
            Sample := Sample / 4;
            Elt := S16 (DSP.Clip_S16 (Sample));
         end loop;
      end if;
   end Render;

   ------------------
   -- Request_Note --
   ------------------

   procedure Request_Note (This     : in out Instance;
                           Id       :        Voice_Id;
                           Key      :        MIDI.MIDI_Key;
                           Velocity :        Tresses.Param_Range)
   is
      V : Voice renames This.Voices (Id);
   begin
      --  Bookkeeping (which note this voice belongs to, voice-stealing
      --  age, held state) updates immediately: Key_Off matching and
      --  Key_On's oldest-voice search both need this to be current right
      --  away. Only the audio-level pitch/envelope switch is deferred,
      --  to a safe near-zero point in the outgoing waveform (see
      --  Voice_Sample), so instant note-stealing feedback doesn't pop.
      V.Note := Key;
      V.Velocity := Velocity;
      V.On := True;
      V.Age := This.Next_Age;
      This.Next_Age := This.Next_Age + 1;

      V.Pending := True;
      V.Pending_Wait := 0;
      V.Drain := 0;
   end Request_Note;

   -----------------
   -- Push_Shadow --
   -----------------

   procedure Push_Shadow (This     : in out Instance;
                          Key      :        MIDI.MIDI_Key;
                          Velocity :        Tresses.Param_Range)
   is
      use type MIDI.MIDI_UInt8;
   begin
      for I in 1 .. This.Shadow_Count loop
         if This.Shadow (I).Key = Key then
            --  Already tracked (shouldn't normally happen), don't
            --  duplicate.
            return;
         end if;
      end loop;

      if This.Shadow_Count = Shadow_Depth then
         --  Forget the oldest shadow note to make room.
         This.Shadow (1 .. Shadow_Depth - 1) :=
           This.Shadow (2 .. Shadow_Depth);
         This.Shadow_Count := This.Shadow_Count - 1;
      end if;

      This.Shadow_Count := This.Shadow_Count + 1;
      This.Shadow (This.Shadow_Count) := (Key => Key, Velocity => Velocity);
   end Push_Shadow;

   -------------------
   -- Remove_Shadow --
   -------------------

   function Remove_Shadow (This : in out Instance; Key : MIDI.MIDI_Key)
                           return Boolean
   is
      use type MIDI.MIDI_UInt8;
   begin
      for I in 1 .. This.Shadow_Count loop
         if This.Shadow (I).Key = Key then
            if I < This.Shadow_Count then
               This.Shadow (I .. This.Shadow_Count - 1) :=
                 This.Shadow (I + 1 .. This.Shadow_Count);
            end if;
            This.Shadow_Count := This.Shadow_Count - 1;
            return True;
         end if;
      end loop;
      return False;
   end Remove_Shadow;

   ------------
   -- Key_On --
   ------------

   procedure Key_On (This     : in out Instance;
                     Key      :       MIDI.MIDI_Key;
                     Velocity :       Tresses.Param_Range)
   is
      Oldest : Voice_Id := Voice_Id'First;
   begin

      --  Try to find a free voice, among only the currently active ones:
      --  voices beyond Active_Voices are never assigned a note.
      for Id in Voice_Id'First .. This.Active_Voices loop
         if not This.Voices (Id).On then
            Request_Note (This, Id, Key, Velocity);
            return;
         end if;
      end loop;

      --  All active voices are in use: steal the oldest one for instant
      --  feedback, but remember the note it was playing so it can be
      --  revived into the next voice that frees up (see Shadow_Depth).
      for Id in Voice_Id'First .. This.Active_Voices loop
         if This.Voices (Id).Age < This.Voices (Oldest).Age then
            Oldest := Id;
         end if;
      end loop;

      Push_Shadow (This,
                   This.Voices (Oldest).Note,
                   This.Voices (Oldest).Velocity);
      Request_Note (This, Oldest, Key, Velocity);
   end Key_On;

   --------------
   -- Key_Off --
   --------------

   procedure Key_Off (This : in out Instance;
                       Key  :        MIDI.MIDI_Key)
   is
      use MIDI;
   begin
      --  A shadow (held but never sounding, voice-stolen) note being
      --  released has no audio effect: just stop tracking it.
      if Remove_Shadow (This, Key) then
         return;
      end if;

      for Id in Voice_Id'First .. This.Active_Voices loop
         if This.Voices (Id).On and then This.Voices (Id).Note = Key then
            This.Voices (Id).On := False;

            if This.Shadow_Count > 0 then
               --  Another note is waiting because it got voice-stolen
               --  while still held: revive it into this freed voice
               --  right away (with its own fresh Attack), like a classic
               --  poly synth's note memory, instead of releasing this
               --  voice.
               declare
                  Next : constant Shadow_Entry :=
                    This.Shadow (This.Shadow_Count);
               begin
                  This.Shadow_Count := This.Shadow_Count - 1;
                  Request_Note (This, Id, Next.Key, Next.Velocity);
               end;
            else
               --  Let this voice's own envelope handle the fade-out: it
               --  is a continuous amplitude multiplier, so there is no
               --  discontinuity to click regardless of where in the
               --  waveform's cycle release happens, and it follows the
               --  same Attack/Release settings as every other voice.
               Envelopes.AR.Off (This.Voices (Id).Env);
            end if;
            exit;
         end if;
      end loop;
   end Key_Off;

end WNM.Voices.Chord_Voice;

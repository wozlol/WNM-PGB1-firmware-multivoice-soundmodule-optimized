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

with Tresses.DSP;
with Tresses.Envelopes.AR; use Tresses.Envelopes.AR;
with Tresses.Resources; use Tresses.Resources;
with WNM.Synth;

package body WNM.Voices.Chord_Voice is

   type Wave_Range is range 0 .. 12;
   Waveforms : constant array (Wave_Range) of
     not null access constant Table_257_S16
       := (WAV_Sine'Access,
           WAV_Sine_Warp1'Access,
           WAV_Sine_Warp2'Access,
           WAV_Sine_Warp3'Access,
           WAV_Triangle'Access,
           WAV_Sawtooth'Access,
           WAV_Chip_Pulse_25'Access,
           WAV_Chip_Pulse_50'Access,
           WAV_Chip_Triangle'Access,
           WAV_Screech'Access,
           WAV_Combined_Sin_Saw'Access,
           WAV_Combined_Trig_Sin'Access,
           WAV_Combined_Square_Sin'Access);

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
         Envelopes.AR.Init (V.Env, Do_Hold => True);
      end loop;
      This.Next_Age := 0;
      This.Shadow_Count := 0;
   end Init;

   ----------------
   -- Voice_Wave --
   ----------------

   function Voice_Wave (This : Instance;
                        Wave_Select : Wave_Range;
                        V : Voice_Id)
                        return not null access constant Table_257_S16
   is
      Mix_Sel : constant Wave_Range :=
        Wave_Range ((U32 (Wave_Select) + U32 (V)) mod
                      (U32 (Wave_Range'Last) + 1));
   begin
      return (case This.Engine is
                 when Waveform        => Waveforms (Wave_Select),
                 when Mixed_Waveforms => Waveforms (Mix_Sel),
                 when Custom_Waveform => WNM.Synth.User_Waveform'Access);
   end Voice_Wave;

   ------------
   -- Render --
   ------------

   procedure Render (This   : in out Instance;
                     Buffer :    out Tresses.Mono_Buffer)
   is

      Mod_Param : constant Param_Range :=
        This.Params (P_Waveform) / (Param_Range'Last / Waveforms'Length);

      Wave_Select : constant Wave_Range :=
        Wave_Range
          (Param_Range'Min (Mod_Param, Param_Range (Wave_Range'Last)));

      Waveform_1 : constant not null access constant Table_257_S16 :=
        Voice_Wave (This, Wave_Select, 1);
      Waveform_2 : constant not null access constant Table_257_S16 :=
        Voice_Wave (This, Wave_Select, 2);
      Waveform_3 : constant not null access constant Table_257_S16 :=
        Voice_Wave (This, Wave_Select, 3);
      Waveform_4 : constant not null access constant Table_257_S16 :=
        Voice_Wave (This, Wave_Select, 4);

      Sample : S32;

      All_Dead : Boolean := True;
   begin

      if This.Do_Init then
         This.Do_Init := False;
         This.Init;
      end if;

      for V of This.Voices loop
         Set_Attack (V.Env, This.Params (P_Attack));
         Set_Release (V.Env, This.Params (P_Release));
         --  A voice with a pending note (its envelope hasn't been
         --  triggered yet, that only happens once its Pending transition
         --  resolves inside the per-sample loop below) must still count
         --  as "not dead" here, or the per-sample loop that would
         --  actually resolve it never runs and the voice is stuck silent.
         if V.Pending
           or else Envelopes.AR.Current_Segment (V.Env) /= Envelopes.AR.Dead
         then
            All_Dead := False;
         end if;
      end loop;

      if All_Dead then
         Buffer := (others => 0);
      else

         declare
            V1 : Voice renames This.Voices (Voice_Id'First + 0);
            V2 : Voice renames This.Voices (Voice_Id'First + 1);
            V3 : Voice renames This.Voices (Voice_Id'First + 2);
            V4 : Voice renames This.Voices (Voice_Id'First + 3);

            S1, S2, S3, S4 : S32;

            function Voice_Sample
              (V        : in out Voice;
               Waveform : not null access constant Table_257_S16)
               return S32
            is
            begin
               --  A voice that isn't held, isn't waiting on a pending
               --  reassignment, and has fully finished its own envelope
               --  is contributing nothing: skip the waveform lookup and
               --  envelope processing for it entirely instead of doing
               --  that work uselessly every sample. With 4 independent
               --  per-voice envelopes now, doing this for genuinely idle
               --  voices adds up and risked missing the audio deadline,
               --  which sounds like a "random" pop unrelated to any
               --  particular note event.
               if not V.On and then not V.Pending
                 and then Envelopes.AR.Current_Segment (V.Env) =
                            Envelopes.AR.Dead
               then
                  return 0;
               end if;

               declare
                  Raw : constant S16 :=
                    DSP.Interpolate824 (Waveform.all, V.Phase);
               begin
                  --  A voice being reassigned (stolen, or revived from the
                  --  shadow queue) can't just wait for its outgoing note
                  --  to release, that would defeat the point of stealing.
                  --  But switching pitch and re-triggering the envelope
                  --  immediately can pop: the outgoing note could be at
                  --  any waveform value and any envelope level. So instead
                  --  the outgoing note keeps rendering completely normally
                  --  until its own waveform comes near zero (Pending_Wait
                  --  bounds how long we wait, in case an unusual waveform
                  --  rarely comes near zero), and only then do we actually
                  --  switch to the new pitch and trigger its envelope.
                  if V.Pending then
                     if abs Integer (Raw) <= Integer (Near_Zero)
                       or else V.Pending_Wait >= Max_Pending_Wait
                     then
                        V.Target_Phase_Incr :=
                          DSP.Compute_Phase_Increment
                            (S16 (Tresses.MIDI_Pitch (V.Pending_Key)));
                        --  Glide was tried here (stepping toward Target
                        --  gradually) and pulled back out: it added
                        --  per-sample cost to every voice and caused
                        --  audible artifacts. Snap directly for now;
                        --  revisit glide later as its own focused pass.
                        V.Current_Phase_Incr := V.Target_Phase_Incr;

                        Envelopes.AR.On (V.Env, V.Pending_Velocity);
                        V.Pending := False;
                     else
                        V.Pending_Wait := V.Pending_Wait + 1;
                     end if;
                  end if;

                  Envelopes.AR.Render (V.Env);
                  return (S32 (Raw) * Low_Pass (V.Env)) / 2 ** 15;
               end;
            end Voice_Sample;
         begin
            for Elt of Buffer loop

               V1.Phase := V1.Phase + V1.Current_Phase_Incr;
               V2.Phase := V2.Phase + V2.Current_Phase_Incr;
               V3.Phase := V3.Phase + V3.Current_Phase_Incr;
               V4.Phase := V4.Phase + V4.Current_Phase_Incr;

               S1 := Voice_Sample (V1, Waveform_1);
               S2 := Voice_Sample (V2, Waveform_2);
               S3 := Voice_Sample (V3, Waveform_3);
               S4 := Voice_Sample (V4, Waveform_4);

               Sample := (S1 + S2 + S3 + S4) / 4;

               Elt := S16 (DSP.Clip_S16 (Sample));
            end loop;
         end;
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
      V.Pending_Key := Key;
      V.Pending_Velocity := Velocity;
      V.Pending_Wait := 0;
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

      --  Try to find a free voice
      for Id in This.Voices'Range loop
         if not This.Voices (Id).On then
            Request_Note (This, Id, Key, Velocity);
            return;
         end if;
      end loop;

      --  All voices are in use: steal the oldest one for instant
      --  feedback, but remember the note it was playing so it can be
      --  revived into the next voice that frees up (see Shadow_Depth).
      for Id in This.Voices'Range loop
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

      for Id in This.Voices'Range loop
         if This.Voices (Id).On and then This.Voices (Id).Note = Key then
            This.Voices (Id).On := False;

            if This.Shadow_Count > 0 then
               --  Another note is waiting because it got voice-stolen
               --  while still held: revive it into this freed voice
               --  right away (with its own fresh Attack), like a classic
               --  4-voice poly synth's note memory, instead of releasing
               --  this voice.
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

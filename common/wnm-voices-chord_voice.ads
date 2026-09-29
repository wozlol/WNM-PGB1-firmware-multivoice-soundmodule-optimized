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

with Tresses;            use Tresses;
with Tresses.Interfaces; use Tresses.Interfaces;

private with Tresses.Envelopes.AR;

package WNM.Voices.Chord_Voice is

   type Instance
   is new Four_Params_Voice
   with private;

   type Chord_Engine is (Waveform,  Mixed_Waveforms, Custom_Waveform);

   function Engine (This : Instance) return Chord_Engine;
   procedure Set_Engine (This : in out Instance; E : Chord_Engine);

   function Img (E : Chord_Engine) return String
   is (case E is
          when Waveform        => "Waveforms",
          when Mixed_Waveforms => "Mixed Waveforms",
          when Custom_Waveform => "Custom Waveform");

   procedure Init (This : in out Instance);

   procedure Render (This   : in out Instance;
                     Buffer :    out Tresses.Mono_Buffer);

   procedure Key_On (This     : in out Instance;
                     Key      :        MIDI.MIDI_Key;
                     Velocity :        Tresses.Param_Range);

   procedure Key_Off (This : in out Instance;
                      Key  :        MIDI.MIDI_Key);

   P_Waveform : constant Tresses.Param_Id := 1;
   P_Glide    : constant Tresses.Param_Id := 2;
   P_Attack   : constant Tresses.Param_Id := 3;
   P_Release  : constant Tresses.Param_Id := 4;

   --  Interfaces --

   overriding
   function Param_Label (This : Instance; Id : Param_Id) return String
   is (case Id is
          when P_Waveform => (if This.Engine /= Custom_Waveform
                              then "Waveform"
                              else "-Unused-"),
          when P_Glide    => "Glide",
          when P_Attack   => "Attack",
          when P_Release  => "Release");

   overriding
   function Param_Short_Label (This : Instance; Id : Param_Id)
                               return Short_Label
   is (case Id is
          when P_Waveform => (if This.Engine /= Custom_Waveform
                              then "WAV"
                              else "---"),
          when P_Glide    => "GLD",
          when P_Attack   => "ATK",
          when P_Release  => "REL");

private

   type Voice is record
      On       : Boolean;
      --  Whether the key for this voice is currently physically held.
      --  Decoupled from amplitude: this voice's own Env keeps rendering
      --  (and decaying through its Release stage) even after On goes
      --  False, and this voice only becomes eligible for a new note once
      --  On is False, regardless of whether Env has finished decaying.
      Note     : MIDI.MIDI_Key;
      Velocity : Tresses.Param_Range;

      Phase              : U32;
      Current_Phase_Incr : U32;
      Target_Phase_Incr  : U32;
      --  Glide is a simple one-pole approach of Current toward Target,
      --  stepped every sample in Render (see Glide_Step in the body): no
      --  separate envelope or "start" point needed, keeping this cheap in
      --  both CPU and RAM with 4 independent voices.

      Age : U32;
      --  Monotonic timestamp used to find the oldest active voice when
      --  stealing is needed.

      Env : Tresses.Envelopes.AR.Instance;
      --  Each voice has its own independent Attack/Release envelope, so
      --  releasing one note out of a held chord fades only that note,
      --  smoothly and click-free (an envelope is a continuous amplitude
      --  multiplier, so there is no discontinuity to click regardless of
      --  where in the waveform's cycle release happens), following the
      --  same Attack/Release settings as every other voice.

      Pending          : Boolean := False;
      Pending_Key      : MIDI.MIDI_Key := 0;
      Pending_Velocity : Tresses.Param_Range := 0;
      Pending_Wait     : U32 := 0;
      --  When this voice is stolen for a new note, we can't just wait for
      --  its current note to release (that would defeat the point of
      --  stealing), but switching pitch and re-triggering the envelope
      --  immediately can pop: the outgoing note could be at any waveform
      --  value and any envelope level. Instead the outgoing note keeps
      --  playing completely normally until its own waveform comes near
      --  zero (Pending_Wait bounds how long we wait, in case an unusual
      --  waveform rarely comes near zero), and only then does the actual
      --  switch to Pending_Key/Pending_Velocity happen.
   end record;

   Near_Zero        : constant S16 := 800;
   Max_Pending_Wait : constant := 3_000;
   --  ~94ms at 32kHz: a safety net so an unusual waveform that rarely
   --  comes near zero can't delay a steal indefinitely.

   Chord_Voices : constant := 4;
   type Voice_Id is range 1 .. Chord_Voices;
   type Voice_Array is array (Voice_Id) of Voice;

   Shadow_Depth : constant := 4;
   --  A key pressed beyond the 4 physical voices steals the oldest one
   --  immediately (for instant feedback), but the note it stole from is
   --  remembered here rather than simply forgotten: if its key is still
   --  held down, it gets revived (with its own fresh Attack, like any
   --  other new note) into the next voice that frees up, instead of
   --  staying silent forever. This is how a classic 4-voice poly synth's
   --  note memory behaves.

   type Shadow_Entry is record
      Key      : MIDI.MIDI_Key      := 0;
      Velocity : Tresses.Param_Range := 0;
   end record;
   type Shadow_Array is array (1 .. Shadow_Depth) of Shadow_Entry;

   type Instance
   is new Four_Params_Voice
   with record
      Next_Age : U32 := 0;

      Voices : Voice_Array;

      Shadow       : Shadow_Array := (others => <>);
      Shadow_Count : Natural range 0 .. Shadow_Depth := 0;

      Engine : Chord_Engine := Chord_Engine'First;

      Do_Init : Boolean := True;
   end record;

end WNM.Voices.Chord_Voice;

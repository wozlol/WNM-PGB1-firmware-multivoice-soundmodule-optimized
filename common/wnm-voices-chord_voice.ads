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
private with WNM.Voices.Chord_Wavetables;

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

   Max_Chord_Voices : constant := 5;
   --  RAM-limited: each voice carries its own independent envelope (for
   --  click-free per-note release), and this is the most that fit
   --  alongside everything else already in RAM. Going higher would mean
   --  shrinking the shared envelope engine every instrument uses, a
   --  separate, larger change.

   procedure Set_Active_Voices (This : in out Instance;
                                N    :        Positive)
     with Pre => N in 1 .. Max_Chord_Voices;
   --  How many of the (up to Max_Chord_Voices) physical voices are
   --  actually usable. Voices beyond this count are never assigned a
   --  note and stay silent. Defaults to 4.

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
   function Param_Label (This : Instance; Id : Param_Id) return String;
   --  For the waveform param this is the name of the currently selected
   --  waveform rather than the word "Waveform", so the screen says what
   --  the knob is actually sitting on.

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

   Drain_Samples : constant := 16;
   --  The envelope's own one-pole output smoother (Envelopes.AR.Low_Pass)
   --  converges halfway to the envelope value per sample, and reaching
   --  the Dead segment zeroes that value but leaves the smoother holding
   --  a nonzero residue. 16 halvings take any 16-bit residue below one
   --  LSB, so after that many samples the voice really is silent and can
   --  safely stop being rendered. See Drain in Voice below.

   type Drain_Count is range 0 .. Drain_Samples;

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

      Age : U16;
      --  Monotonic timestamp used to find the oldest active voice when
      --  stealing is needed. 16-bit to save RAM across 8 voices: a wrap
      --  only risks picking a slightly-not-oldest voice to steal, never
      --  a functional break.

      Zone : Chord_Wavetables.Zone_Index := 0;
      --  Which band-limited copy of the waveform this voice reads, picked
      --  from the pitch that is actually sounding. Set at the same moment
      --  as Current_Phase_Incr, never from Note directly, because during a
      --  steal Note is already the incoming note while the outgoing one is
      --  still sounding, and swapping the table out from under it would
      --  click. Declared here so it lands in padding the record already
      --  had, costing no RAM.

      Env : Tresses.Envelopes.AR.Instance;
      --  Each voice has its own independent Attack/Release envelope, so
      --  releasing one note out of a held chord fades only that note,
      --  smoothly and click-free (an envelope is a continuous amplitude
      --  multiplier, so there is no discontinuity to click regardless of
      --  where in the waveform's cycle release happens), following the
      --  same Attack/Release settings as every other voice.

      Drain : Drain_Count := Drain_Count'Last;
      --  Counts the samples rendered since this voice's envelope reached
      --  Dead. Until it reaches Drain_Samples the voice keeps being
      --  rendered so the envelope's output smoother can finish decaying
      --  on its own. Cutting it off early instead leaves a step down to
      --  zero at the end of the note, and leaves a stale nonzero
      --  smoother value that the next note on this voice would start
      --  from, both of which are audible clicks. Starts out already
      --  drained, and Request_Note resets it for each new note.

      Pending      : Boolean := False;
      Pending_Wait : U16 := 0;
      --  When this voice is stolen for a new note, we can't just wait for
      --  its current note to release (that would defeat the point of
      --  stealing), but switching pitch and re-triggering the envelope
      --  immediately can pop: the outgoing note could be at any waveform
      --  value and any envelope level. Instead the outgoing note keeps
      --  playing completely normally until its own waveform comes near
      --  zero (Pending_Wait bounds how long we wait, in case an unusual
      --  waveform rarely comes near zero), and only then does the actual
      --  switch to Note/Velocity (already updated immediately by
      --  Request_Note) happen.
   end record;

   Near_Zero        : constant S16 := 800;
   Max_Pending_Wait : constant := 3_000;
   --  ~94ms at 32kHz: a safety net so an unusual waveform that rarely
   --  comes near zero can't delay a steal indefinitely.

   Chord_Voices : constant := Max_Chord_Voices;
   type Voice_Id is range 1 .. Chord_Voices;
   type Voice_Array is array (Voice_Id) of Voice;

   Shadow_Depth : constant := 4;
   --  A key pressed beyond the currently active physical voices steals
   --  the oldest one immediately (for instant feedback), but the note it
   --  stole from is remembered here rather than simply forgotten: if its
   --  key is still held down, it gets revived (with its own fresh
   --  Attack, like any other new note) into the next voice that frees
   --  up, instead of staying silent forever. This is how a classic poly
   --  synth's note memory behaves.

   type Shadow_Entry is record
      Key      : MIDI.MIDI_Key      := 0;
      Velocity : Tresses.Param_Range := 0;
   end record;
   type Shadow_Array is array (1 .. Shadow_Depth) of Shadow_Entry;

   type Instance
   is new Four_Params_Voice
   with record
      Next_Age : U16 := 0;

      Voices : Voice_Array;

      Shadow       : Shadow_Array := (others => <>);
      Shadow_Count : Natural range 0 .. Shadow_Depth := 0;

      Active_Voices : Voice_Id := Voice_Id'Last;

      Engine : Chord_Engine := Chord_Engine'First;

      Do_Init : Boolean := True;
   end record;

end WNM.Voices.Chord_Voice;

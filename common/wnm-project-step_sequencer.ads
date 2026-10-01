-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--                     Copyright (C) 2022 Fabien Chouteau                    --
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

with WNM.UI;
with MIDI.Time;

package WNM.Project.Step_Sequencer is

   function Playing_Step (T : Tracks) return Playhead;

   procedure Play_Pause;
   --  Use it to signal a play/pause event

   procedure On_Press (Button : Keyboard_Button;
                       Mode : WNM.UI.Main_Modes);

   procedure MIDI_Clock_Tick (Step : MIDI.Time.Step_Count);

   function Keyboard_Octave return Octave_Offset;
   procedure Set_Keyboard_Octave (O : Octave_Offset);

   function Offset_Key (K : MIDI.MIDI_Key; Oct : Octave_Offset)
                        return MIDI.MIDI_Key;
   --  K moved by Oct octaves, clamped to the MIDI range rather than
   --  wrapping. Exposed so Looper mode offsets a note by a track's octave
   --  the same way this package already does.

   function Keyboard_Key (Button : Keyboard_Button;
                          T      : Tracks) return MIDI.MIDI_Key;
   --  The note this pad plays on the chromatic keyboard layout, with both
   --  the current keyboard octave and the track's own octave offset
   --  already applied, exactly as playing a pad in Track mode does. B1,
   --  B4 and B8 are that layout's octave controls and have no note of
   --  their own, so they answer C4. Exposed so Looper mode plays the same
   --  layout from its own keypad handling instead of repeating the
   --  mapping.

private

   Current_Playing_Step : Sequencer_Steps := Sequencer_Steps'First with Atomic;

   --  Current_Seq_State : Sequencer_State := Pause with Atomic;
   Current_Track     : Tracks := Tracks'First with Atomic;

   procedure Execute_Step;

end WNM.Project.Step_Sequencer;

-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--                  Copyright (C) 2016-2017 Fabien Chouteau                  --
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

with WNM.Project;
with WNM.Project.Step_Sequencer;
with WNM.Project.Song_Part_Sequencer;
with WNM.MIDI_Clock; use WNM.MIDI_Clock;
with WNM.GUI.Menu;
with WNM.GUI.Menu.Root;
with WNM.LEDs;
with WNM.Time;
with WNM.UI.Logs;
with WNM.Audio_Routing;
with WNM.Voices.Auto_Filter_FX;
with WNM.Voices.Stutter_FX;
with WNM.Mixer;
with WNM.Looper;
with WNM.Synth;

with HAL; use HAL;

with WNM.GUI.Popup;

package body WNM.UI is

   use type WNM.Project.Sequencer_Mode_Kind;

   procedure Signal_Event (B : Button; Evt : Button_Event);

   procedure Toggle_FX (B : Keyboard_Button);
   procedure Toggle_Mute (Track : WNM.Tracks);
   procedure Toggle_Solo (Track : WNM.Tracks);
   function In_Solo return Boolean;
   function Solo return WNM.Tracks;

   Last_Main_Mode : Main_Modes := Track_Mode;
   Current_Input_Mode : Input_Mode_Type := Last_Main_Mode;

   Select_Done : Boolean := False;

   Recording_On : Boolean := False;
   Chroma_Keyboard_On : Boolean := False;

   --  Edit is the faceplate name for the button this code calls Rec: the
   --  bottom right one, the one whose hold brings up the keyboard.
   --  Packed into one byte rather than three: this firmware has four
   --  bytes of RAM spare in total (see LOOPER_MODE_PLAN.md) and three
   --  plain Booleans here were enough to go over.
   type Edit_Button_State is record
      Held : Boolean := False;

      Momentary : Boolean := False;
      --  This hold is the one that turned the keyboard on, so releasing
      --  turns it back off. A hold while it was already on leaves it on.

      Was_Modifier : Boolean := False;
      --  Edit has been used as a modifier for another button during this
      --  hold, so letting go of it is not also a tap on Edit itself.
   end record
     with Pack;

   Edit_Btn : Edit_Button_State;

   --  Nothing tracks whether Play was held: a long press switches
   --  Current_Input_Mode to Volume_BPM_Mute/Solo, so the release that
   --  follows is handled by that mode's own branch and never reaches the
   --  Main_Modes one that treats a release as a tap.

   Track_Muted : array (WNM.Tracks) of Boolean := (others => False);
   Solo_Mode_Enabled : Boolean := False;
   Solo_Track : WNM.Tracks := 1;
   Anim_Step : UInt32 := 0;

   ----------------
   -- Input_Mode --
   ----------------

   function Input_Mode return Input_Mode_Type is
   begin
      return Current_Input_Mode;
   end Input_Mode;

   --------------------
   -- Input_GUI_Mode --
   --------------------

   function Input_GUI_Mode return Input_Mode_Type is
   begin
      if Current_Input_Mode in Pattern_Select |
                               Track_Select |
                               Step_Select |
                               Song_Select
      then
         return Last_Main_Mode;
      else
         return Current_Input_Mode;
      end if;
   end Input_GUI_Mode;

   function Recording return Boolean
   is (Recording_On);

   function Chroma_Keyboard return Boolean
   is (Chroma_Keyboard_On);

   ------------------
   -- Signal_Event --
   ------------------

   procedure Signal_Event (B : Button; Evt : Button_Event) is
   begin
      WNM.UI.Logs.Log_Button_Event (B, Evt);

      if B in PAD_Up | PAD_Down | PAD_Left | PAD_Right | PAD_A | PAD_B
        and then
          Evt = On_Press
      then
         case Current_Input_Mode is
            when Volume_BPM_Mute | Volume_BPM_Solo =>
               case B is
                  when PAD_Up =>
                     WNM.Audio_Routing.Change_Main_Volume (1);
                  when PAD_Down =>
                     WNM.Audio_Routing.Change_Main_Volume (-1);
                  when PAD_Left =>
                     WNM.Project.Change_BPM (-1);
                  when PAD_Right =>
                     WNM.Project.Change_BPM (1);
                  when others =>
                     null;
               end case;

            when FX_Alt =>
               case B is
                  when PAD_Up =>
                     Project.Next_Value (Project.Alt_Slider_Ctrl);
                  when PAD_Down =>
                     Project.Prev_Value (Project.Alt_Slider_Ctrl);
                  when PAD_Left =>
                     Project.Prev_Value (Project.Alt_Slider_Track);
                  when PAD_Right =>
                     Project.Next_Value (Project.Alt_Slider_Track);
                  when others =>
                     null;
               end case;

            when others =>
               declare
                  Kind : constant GUI.Menu.Menu_Event_Kind :=
                    (case B is
                        when PAD_Up => GUI.Menu.Up_Press,
                        when PAD_Down => GUI.Menu.Down_Press,
                        when PAD_Left => GUI.Menu.Left_Press,
                        when PAD_Right => GUI.Menu.Right_Press,
                        when PAD_A => GUI.Menu.A_Press,
                        when PAD_B => GUI.Menu.B_Press,
                        when others => raise Program_Error);
                  Menu_Evt : GUI.Menu.Menu_Event (Kind => Kind);
               begin
                  GUI.Menu.On_Event (Menu_Evt);
               end;
         end case;
         return;
      end if;

      case Current_Input_Mode is

         when Main_Modes =>
            case Evt is
               when On_Press =>
                  case B is
                  when Pattern_Button =>
                     Current_Input_Mode := Pattern_Select;
                     Select_Done := False;
                  when Track_Button =>
                     Current_Input_Mode := Track_Select;
                     Select_Done := False;
                  when Step_Button =>
                     Current_Input_Mode := Step_Select;
                     Select_Done := False;
                  when Song_Button =>
                     Current_Input_Mode := Song_Select;
                     Select_Done := False;

                  when Func =>
                     --  Switch to Func mode
                     Current_Input_Mode := FX_Alt;
                     Select_Done := False;

                  when Menu =>
                     GUI.Menu.Root.Push_Root_Window;

                  when Play =>
                     if Project.Sequencer_Mode = Project.OG_Sequencer then
                        Project.Play_Pause_Dispatch;
                     elsif Edit_Btn.Held then
                        --  Edit held plus Play clears the selected loop
                        --  track (or undoes that clear). Noting that Edit
                        --  was used as a modifier so letting go of it
                        --  does not also toggle the keyboard.
                        Edit_Btn.Was_Modifier := True;
                        Project.Looper_Clear_Track;
                     end if;
                     --  Otherwise Play is handled on release, so a hold
                     --  (BPM/volume) or a double tap can take precedence
                     --  over the plain tap. See On_Release below.

                  when Rec =>
                     --  The button the faceplate calls Edit. Edit_Btn.Held
                     --  is set on the physical press in Update, not here:
                     --  Rec has a long press, so On_Press is deferred
                     --  until release, which is after every combo that
                     --  needs to know Edit is down has already happened.
                     if Project.Sequencer_Mode = Project.OG_Sequencer then
                        case Current_Input_Mode is
                           when Step_Mode | Track_Mode =>
                              Recording_On := not Recording_On;
                           when others =>
                              null;
                        end case;
                     end if;
                     --  In Looper mode Edit is keyboard-mode and the
                     --  Play modifier only: there is no step grid to
                     --  arm recording into, that is the Play button's
                     --  job here (Project.Looper_Play_Tap).

                  when Keyboard_Button =>

                     --  Step_Sequencer.On_Press reads and writes
                     --  Tracks/Patterns/Steps directly (step entry,
                     --  trigger toggling, step preview, per-step CC
                     --  overrides), which in Four_Track_Looper mode is the
                     --  loop event pool's own storage, so that mode has
                     --  its own handlers instead.
                     if Project.Sequencer_Mode = Project.OG_Sequencer then
                        Project.Step_Sequencer.On_Press
                          (B, Current_Input_Mode);

                     elsif Chroma_Keyboard_On
                       or else Current_Input_Mode = Sample_Edit_Mode
                     then
                        --  Playing notes. Note Off comes on release, not
                        --  after a fixed duration, so the arp and the
                        --  loop both get the real length of the note.
                        --  Sample Edit shows the keyboard whether or not
                        --  the Edit toggle is on, so it plays notes too.
                        Project.Looper_Keyboard_Press (B);

                     elsif Current_Input_Mode = Step_Mode then
                        --  The spec's LiveArp surface: 1-6 styles, 7-8
                        --  octave down/up, 9-16 divisions.
                        Project.Looper_Arp_Pad (B);

                     else
                        --  Track mode: pick the instrument and play it,
                        --  so the pads beat out a part the way the front
                        --  panel always has, and the looper records it.
                        Project.Looper_Track_Press (B);
                     end if;

                  when others =>
                     null;
                  end case;
               when On_Long_Press =>
                  case B is
                  when Play =>
                     --  Switch to volume/BPM config mode. Also marks the
                     --  hold so releasing Play does not then act as a
                     --  tap: "hold play and use arrows to change bpm or
                     --  volume, cancel play doing anything else that
                     --  press". The release after this lands in that
                     --  mode's own branch, not the tap handling below.
                     if Solo_Mode_Enabled then
                        Current_Input_Mode := Volume_BPM_Solo;
                     else
                        Current_Input_Mode := Volume_BPM_Mute;
                     end if;

                  when Rec =>
                     --  Held Edit shows the keyboard for as long as it is
                     --  held, and letting go puts things back, the way
                     --  the Track button behaves.
                     Edit_Btn.Momentary := not Chroma_Keyboard_On;
                     Chroma_Keyboard_On := True;

                  when others =>
                     null;
                  end case;

               when On_Release =>
                  case B is
                  when Rec =>
                     Edit_Btn.Held := False;

                     if Edit_Btn.Momentary then
                        --  Was a hold: put the keyboard back the way it
                        --  was before.
                        Chroma_Keyboard_On := False;
                        Edit_Btn.Momentary := False;

                     elsif Edit_Btn.Was_Modifier then
                        --  Was held as a modifier for another button, so
                        --  it was never a tap on Edit itself.
                        null;

                     elsif Project.Sequencer_Mode /= Project.OG_Sequencer
                     then
                        --  A tap toggles keyboard mode and it sticks,
                        --  rather than needing to be held.
                        Chroma_Keyboard_On := not Chroma_Keyboard_On;
                     end if;

                     Edit_Btn.Was_Modifier := False;

                  when Play =>
                     if Project.Sequencer_Mode /= Project.OG_Sequencer
                       and then not Edit_Btn.Held
                     then
                        --  A plain tap (not a hold, not the Edit+Play
                        --  combo already handled on press).
                        Project.Looper_Play_Tap;
                     end if;

                  when Keyboard_Button =>
                     if Project.Sequencer_Mode = Project.OG_Sequencer then
                        null;
                     elsif Chroma_Keyboard_On
                       or else Current_Input_Mode = Sample_Edit_Mode
                     then
                        Project.Looper_Keyboard_Release (B);
                     elsif Current_Input_Mode /= Step_Mode then
                        --  The matching release for a track pad. Not in
                        --  Step mode, where the pads are the arp grid and
                        --  nothing is sounding to release.
                        Project.Looper_Track_Release (B);
                     end if;

                  when others =>
                     null;
                  end case;
               when others =>
                  null;
            end case;

         when Pattern_Select =>
            case B is
               when Keyboard_Button =>
                  Project.Editing_Pattern := To_Value (B);
                  Select_Done := True;

               when Pattern_Button =>
                  if Evt = On_Release then
                     if Select_Done
                       or else Project.Sequencer_Mode /= Project.OG_Sequencer
                     then
                        --  Go back a main mode. Also taken in
                        --  Four_Track_Looper mode: Pattern_Menu reads
                        --  Patterns/Steps directly, which in that mode is
                        --  the loop event pool's own storage, and its
                        --  Looper-mode replacement is a later phase
                        --  (LOOPER_MODE_PLAN.md P6), not built yet.
                        Current_Input_Mode := Last_Main_Mode;

                     else
                        --  Switch to pattern mode
                        Current_Input_Mode := Pattern_Mode;
                        GUI.Menu.Open (GUI.Menu.Pattern_Menu);
                        Last_Main_Mode := Current_Input_Mode;

                        --  Switching mode disables recording.
                        --  TODO: Is that a good thing?
                        Recording_On := False;
                        Chroma_Keyboard_On := False;
                     end if;
                  end if;
               when others => null;
            end case;

         when Track_Select =>
            case B is
               when Keyboard_Button =>
                  Project.Editing_Track := To_Value (B);
                  Select_Done := True;

               when Track_Button =>
                  if Evt = On_Release then
                     if Select_Done then
                        --  Go back a main mode
                        Current_Input_Mode := Last_Main_Mode;

                     else
                        --  Switch to track mode
                        Current_Input_Mode := Track_Mode;
                        GUI.Menu.Open (GUI.Menu.Track_Menu);
                        Last_Main_Mode := Current_Input_Mode;

                        --  Switching mode disables recording.
                        --  TODO: Is that a good thing?
                        Recording_On := False;
                        Chroma_Keyboard_On := False;

                     end if;
                  end if;
               when others => null;
            end case;

         when Step_Select =>
            case B is
               when Keyboard_Button =>
                  if Project.Sequencer_Mode = Project.Four_Track_Looper then
                     --  "when HOLDING the step button, these 16 buttons
                     --  will have a whole other set of special roles":
                     --  pads 1-8 are the momentary stutter, 9-16 the
                     --  latching dub delay. There is no step grid to
                     --  select into in this mode, which is what these
                     --  pads would otherwise be doing.
                     case Evt is
                        when On_Press =>
                           Project.Looper_FX_Press (To_Value (B));
                           Select_Done := True;
                        when On_Release =>
                           Project.Looper_FX_Release (To_Value (B));
                        when others =>
                           null;
                     end case;
                  else
                     Project.Editing_Step := To_Value (B);
                     Select_Done := True;
                  end if;

               when Step_Button =>
                  if Evt = On_Release then
                     if Project.Sequencer_Mode = Project.Four_Track_Looper
                     then
                        if Select_Done then
                           --  A pad was used while Step was held, so this
                           --  release just ends the FX surface. The
                           --  stutter is momentary and is stopped here as
                           --  well as on the pad's own release: letting go
                           --  of Step first leaves the pad's release to be
                           --  handled by a mode that knows nothing about
                           --  it, and the stutter would run forever,
                           --  looping the whole history ring.
                           Project.Looper_FX_Release_All;
                           Current_Input_Mode := Last_Main_Mode;
                        else
                           --  A tap opens the Looper screens. Step_Settings
                           --  reads Steps directly, which is the loop event
                           --  pool in this mode, so Looper_Menu takes its
                           --  place: the track grid, the LiveArp readout and
                           --  the button reference.
                           Current_Input_Mode := Step_Mode;
                           GUI.Menu.Open (GUI.Menu.Looper_Menu);
                           Last_Main_Mode := Current_Input_Mode;
                        end if;

                     elsif Select_Done then
                        --  Go back a main mode
                        Current_Input_Mode := Last_Main_Mode;

                     else
                        --  Switch to step mode
                        Current_Input_Mode := Step_Mode;
                        GUI.Menu.Open (GUI.Menu.Step_Menu);
                        Last_Main_Mode := Current_Input_Mode;

                        --  Switching mode disables recording.
                        --  TODO: Is that a good thing?
                        Recording_On := False;
                        Chroma_Keyboard_On := False;

                     end if;
                  end if;
               when others => null;
            end case;

         when Song_Select =>
            case B is
               when Keyboard_Button =>
                  Project.Editing_Song_Elt := To_Value (B);
                  Select_Done := True;

               when Song_Button =>
                  if Evt = On_Release then
                     if Select_Done then
                        --  Go back a main mode
                        Current_Input_Mode := Last_Main_Mode;

                     else
                        --  Switch to song mode
                        Current_Input_Mode := Song_Mode;
                        GUI.Menu.Open (GUI.Menu.Chord_Menu);
                        Last_Main_Mode := Current_Input_Mode;

                        --  Switching mode disables recording.
                        --  TODO: Is that a good thing?
                        Recording_On := False;
                        Chroma_Keyboard_On := False;

                     end if;
                  end if;
               when others => null;
            end case;

         when FX_Alt =>
            case Evt is
               when On_Press =>
                  case B is
                     when Keyboard_Button =>
                        Toggle_FX (B);
                        Select_Done := True;

                     --  Pattern_Button, Track_Button and Step_Button here
                     --  all start copying Steps (despite what the "Track"
                     --  one sounds like: it copies every step of every
                     --  pattern for a track, not the track's engine
                     --  settings). In Four_Track_Looper mode that storage
                     --  is the loop event pool, so none of these three may
                     --  run there. Song_Button below is unaffected, it
                     --  copies Song Parts or Chord Progressions, neither
                     --  of which this mode touches.

                     when Pattern_Button =>
                        if Project.Sequencer_Mode = Project.OG_Sequencer then
                           Copy_T := WNM.Sequence_Copy.Start_Copy_Pattern
                             (Project.Editing_Track);
                           Current_Input_Mode := Copy;
                           Select_Done := True;
                        end if;

                     when Track_Button =>
                        if Project.Sequencer_Mode = Project.OG_Sequencer then
                           Copy_T := WNM.Sequence_Copy.Start_Copy_Track;
                           Current_Input_Mode := Copy;
                           Select_Done := True;
                        end if;

                     when Step_Button =>
                        if Project.Sequencer_Mode = Project.OG_Sequencer then
                           Copy_T := WNM.Sequence_Copy.Start_Copy_Step
                             (Project.Editing_Track,
                              Project.Editing_Pattern);
                           Current_Input_Mode := Copy;
                           Select_Done := True;
                        end if;

                     when Song_Button =>
                        Copy_T := WNM.Sequence_Copy.Start_Copy_Song;
                        Current_Input_Mode := Copy;
                        Select_Done := True;

                     when Rec =>
                        --  Switch to sample edit mode
                        Current_Input_Mode := Sample_Edit_Mode;
                        GUI.Menu.Open (GUI.Menu.Sample_Edit_Menu);
                        Last_Main_Mode := Current_Input_Mode;

                     when others =>
                        null;

                  end case;
               when On_Release =>
                  if B = Func then
                     --  Go back a main mode
                     Current_Input_Mode := Last_Main_Mode;
                  end if;
               when others =>
                  null;
            end case;

         when Copy =>
            if Evt = On_Release and then B = Func then
               Current_Input_Mode := Last_Main_Mode;
            elsif Evt = On_Press then
               WNM.Sequence_Copy.Apply (Copy_T, B);
               if WNM.Sequence_Copy.Is_Complete (Copy_T) then
                  if WNM.Project.Do_Copy (Copy_T) then
                     WNM.GUI.Popup.Display ("     copied     ", 500_000);
                  end if;
               end if;
            end if;

         when Volume_BPM_Mute | Volume_BPM_Solo =>

            if B = Play and then Evt = On_Release then
               Current_Input_Mode := Last_Main_Mode;
            end if;

            if Current_Input_Mode = Volume_BPM_Mute then

               if B in Keyboard_Button and then Evt = On_Press then
                  Toggle_Mute (To_Value (B));
               end if;

               if B = Track_Button and then Evt = On_Press then
                  Current_Input_Mode := Volume_BPM_Solo;
               end if;

            else

               if B = Track_Button and then Evt = On_Press then
                  Current_Input_Mode := Volume_BPM_Mute;
                  Solo_Mode_Enabled := False;
               end if;

               if B in Keyboard_Button and then Evt = On_Press then
                  Toggle_Solo (To_Value (B));

                  if not Solo_Mode_Enabled then
                     --  We disabled solo so go back to mute mode
                     Current_Input_Mode := Volume_BPM_Mute;
                  end if;
               end if;
            end if;
      end case;

   end Signal_Event;

   ---------------
   -- Toggle_FX --
   ---------------

   procedure Toggle_FX (B : Keyboard_Button) is
   begin

      case B is
         when B1 .. B4 =>
            declare
               use Project;
               Kind : constant Roll_Kind :=
                 (case B is
                     when B1     => Eighth,
                     when B2     => Quarter,
                     when B3     => Half,
                     when B4     => Beat,
                     when others => Off);

            begin
               if Kind = Roll_State then
                  Roll (Project.Off);
               else
                  Roll (Kind);
               end if;
            end;

         when B9 =>
            Project.Step_Fill_Toogle;

         when B10 .. B12 =>
            declare
               use Project;
               Kind : constant Auto_Fill_Kind :=
                 (case B is
                     when B10    => Auto_Low,
                     when B11    => Auto_High,
                     when B12    => Auto_Buildup,
                     when others => Off);

            begin
               if Kind = Auto_Fill_State then
                  Auto_Fill (Project.Off);
               else
                  Auto_Fill (Kind);
               end if;
            end;

         when B5 .. B7 | B13 .. B15 =>
            declare
               use Voices.Auto_Filter_FX;
               Kind : constant Mode_Kind :=
                 (case B is
                     when B5  => Fix_Low_Pass,
                     when B6  => Fix_Band_Pass,
                     when B7  => Fix_High_Pass,
                     when B13 => Sweep_Low_Pass,
                     when B14 => Sweep_Band_Pass,
                     when B15 => Sweep_High_Pass,
                     when others => Off);

            begin
               if Kind = Mixer.Auto_Filter_Mode then
                  Mixer.Set_Auto_Filter (Off);
               else
                  Mixer.Set_Auto_Filter (Kind);
               end if;
            end;

         when B8 | B16 =>
            declare
               use Voices.Stutter_FX;
               Kind : constant Mode_Kind :=
                 (case B is
                     when B8  => On_Short,
                     when B16 => On_Trip,
                     when others => Off);

            begin
               if Kind = Mixer.Stutter_Mode then
                  Mixer.Set_Stutter (Off);
               else
                  Mixer.Set_Stutter (Kind);
               end if;
            end;
      end case;

   end Toggle_FX;

   --------------------
   -- Has_Long_Press --
   --------------------

   function Has_Long_Press (B : Button) return Boolean
   is (case B is
          when B1             => False,
          when B2             => False,
          when B3             => False,
          when B4             => False,
          when B5             => False,
          when B6             => False,
          when B7             => False,
          when B8             => False,
          when B9             => False,
          when B10            => False,
          when B11            => False,
          when B12            => False,
          when B13            => False,
          when B14            => False,
          when B15            => False,
          when B16            => False,
          when Rec            => True,
          when Play           => True,
          when Func           => False,
          when Step_Button    => False,
          when Track_Button   => False,
          when Pattern_Button => False,
          when Song_Button    => False,
          when Menu           => False,
          when PAD_Up         => True,
          when PAD_Down       => True,
          when PAD_Left       => True,
          when PAD_Right      => True,
          when PAD_A          => False,
          when PAD_B          => False);

   function Has_Repeat_Press (B : Button) return Boolean
   is (case B is
          when PAD_Up .. PAD_Right => True,
          when others => False);

   Last_State    : WNM_HAL.Buttons_State := (others => Up);

   subtype Long_Press_Button is Button range Rec .. PAD_Right;
   --  Every button Has_Long_Press answers True for (Rec, Play and the
   --  four arrows) falls inside this range. Indexed by it rather than by
   --  Button because the deadline is a 64-bit timestamp: all of Button
   --  would be 240 bytes to hold six live entries, and this firmware is
   --  at its RAM ceiling (see LOOPER_MODE_PLAN.md).
   Long_Press_Deadline :
     array (Long_Press_Button) of WNM.Time.Time_Microseconds :=
       (others => WNM.Time.Time_Microseconds'Last);

   Last_Event    : array (Button) of Button_Event := (others => On_Release);

   ------------
   -- Update --
   ------------

   procedure Update is
      Now : constant Time.Time_Microseconds := Time.Clock;

      State : WNM_HAL.Buttons_State;
   begin
      State := WNM_HAL.State;

      --  Handle buttons
      for B in Button loop
         if Last_State (B) = State (B) then
            --  The button didn't change, let's check if we are waiting for
            --  a long press event.
            if B in Long_Press_Button
              and then
                Has_Long_Press (B)
              and then
                State (B) = Down
              and then
                Last_Event (B) = Waiting_For_Long_Press
              and then
                Long_Press_Deadline (B) < Now
            then
               if Has_Repeat_Press (B) then
                  Signal_Event (B, On_Press);
                  Long_Press_Deadline (B) :=
                    Now + Repeat_Press_Time_Span_Microseconds;
               else
                  Last_Event (B) := On_Long_Press;
                  Signal_Event (B, Last_Event (B));
               end if;
            end if;

         elsif State (B) = Down then
            --  Button was justed pressed

            if B = Rec then
               --  Edit's held flag, from the physical edge. Its On_Press
               --  is deferred (it has a long press), so taking Held from
               --  there would only ever go true on release, long after
               --  Edit+Play has come and gone.
               Edit_Btn := (Held => True, Momentary => False,
                           Was_Modifier => False);
            end if;

            if B in Long_Press_Button and then Has_Long_Press (B) then
               --  If this button has long press event we don't signal the
               --  On_Press right now, but we record the time at wich it was
               --  pressed.

               Last_Event (B) := Waiting_For_Long_Press;
               Long_Press_Deadline (B) :=
                 Now + Long_Press_Time_Span_Microseconds;
            else
               Last_Event (B) := On_Press;
               Signal_Event (B, Last_Event (B));
            end if;
         else
            --  Button was just released

            if Last_Event (B) = Waiting_For_Long_Press then
               --  The button was released before we reached the long press
               --  delay. It was not a long press after all so we first send
               --  The On_Press event and then the On_Realease.
               Signal_Event (B, On_Press);
            end if;

            Last_Event (B) := On_Release;
            Signal_Event (B, Last_Event (B));
         end if;

         Last_State (B) := State (B);
      end loop;

      declare
         TP : constant WNM_HAL.Touch_Data := WNM_HAL.Touch_Strip_State;
      begin
         if TP.Touch then
            case Current_Input_Mode is
               when Volume_BPM_Mute | Volume_BPM_Solo =>
                  WNM.Audio_Routing.Set_Main_Volume
                    (Audio_Volume (TP.Value * Float (Audio_Volume'Last)));
               when FX_Alt =>
                  Project.Alt_Slider_Set (TP.Value);
               when others =>
                  GUI.Menu.On_Event ((Kind => GUI.Menu.Slider_Touch,
                                      Slider_Value => TP.Value));
            end case;
         end if;
      end;
   end Update;

   --------------------------
   -- LEDs_Chroma_Keyboard --
   --------------------------

   procedure LEDs_Chroma_Keyboard is
      use type WNM.Project.Octave_Offset;
      Octave : constant WNM.Project.Octave_Offset :=
        WNM.Project.Step_Sequencer.Keyboard_Octave;

      Oct_Hue : constant WNM.LEDs.Hue :=
        (case abs Octave is
            when      1 => LEDs.Spring_Green,
            when      2 => LEDs.Cyan,
            when      3 => LEDs.Azure,
            when      4 => LEDs.Blue,
            when      5 => LEDs.Violet,
            when      6 => LEDs.Magenta,
            when      7 => LEDs.Rose,
            when others => LEDs.Red);
   begin
      LEDs.Set_Hue (Oct_Hue);
      if Octave < 0 then
         LEDs.Turn_On (B1);
      elsif Octave > 0 then
         LEDs.Turn_On (B8);
      end if;

      LEDs.Set_Hue (LEDs.Yellow);

      for B in B9 .. B16 loop
         LEDs.Turn_On (B);
      end loop;
      LEDs.Turn_On (B2);
      LEDs.Turn_On (B3);
      LEDs.Turn_On (B5);
      LEDs.Turn_On (B6);
      LEDs.Turn_On (B7);
   end LEDs_Chroma_Keyboard;

   -----------------------
   -- LEDs_LiveArp_Grid --
   -----------------------

   procedure LEDs_LiveArp_Grid is
      use type WNM.Looper.Arp_Style_Kind;
   begin
      if not Project.Looper_Arp_Available then
         --  Chord never arps, and a MIDI-out track has no instance, so
         --  there is nothing on the grid to show or change.
         return;
      end if;

      declare
         Chan : constant WNM.Looper.Arp_Channel :=
           WNM.Looper.Arp_Channel (Project.Looper_Arp_Channel);
         Style : constant WNM.Looper.Arp_Style_Kind :=
           WNM.Looper.Arp_Style (Chan);
      begin
         --  Styles: Arp_Style_Kind'First is Arp_Off, so the six playable
         --  ones are Pos 1 .. 6 and land on pads 1 .. 6.
         --  Cyan and green across the whole arp grid, nothing like the
         --  magenta the FX surface uses: both live on pads 9-16 and the
         --  only way to tell them apart at a glance is the colour.
         if Style /= WNM.Looper.Arp_Off then
            LEDs.Turn_On
              (To_Button
                 (Keyboard_Value (WNM.Looper.Arp_Style_Kind'Pos (Style))),
               LEDs.Cyan);
         end if;

         --  Octave toggles.
         if WNM.Looper.Arp_Octave_Down (Chan) then
            LEDs.Turn_On (B7, LEDs.Azure);
         end if;
         if WNM.Looper.Arp_Octave_Up (Chan) then
            LEDs.Turn_On (B8, LEDs.Azure);
         end if;

         --  Divisions on 9 .. 16, only worth showing once a style is on.
         if Style /= WNM.Looper.Arp_Off then
            LEDs.Turn_On
              (To_Button
                 (Keyboard_Value
                    (9 + WNM.Looper.Arp_Division_Kind'Pos
                       (WNM.Looper.Arp_Division (Chan)))),
               LEDs.Spring_Green);
         end if;
      end;
   end LEDs_LiveArp_Grid;

   -----------------
   -- Update_LEDs --
   -----------------

   procedure Update_LEDs is

      function Track_Muted (T : Tracks) return Boolean
      is (UI.Muted (T) or else Project.Song_Part_Sequencer.Muted (T));

      ---------------------
      -- On_Playing_Step --
      ---------------------

      procedure On_Playing_Step (H : LEDs.Hue) is
         T : constant Tracks := Project.Editing_Track;
         PH    : constant Project.Playhead :=
           Project.Step_Sequencer.Playing_Step (T);
      begin
         if WNM.MIDI_Clock.Running
           and then
             not Track_Muted (T)
           and then
             Project.Editing_Pattern = PH.P
             and then
               PH.Steps_Count in
                 Natural (Keyboard_Value'First) ..
           Natural (Keyboard_Value'Last)
         then
            LEDs.Turn_On
              (To_Button (Keyboard_Value (PH.Steps_Count)),
               H);
         end if;
      end On_Playing_Step;

      Beat_Step : constant Boolean :=
        WNM.MIDI_Clock.Step in 1 .. 12 | 24 .. 36;

      Select_Blink : constant Boolean := Anim_Step mod 6 < 2;
   begin
      Anim_Step := Anim_Step + 1;

      LEDs.Turn_Off_All;

      if Project.Sequencer_Mode /= Project.OG_Sequencer then
         -- Rec LED: the keyboard toggle, which is what Edit does here --
         if Chroma_Keyboard_On then
            LEDs.Turn_On (Rec, LEDs.Track);
         end if;

         -- Play LED: steady while playing, blinking while recording --
         if WNM.Looper.Recording or else WNM.Looper.Overdubbing then
            LEDs.Turn_On (Play, LEDs.Recording);
         elsif WNM.Looper.Recording_Armed then
            if Select_Blink then
               LEDs.Turn_On (Play, LEDs.Recording);
            end if;
         elsif WNM.Looper.Playing then
            LEDs.Turn_On (Play, LEDs.Play);
         end if;

      else
         -- Rec LED --
         if Recording then
            LEDs.Turn_On (Rec, LEDs.Recording);
         end if;

         -- Play LED --
         if WNM.MIDI_Clock.Running and then Beat_Step then
            LEDs.Turn_On (Play, LEDs.Play);
         end if;
      end if;

      --  The FX LED is on if there's at least one FX enabled
      if Some_FX_On then
         LEDs.Turn_On (Func, LEDs.FX);
      end if;

      --  B1 .. B16 LEDs --
      case Current_Input_Mode is

         -- FX selection mode --
         when FX_Alt =>

            LEDs.Set_Hue (LEDs.FX);

            case Project.Roll_State is
               when Project.Off =>
                  null;
               when Project.Beat =>
                  LEDs.Turn_On (B4);
               when Project.Half =>
                  LEDs.Turn_On (B3);
               when Project.Quarter =>
                  LEDs.Turn_On (B2);
               when Project.Eighth =>
                  LEDs.Turn_On (B1);
            end case;

            if Project.Step_Fill then
               LEDs.Turn_On (B9);
            end if;

            case Project.Auto_Fill_State is
               when Project.Off =>
                  null;
               when Project.Auto_Low =>
                  LEDs.Turn_On (B10);
               when Project.Auto_High =>
                  LEDs.Turn_On (B11);
               when Project.Auto_Buildup =>
                  LEDs.Turn_On (B12);
            end case;

            case Mixer.Auto_Filter_Mode is
               when Voices.Auto_Filter_FX.Off =>
                  null;
               when Voices.Auto_Filter_FX.Fix_Low_Pass =>
                  LEDs.Turn_On (B5);
               when Voices.Auto_Filter_FX.Fix_Band_Pass =>
                  LEDs.Turn_On (B6);
               when Voices.Auto_Filter_FX.Fix_High_Pass =>
                  LEDs.Turn_On (B7);
               when Voices.Auto_Filter_FX.Sweep_Low_Pass =>
                  LEDs.Turn_On (B13);
               when Voices.Auto_Filter_FX.Sweep_Band_Pass =>
                  LEDs.Turn_On (B14);
               when Voices.Auto_Filter_FX.Sweep_High_Pass =>
                  LEDs.Turn_On (B15);
            end case;

            case Mixer.Stutter_Mode is
               when Voices.Stutter_FX.Off =>
                  null;
               when Voices.Stutter_FX.On_Short =>
                  LEDs.Turn_On (B8);
               when Voices.Stutter_FX.On_Trip =>
                  LEDs.Turn_On (B16);
            end case;

            -- Step select mode --
         when Step_Select =>
            if Project.Sequencer_Mode /= Project.OG_Sequencer then
               --  Step held is the FX surface here: 1-8 stutter
               --  (momentary), 9-16 dub delay (latching).
               LEDs.Set_Hue (LEDs.Magenta);
               if WNM.Looper.Delay_Active then
                  LEDs.Turn_On
                    (To_Button
                       (Keyboard_Value
                          (9 + WNM.Looper.Arp_Division_Kind'Pos
                             (WNM.Looper.Delay_Division))));
               end if;
               if WNM.Looper.Stutter_Active and then Select_Blink then
                  --  Which of the eight it is lives inside the engine, so
                  --  the Step button itself carries "a stutter is running"
                  --  rather than guessing a pad.
                  LEDs.Turn_On (Step_Button, LEDs.Magenta);
               end if;
            else
               LEDs.Set_Hue (LEDs.Step);
               LEDs.Turn_On (To_Button (Project.Editing_Step));
            end if;

            -- Track assign mode --
         when Track_Select =>
            LEDs.Set_Hue (LEDs.Track);
            LEDs.Turn_On (To_Button (Project.Editing_Track));

            --  Pattern select --
         when Pattern_Select =>
            LEDs.Set_Hue (LEDs.Pattern);
            LEDs.Turn_On (To_Button (Project.Editing_Pattern));

            --  Song Part select --
         when Song_Select =>
            case Project.Editing_Song_Elt is
               when Parts =>
                  LEDs.Set_Hue (LEDs.Part);
               when Chord_Progressions =>
                  LEDs.Set_Hue (LEDs.Chord);
            end case;
            LEDs.Turn_On (To_Button (Project.Editing_Song_Elt));

            --  Volume and BPM mode --
         when Volume_BPM_Mute | Volume_BPM_Solo =>

            LEDs.Set_Hue (LEDs.Track);

            if Solo_Mode_Enabled then
               LEDs.Turn_On (Track_Button);
               LEDs.Turn_On (To_Button (Solo));
            else
               for B in B1 .. B16 loop
                  if not Muted (To_Value (B)) then
                     LEDs.Turn_On (B);
                  end if;
               end loop;
            end if;

         when others =>
            case Last_Main_Mode is
            when Pattern_Mode =>
               LEDs.Set_Hue (LEDs.Pattern);
               LEDs.Turn_On (Pattern_Button);

               declare
                  T : constant Tracks := Project.Editing_Track;
                  EP : constant Patterns := Project.Editing_Pattern;
                  P : Patterns;
               begin
                  LEDs.Turn_On (To_Button (EP));

                  LEDs.Set_Hue (LEDs.Pattern_Link);

                  --  Chained patterns after EP
                  P := EP;
                  while P /= Patterns'Last and then Project.Link (T, P) loop
                     P := P + 1;
                     LEDs.Turn_On (To_Button (P));
                  end loop;

                  --  Chained patterns before EP
                  P := EP;
                  while P /= Patterns'First and then Project.Link (T, P - 1)
                  loop
                     P := P - 1;
                     LEDs.Turn_On (To_Button (P));
                  end loop;

                  --  Blink playing pattern
                  if WNM.MIDI_Clock.Running then
                     if Beat_Step then
                        LEDs.Turn_On
                          (To_Button
                             (Project.Step_Sequencer.Playing_Step (T).P),
                           LEDs.Playing);
                     end if;
                  end if;

               end;

            when Song_Mode =>
               case Project.Editing_Song_Elt is
               when Parts =>
                  LEDs.Set_Hue (LEDs.Part);
               when Chord_Progressions =>
                  LEDs.Set_Hue (LEDs.Chord);
               end case;

               --  Blink selected song part
               LEDs.Turn_On (Song_Button);
               LEDs.Turn_On (To_Button (Project.Editing_Song_Elt));

               --  Blinking playing part
               if WNM.MIDI_Clock.Running then
                  if Beat_Step then
                     LEDs.Turn_On
                       (To_Button (Project.Song_Part_Sequencer.Playing),
                        LEDs.Playing);
                  end if;
               end if;

            when Track_Mode =>

               LEDs.Set_Hue (LEDs.Track);
               LEDs.Turn_On (Track_Button);

               if Chroma_Keyboard_On then
                  LEDs_Chroma_Keyboard;

               elsif Project.Sequencer_Mode /= Project.OG_Sequencer then
                  --  Both branches below read Steps directly (per-step
                  --  trigger state, playhead lookups), which in
                  --  Four_Track_Looper mode is the loop event pool's own
                  --  storage. Just the track-select LED, using only the
                  --  plain Editing_Track variable, until the Looper's own
                  --  Track_Mode LEDs are built (LOOPER_MODE_PLAN.md P6).
                  LEDs.Turn_On (To_Button (Project.Editing_Track),
                               LEDs.Track);

               elsif Recording then

                  --  Active steps in edit mode
                  LEDs.Set_Hue (LEDs.Recording);
                  for B in Keyboard_Button loop
                     if Project.Set (Step => To_Value (B)) then
                        LEDs.Turn_On (B);
                     end if;
                  end loop;

                  if Select_Blink then
                     --  Blink Selected step
                     LEDs.Turn_On (To_Button (Project.Editing_Step),
                                   LEDs.Step);
                  end if;

                  On_Playing_Step (LEDs.Playing);

               else

                  --  Selected track
                  LEDs.Turn_On (To_Button (Project.Editing_Track),
                                LEDs.Track);

                  --  Triggered tracks
                  if WNM.MIDI_Clock.Running then
                     LEDs.Set_Hue (LEDs.Playing);
                     for B in Keyboard_Button loop
                        declare
                           Track : constant Tracks := To_Value (B);
                           PH    : constant Project.Playhead :=
                             Project.Step_Sequencer.Playing_Step (Track);
                        begin
                           if not Track_Muted (Track)
                             and then
                               Project.Set (Track, PH)
                           then
                              LEDs.Turn_On (B);
                           end if;
                        end;
                     end loop;
                  end if;

               end if;

            when Step_Mode =>
               LEDs.Set_Hue (LEDs.Step);
               LEDs.Turn_On (Step_Button);

               if Chroma_Keyboard_On then
                  LEDs_Chroma_Keyboard;
               elsif Project.Sequencer_Mode /= Project.OG_Sequencer then
                  --  The LiveArp grid, matching Looper_Arp_Pad: 1-6 are
                  --  the styles, 7-8 the octave toggles, 9-16 the
                  --  divisions. Everything in the OG branch below reads
                  --  Steps directly, which is the loop event pool here.
                  LEDs_LiveArp_Grid;
               else

                  if Recording then
                     --  Red means editing
                     LEDs.Set_Hue (LEDs.Recording);
                  else
                     LEDs.Set_Hue (LEDs.Active_Step);
                  end if;

                  --  Active steps
                  for B in Keyboard_Button loop
                     if Project.Set (Step => To_Value (B)) then
                        LEDs.Turn_On (B);
                     end if;
                  end loop;

                  if Project.Set (Step => Project.Editing_Step) then
                     if Select_Blink then
                        --  Blink Selected step
                        LEDs.Turn_On (To_Button (Project.Editing_Step),
                                      LEDs.Step);
                     end if;
                  else
                     LEDs.Turn_On (To_Button (Project.Editing_Step),
                                   LEDs.Step);
                  end if;

                  --  Playing step
                  On_Playing_Step (LEDs.Playing);
               end if;

            when FX_Mode =>
               LEDs.Set_Hue (LEDs.Violet);

               LEDs.Turn_On (Func);

            when Sample_Edit_Mode =>
               LEDs_Chroma_Keyboard;
            end case;
      end case;

      WNM.LEDs.Update;
   end Update_LEDs;

   -----------------
   -- Toggle_Mute --
   -----------------

   procedure Toggle_Mute (Track : WNM.Tracks) is
   begin
      Track_Muted (Track) := not Track_Muted (Track);
   end Toggle_Mute;

   -----------
   -- Muted --
   -----------

   function Muted (Track : WNM.Tracks) return Boolean
   is (if In_Solo
       then Solo /= Track
       else Track_Muted (Track));

   ----------------
   -- Some_FX_On --
   ----------------

   function Some_FX_On return Boolean is
      use type Project.Roll_Kind;
      use type Project.Auto_Fill_Kind;
      use type Voices.Auto_Filter_FX.Mode_Kind;
      use type Voices.Stutter_FX.Mode_Kind;
   begin
      return Project.Roll_State /= Project.Off
        or else
          Project.Auto_Fill_State /= Project.Off
          or else
            Project.Step_Fill
            or else
              Mixer.Auto_Filter_Mode /= Voices.Auto_Filter_FX.Off
              or else
                Mixer.Stutter_Mode /= Voices.Stutter_FX.Off;
   end Some_FX_On;

   -----------------
   -- Toggle_Solo --
   -----------------

   procedure Toggle_Solo (Track : WNM.Tracks) is
   begin
      if Solo_Mode_Enabled then
         if Solo_Track = Track then
            Solo_Mode_Enabled := False;
         else
            Solo_Track := Track;
         end if;
      else
         Solo_Mode_Enabled := True;
         Solo_Track := Track;
      end if;
   end Toggle_Solo;

   -------------
   -- In_Solo --
   -------------

   function In_Solo return Boolean
   is (Solo_Mode_Enabled);

   ----------
   -- Solo --
   ----------

   function Solo return WNM.Tracks
   is (Solo_Track);

end WNM.UI;

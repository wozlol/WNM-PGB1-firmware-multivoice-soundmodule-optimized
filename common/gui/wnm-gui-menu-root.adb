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

with WNM.GUI.Menu.Drawing;       use WNM.GUI.Menu.Drawing;
with WNM.GUI.Menu.Yes_No_Dialog;
with WNM.GUI.Bitmap_Fonts;
with WNM.GUI.Menu.Projects;
with WNM.GUI.Menu.FX_Settings;
with WNM.GUI.Menu.Inputs;
with WNM.GUI.Menu.System_Info;
with WNM.GUI.Menu.MIDI_Settings;
with WNM.GUI.Menu.User_Waveform;
with WNM.GUI.Menu.Tracks_Mixer;
with WNM.Power_Control;
with WNM.Screen;
with WNM.Project;
with WNM.Looper;

with edit_wave_icon;
with project_icon;
with line_in_icon;
with midi_icon;
with system_info_icon;
with firmware_update_icon;
with mixer_icon;
with live_fx_icon;
with loop_icon;

package body WNM.GUI.Menu.Root is

   use type WNM.Project.Sequencer_Mode_Kind;

   On_Stack : Boolean := False with Volatile;

   Root_Window_Singleton : aliased Root_Menu;

   function Menu_Item_Text (Item : Menu_Items) return String
   is (case Item is
          when Projects        => "Projects",
          when Sequencer_Mode_Select => "Sequencer Mode",
          when Looper_Config   => "Looper Tracks",
          when Tracks_Mixer    => "Project Mixer",
          when Inputs          => "Inputs Settings",
          when User_Waveform   => "Custom Waveform",
          when Live_FX         => "Live FX Settings",
          when MIDI_Settings   => "MIDI Settings",
          when DFU_Mode        => "Update Mode",
          when System_Info     => "System Info");

   function Other_Mode return WNM.Project.Sequencer_Mode_Kind
   is (if WNM.Project.Sequencer_Mode = WNM.Project.OG_Sequencer
       then WNM.Project.Four_Track_Looper
       else WNM.Project.OG_Sequencer);
   --  There are only two modes, and a confirmation is only ever showing for
   --  a switch away from whichever one is live right now, so the pending
   --  choice needs no variable of its own, just this.

   procedure Apply_Mode_Switch (M : WNM.Project.Sequencer_Mode_Kind) is
   begin
      if M = WNM.Project.Sequencer_Mode then
         return;
      end if;
      --  Anything the stutter or dub delay still has sounding gets its
      --  note-offs now, while the engine that knows about them is still
      --  the live one.
      WNM.Project.Looper_Silence_Effects;

      --  Both directions share the same RAM (see WNM.Looper), so every
      --  switch resets both sides: the one taking over starts clean, and
      --  the one being left starts clean too, for next time.
      WNM.Looper.Reset;
      WNM.Project.Clear_Sequences;
      WNM.Project.Set_Sequencer_Mode (M);
   end Apply_Mode_Switch;

   procedure Request_Mode (M : WNM.Project.Sequencer_Mode_Kind) is
   begin
      if M = WNM.Project.Sequencer_Mode then
         return;
      end if;

      declare
         Needs_Warning : constant Boolean :=
           (if M = WNM.Project.Four_Track_Looper
            --  Whether the OG sequencer still holds its factory-default
            --  content isn't checked here, so this warns even on a fresh
            --  project. An extra confirm on an empty project is a minor
            --  annoyance, not a safety problem, and is cheap tonight;
            --  skipping it correctly would need a real content comparison.
            then True
            else WNM.Looper.Has_Any_Data);
      begin
         if not Needs_Warning then
            Apply_Mode_Switch (M);
            return;
         end if;

         Yes_No_Dialog.Set_Title
           (if M = WNM.Project.Four_Track_Looper
            then "Steps Will Be Lost"
            else "Loops Will Be Lost");
         Yes_No_Dialog.Push_Window;
      end;
   end Request_Mode;

   ----------------------
   -- Push_Root_Window --
   ----------------------

   procedure Push_Root_Window is
   begin
      if not On_Stack then
         Push (Root_Window_Singleton'Access);
         On_Stack := True;
      end if;
   end Push_Root_Window;

   ---------------
   -- Draw_Icon --
   ---------------

   procedure Draw_Icon (Bmp : Screen.Bitmap) is
      Icon_W : constant Natural := Bmp.W;
      Icon_H : constant Natural := Bmp.H;
      Icon_Left : constant Natural :=
        Box_Center.X - (Icon_W / 2);
      Icon_Top : constant Natural :=
        Box_Center.Y - 3 - (Icon_H / 2);
   begin
      Screen.Copy_Bitmap (Bmp, Icon_Left, Icon_Top);
   end Draw_Icon;

   --------------------------------
   -- Draw_Sequencer_Mode_Icons  --
   --------------------------------

   Sequencer_Grid_Icon : constant Screen.Bitmap :=
     (W => 23, H => 5, Length_Byte => 15,
      Data => (219, 182, 237, 109, 219, 54, 0, 0, 96, 219, 182, 189, 109,
               219, 6));
   --  8x2 dot grid, one dot per step pad, matching the physical 16-pad
   --  layout. Generated, not hand drawn: see the Sequencer Mode tab. Kept
   --  as a local constant rather than its own package: a separate package
   --  for one tiny icon used in exactly one place costs a few bytes of its
   --  own elaboration bookkeeping, measured to matter at this RAM budget.

   procedure Draw_Sequencer_Mode_Icons is

      Left_X  : constant Natural := Box_Left + Box_Width / 4;
      Right_X : constant Natural := Box_Right - Box_Width / 4;
      Icon_Y  : constant Natural := Box_Center.Y - 3 - (loop_icon.Data.H / 2);
      Label_Y : constant Natural := Box_Bottom - Bitmap_Fonts.Height - 2;

      procedure Centered_Str (Center_X : Natural; Str : String) is
      begin
         Draw_Str (Center_X - (Str'Length * Font_Width) / 2, Label_Y, Str);
      end Centered_Str;

      Active : constant WNM.Project.Sequencer_Mode_Kind :=
        WNM.Project.Sequencer_Mode;
   begin
      Screen.Copy_Bitmap (loop_icon.Data,
                         Left_X - loop_icon.Data.W / 2, Icon_Y);
      Screen.Copy_Bitmap (Sequencer_Grid_Icon,
                         Right_X - Sequencer_Grid_Icon.W / 2,
                         Box_Center.Y - 3 - Sequencer_Grid_Icon.H / 2);

      Centered_Str (Left_X, "4-Track Looper");
      Centered_Str (Right_X, "OG Sequencer");

      --  A box around whichever side is the live mode, same device as the
      --  Yes/No dialog's own selection box.
      if Active = WNM.Project.Four_Track_Looper then
         Screen.Draw_Rect (((Left_X - loop_icon.Data.W / 2 - 3,
                             Icon_Y - 3),
                            loop_icon.Data.W + 6, loop_icon.Data.H + 6));
      else
         Screen.Draw_Rect (((Right_X - Sequencer_Grid_Icon.W / 2 - 3,
                             Box_Center.Y - 3 - Sequencer_Grid_Icon.H / 2
                               - 3),
                            Sequencer_Grid_Icon.W + 6,
                            Sequencer_Grid_Icon.H + 6));
      end if;
   end Draw_Sequencer_Mode_Icons;

   -----------------------
   -- Looper_Column_X   --
   -----------------------

   Looper_AUT_Column : constant Looper_Column_Id := 5;

   function Looper_Column_X (Col : Looper_Column_Id) return Natural
   is (Box_Left + 12 + Natural (Col - 1) * 24);
   --  5 columns, 24px apart, scaled down from the Preferences tab's 4
   --  columns at 32px.

   ------------------------
   -- Draw_Track_Icon    --
   ------------------------

   --  Small hand-drawn glyphs rather than bitmaps: these react to live
   --  engine state (which track is recording right now), so a fixed
   --  bitmap per shape plus Set_Pixel-level control over exactly which one
   --  is showing is simpler than four more generated icon files.
   procedure Draw_Track_Icon (Icon : WNM.Looper.Track_Icon; Cx, Cy : Natural)
   is
      R : constant := 4;
   begin
      case Icon is
         when WNM.Looper.Empty =>
            null;

         when WNM.Looper.Stopped =>
            --  Hollow square: has content, not currently sounding.
            Screen.Draw_Rect (((Cx - R, Cy - R), 2 * R, 2 * R));

         when WNM.Looper.Playing_Icon =>
            --  Filled triangle, pointing right.
            for Dy in 0 .. 2 * R loop
               declare
                  Half_Width : constant Natural :=
                    (if Dy <= R then Dy else 2 * R - Dy);
               begin
                  Screen.Draw_H_Line (Cx - R, Cx - R + Half_Width,
                                      Cy - R + Dy);
               end;
            end loop;

         when WNM.Looper.Armed =>
            --  Hollow circle: armed, waiting for the next note to start.
            Screen.Draw_Circle ((Cx, Cy), R);

         when WNM.Looper.Recording_Icon =>
            --  Filled circle: actively recording or overdubbing. Plain
            --  integer search rather than a real sqrt: R is always 4, so
            --  this is at most 4 iterations.
            for Dy in -R .. R loop
               declare
                  Limit  : constant Natural := R * R - Dy * Dy;
                  Dx_Max : Natural := 0;
               begin
                  while (Dx_Max + 1) * (Dx_Max + 1) <= Limit loop
                     Dx_Max := Dx_Max + 1;
                  end loop;
                  Screen.Draw_H_Line (Cx - Dx_Max, Cx + Dx_Max, Cy + Dy);
               end;
            end loop;
      end case;
   end Draw_Track_Icon;

   -------------------------
   -- Draw_Looper_Config  --
   -------------------------

   procedure Draw_Looper_Config (Column : Looper_Column_Id) is
      use WNM.Looper;

      Icon_Y  : constant Natural := Box_Top + 16;
      Bars_Y  : constant Natural := Box_Top + 26;
      Label_Y : constant Natural := Box_Bottom - Font_Height - 2;
   begin
      if Column = Looper_AUT_Column then
         Draw_Title ("Auto Setting", "");
      else
         Draw_Title
           ("Track" & Loop_Track'Image (Loop_Track (Column)), "");
      end if;

      for Col in Looper_Column_Id loop
         declare
            Cx       : constant Natural := Looper_Column_X (Col);
            Selected : constant Boolean := Col = Column;
         begin
            if Col = Looper_AUT_Column then
               Draw_Str (Cx - 3 * Font_Width, Bars_Y, Img (Auto_Setting));
               Draw_Value_Pos ("AUT", Cx, Selected);
            else
               declare
                  Track : constant Loop_Track := Loop_Track (Col);
               begin
                  Draw_Track_Icon (Icon (Track), Cx, Icon_Y);
                  Draw_Str (Cx - Font_Width, Bars_Y,
                           Bar_Count'Image (Bars (Track)));
                  Draw_Value_Pos (Img (Quantize (Track)), Cx, Selected);
               end;
            end if;
         end;
      end loop;

      Draw_Str_Center (Label_Y - Font_Height - 2,
                       "Up/Down bars, A quantize");
   end Draw_Looper_Config;

   -------------------------
   -- Looper_Config_Event --
   -------------------------

   procedure Looper_Config_Event (Column : in out Looper_Column_Id;
                                  Event  :        Menu_Event)
   is
      use WNM.Looper;

      procedure Sync_Selected_Track is
      begin
         --  Arm_Record always arms WNM.Looper.Selected_Track, and this is
         --  the only place anything picks which track that is: there is
         --  no dedicated track-select button for this mode yet (that is
         --  part of the fuller button remap, LOOPER_MODE_PLAN.md P6), so
         --  for now landing on a track column here is what decides what
         --  the next Rec press arms.
         if Column /= Looper_AUT_Column then
            Select_Track (Loop_Track (Column));
         end if;
      end Sync_Selected_Track;
   begin
      case Event.Kind is
         when Right_Press =>
            Column :=
              (if Column = Looper_Column_Id'Last then Looper_Column_Id'First
               else Column + 1);
            Sync_Selected_Track;

         when Left_Press =>
            Column :=
              (if Column = Looper_Column_Id'First then Looper_Column_Id'Last
               else Column - 1);
            Sync_Selected_Track;

         when Up_Press =>
            if Column /= Looper_AUT_Column then
               declare
                  Track : constant Loop_Track := Loop_Track (Column);
                  Current : constant Bar_Count := Bars (Track);
               begin
                  if Current /= Bar_Count'Last then
                     --  Does not yet resize the running engine, only
                     --  records the chosen bar count (see WNM.Looper.
                     --  Set_Bars).
                     Set_Bars (Track, Current + 1, 0, null);
                  end if;
               end;
            end if;

         when Down_Press =>
            if Column /= Looper_AUT_Column then
               declare
                  Track : constant Loop_Track := Loop_Track (Column);
                  Current : constant Bar_Count := Bars (Track);
               begin
                  if Current /= Bar_Count'First then
                     Set_Bars (Track, Current - 1, 0, null);
                  end if;
               end;
            end if;

         when A_Press =>
            if Column = Looper_AUT_Column then
               Set_Auto_Setting (Auto_Next (Auto_Setting));
            else
               declare
                  Track : constant Loop_Track := Loop_Track (Column);
               begin
                  Set_Quantize (Track, Quantize_Next (Quantize (Track)));
               end;
            end if;

         when B_Press | Slider_Touch =>
            null;
      end case;
   end Looper_Config_Event;

   ----------
   -- Draw --
   ----------

   overriding
   procedure Draw
     (This   : in out Root_Menu)
   is
   begin
      Draw_Menu_Box ("Menu",
                     Count => Menu_Items_Count,
                     Index => Menu_Items'Pos (This.Item));

      case This.Item is
         when Projects =>
            Draw_Icon (project_icon.Data);
         when Sequencer_Mode_Select =>
            Draw_Sequencer_Mode_Icons;
         when Looper_Config =>
            if not This.Looper_Editing then
               Draw_Icon (loop_icon.Data);
            end if;
         when Tracks_Mixer =>
            Draw_Icon (mixer_icon.Data);
         when User_Waveform =>
            Draw_Icon (edit_wave_icon.Data);
         when Live_FX =>
            Draw_Icon (live_fx_icon.Data);
         when Inputs =>
            Draw_Icon (line_in_icon.Data);
         when MIDI_Settings =>
            Draw_Icon (midi_icon.Data);
         when DFU_Mode =>
            Draw_Icon (firmware_update_icon.Data);
         when System_Info =>
            Draw_Icon (system_info_icon.Data);
      end case;

      if This.Item = Looper_Config and then This.Looper_Editing then
         --  Replaces the icon and the generic bottom label below with the
         --  5-column editor.
         Draw_Looper_Config (This.Looper_Column);
      elsif This.Item = Sequencer_Mode_Select then
         null;  --  Draws its own two labels, one per icon, above.
      else
         Draw_Str_Center (Box_Bottom - Bitmap_Fonts.Height - 2,
                          Menu_Item_Text (This.Item));
         if This.Item = Looper_Config then
            Draw_Str (Box_Left + 3, Value_Text_Y, "Press A to edit");
         end if;
      end if;
   end Draw;

   --------------
   -- On_Event --
   --------------

   overriding
   procedure On_Event
     (This  : in out Root_Menu;
      Event : Menu_Event)
   is
   begin
      if This.Item = Looper_Config and then This.Looper_Editing then
         if Event.Kind = B_Press then
            This.Looper_Editing := False;
         else
            Looper_Config_Event (This.Looper_Column, Event);
         end if;
         return;
      end if;

      case Event.Kind is
         when A_Press =>
            case This.Item is
               when Projects =>
                  Menu.Projects.Push_Window;

               when Sequencer_Mode_Select =>
                  Request_Mode (WNM.Project.Four_Track_Looper);

               when Looper_Config =>
                  This.Looper_Editing := True;

               when Inputs =>
                  Menu.Inputs.Push_Window;

               when Tracks_Mixer =>
                  Menu.Tracks_Mixer.Push_Window;

               when User_Waveform =>
                  Menu.User_Waveform.Push_Window;

               when Live_FX =>
                  Menu.FX_Settings.Push_Window;

               when MIDI_Settings =>
                  Menu.MIDI_Settings.Push_Window;

               when DFU_Mode =>
                  Yes_No_Dialog.Set_Title ("Enter Update Mode?");
                  Yes_No_Dialog.Push_Window;

               when System_Info =>
                  Menu.System_Info.Push_Window;

            end case;

         when B_Press =>
            if This.Item = Sequencer_Mode_Select then
               Request_Mode (WNM.Project.OG_Sequencer);
            end if;

         when Up_Press =>
            null;
         when Down_Press =>
            null;

         when Right_Press =>
            if This.Item /= Menu_Items'Last then
               This.Item := Menu_Items'Succ (This.Item);
            else
               This.Item := Menu_Items'First;
            end if;

         when Left_Press =>
            if This.Item /= Menu_Items'First then
               This.Item := Menu_Items'Pred (This.Item);
            else
               This.Item := Menu_Items'Last;
            end if;

         when Slider_Touch =>
            null;
      end case;
   end On_Event;

   ---------------
   -- On_Pushed --
   ---------------

   overriding
   procedure On_Pushed
     (This  : in out Root_Menu)
   is
   begin
      This.Item := Menu_Items'First;
      This.Looper_Editing := False;
   end On_Pushed;

   --------------
   -- On_Focus --
   --------------

   overriding
   procedure On_Focus
     (This       : in out Root_Menu;
      Exit_Value : Window_Exit_Value)
   is
   begin
      case This.Item is
         when DFU_Mode =>
            if Exit_Value = Success then
               WNM.Power_Control.Enter_DFU_Mode;
            end if;

         when Sequencer_Mode_Select =>
            if Exit_Value = Success then
               Apply_Mode_Switch (Other_Mode);
            end if;

         when others =>
            null;
      end case;
   end On_Focus;

   ------------
   -- On_Pop --
   ------------

   overriding
   procedure On_Pop (This : in out Root_Menu) is
      pragma Unreferenced (This);
   begin
      On_Stack := False;
   end On_Pop;

end WNM.GUI.Menu.Root;

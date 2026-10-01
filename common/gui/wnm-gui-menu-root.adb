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
      Icon_Y  : constant Natural := Box_Top + 4;

      --  Two label rows under the icons: neither name fits on one line at
      --  half the screen width, and a 23px wide icon plus two 7px rows is
      --  what the box has room for.
      Label_Y   : constant Natural := Box_Bottom - 2 * Bitmap_Fonts.Height - 4;
      Label_Y_2 : constant Natural := Label_Y + Bitmap_Fonts.Height + 1;

      procedure Centered_Str (Center_X, Y : Natural; Str : String) is
      begin
         Draw_Str (Center_X - (Str'Length * Font_Width) / 2, Y, Str);
      end Centered_Str;

      Active : constant WNM.Project.Sequencer_Mode_Kind :=
        WNM.Project.Sequencer_Mode;
   begin
      Screen.Copy_Bitmap (loop_icon.Data,
                         Left_X - loop_icon.Data.W / 2, Icon_Y);
      Screen.Copy_Bitmap (Sequencer_Grid_Icon,
                         Right_X - Sequencer_Grid_Icon.W / 2,
                         Icon_Y + loop_icon.Data.H / 2
                           - Sequencer_Grid_Icon.H / 2);

      Centered_Str (Left_X, Label_Y, "4-Track");
      Centered_Str (Left_X, Label_Y_2, "Looper");
      Centered_Str (Right_X, Label_Y, "OG");
      Centered_Str (Right_X, Label_Y_2, "Sequencer");

      --  A box around whichever side is the live mode, same device as the
      --  Yes/No dialog's own selection box.
      if Active = WNM.Project.Four_Track_Looper then
         Screen.Draw_Rect (((Left_X - loop_icon.Data.W / 2 - 3,
                             Icon_Y - 3),
                            loop_icon.Data.W + 6, loop_icon.Data.H + 6));
      else
         Screen.Draw_Rect (((Right_X - Sequencer_Grid_Icon.W / 2 - 3,
                             Icon_Y + loop_icon.Data.H / 2
                               - Sequencer_Grid_Icon.H / 2 - 3),
                            Sequencer_Grid_Icon.W + 6,
                            Sequencer_Grid_Icon.H + 6));
      end if;
   end Draw_Sequencer_Mode_Icons;


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

      if This.Item /= Sequencer_Mode_Select then
         --  Sequencer Mode draws its own label under each of its two
         --  icons, so it has no single name to put along the bottom.
         Draw_Str_Center (Box_Bottom - Bitmap_Fonts.Height - 2,
                          Menu_Item_Text (This.Item));
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
      case Event.Kind is
         when A_Press =>
            case This.Item is
               when Projects =>
                  Menu.Projects.Push_Window;

               when Sequencer_Mode_Select =>
                  Request_Mode (WNM.Project.Four_Track_Looper);

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

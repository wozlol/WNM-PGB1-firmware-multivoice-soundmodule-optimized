-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--                  Copyright (C) 2016-2021 Fabien Chouteau                  --
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

with WNM.GUI.Menu.Drawing; use WNM.GUI.Menu.Drawing;
with WNM.Screen;
with WNM.Project;
with WNM.Looper;
with WNM.Persistent;
with WNM.Time;

package body WNM.GUI.Menu.Looper_Settings is

   use type WNM.Looper.Menu_Column_Id;
   use type WNM.Looper.Menu_Tab_Id;

   Looper_Menu_Singleton : aliased Looper_Settings_Menu;

   --  The cursor lives in WNM.Looper's overlay, so these two translate
   --  between that plain index and this screen's own enum.
   function Tab return Top_Settings
   is (Top_Settings'Val (Natural (WNM.Looper.Menu_Tab)));

   procedure Set_Tab (T : Top_Settings) is
   begin
      WNM.Looper.Set_Menu_Tab
        (WNM.Looper.Menu_Tab_Id (Top_Settings'Pos (T)));
   end Set_Tab;

   function Column return Column_Id
   is (WNM.Looper.Menu_Column);

   procedure Set_Column (C : Column_Id) is
   begin
      WNM.Looper.Set_Menu_Column (C);
   end Set_Column;

   pragma Compile_Time_Error
     (Top_Settings'Pos (Top_Settings'Last) + 1 /= WNM.Looper.Menu_Tab_Count,
      "Menu_Tab_Id no longer covers every tab on this screen");

   pragma Compile_Time_Error
     (Top_Settings'Pos (Arp_Tab) /= WNM.Looper.Menu_Tab_Arp,
      "Menu_Tab_Arp no longer points at this screen's LiveArp tab");

   AUT_Column : constant Column_Id := Column_Id'Last;

   --  Three rows inside the box, plus the selection underline the rest of
   --  the UI already puts at Select_Line_Y. The box runs 22 .. 63, so an
   --  icon centred on 31 spans 27 .. 35, and the two text rows below it
   --  are clear of both it and the underline.
   Icon_Row_Y  : constant := Box_Top + 9;
   Bars_Row_Y  : constant := Box_Top + 18;

   --  Five 3-character columns, 18px of glyphs each on a 24px pitch,
   --  which is the widest that keeps all five inside the box.
   Column_Chars : constant := 3;
   Column_Width : constant := Column_Chars * Font_Width;

   function Column_Left (Col : Column_Id) return Natural
   is (Box_Left + 4 + Natural (Col - 1) * 24);

   function Column_Center (Col : Column_Id) return Natural
   is (Column_Left (Col) + Column_Width / 2);

   -----------------
   -- Push_Window --
   -----------------

   procedure Push_Window is
   begin
      Push (Looper_Menu_Singleton'Access);
   end Push_Window;

   --------------
   -- Bars_Img --
   --------------

   function Bars_Img (B : WNM.Looper.Bar_Count) return String is
      N : constant Natural := Natural (B);
      Digit : constant Character :=
        Character'Val (Character'Pos ('0') + (N mod 10));
   begin
      --  Always exactly Column_Chars wide so a column never shifts under
      --  the value as it changes.
      if N < 10 then
         return "b" & Digit & ' ';
      else
         return "b1" & Digit;
      end if;
   end Bars_Img;

   ---------------
   -- Quant_Img --
   ---------------

   function Quant_Img (Q : WNM.Looper.Quantize_Kind) return String
   is (case Q is
          when WNM.Looper.Off  => "qx ",
          when WNM.Looper.Q_8  => "q8 ",
          when WNM.Looper.Q_16 => "q16",
          when WNM.Looper.Q_32 => "q32");

   --------------
   -- Auto_Img --
   --------------

   function Auto_Img (A : WNM.Looper.Auto_Kind) return String
   is (case A is
          when WNM.Looper.Auto_Off     => " - ",
          when WNM.Looper.Auto_Overdub => "ovr",
          when WNM.Looper.Auto_Track   => "trk",
          when WNM.Looper.Auto_Arm     => "arm");

   ---------------------
   -- Draw_Track_Icon --
   ---------------------

   --  Hand drawn rather than four more icon bitmaps: these follow live
   --  engine state, so which shape is showing changes frame to frame.
   procedure Draw_Track_Icon (Icon : WNM.Looper.Track_Icon; Cx, Cy : Natural)
   is
      R : constant := 4;
   begin
      case Icon is
         when WNM.Looper.Empty =>
            --  Nothing recorded: the column is blank above the bar count.
            null;

         when WNM.Looper.Stopped =>
            --  Square: has content, not sounding.
            Screen.Draw_Rect (((Cx - R, Cy - R), 2 * R, 2 * R));

         when WNM.Looper.Playing_Icon =>
            --  Filled triangle pointing right.
            for Dy in 0 .. 2 * R loop
               declare
                  Half : constant Natural :=
                    (if Dy <= R then Dy else 2 * R - Dy);
               begin
                  Screen.Draw_H_Line (Cx - R, Cx - R + Half, Cy - R + Dy);
               end;
            end loop;

         when WNM.Looper.Armed =>
            --  Hollow circle: waiting for the first note.
            Screen.Draw_Circle ((Cx, Cy), R);

         when WNM.Looper.Recording_Icon =>
            --  Filled circle: recording or overdubbing. Integer search
            --  instead of a square root, R is 4 so this is 4 steps.
            for Dy in -R .. R loop
               declare
                  Limit : constant Natural := R * R - Dy * Dy;
                  Dx    : Natural := 0;
               begin
                  while (Dx + 1) * (Dx + 1) <= Limit loop
                     Dx := Dx + 1;
                  end loop;
                  Screen.Draw_H_Line (Cx - Dx, Cx + Dx, Cy + Dy);
               end;
            end loop;
      end case;
   end Draw_Track_Icon;

   -----------------
   -- Draw_Tracks --
   -----------------

   procedure Draw_Tracks (Selected : Column_Id) is
      use WNM.Looper;
   begin
      for Col in Column_Id loop
         declare
            X  : constant Natural := Column_Left (Col);
            Cx : constant Natural := Column_Center (Col);
         begin
            if Col = AUT_Column then
               Draw_Str (X, Icon_Row_Y - Font_Height / 2, "AUT");
               Draw_Str (X, Bars_Row_Y, Auto_Img (Auto_Setting));
            else
               declare
                  T : constant Loop_Track := Loop_Track (Col);
               begin
                  Draw_Track_Icon (Icon (T), Cx, Icon_Row_Y);
                  Draw_Str (X, Bars_Row_Y, Bars_Img (Bars (T)));
                  Draw_Str (X, Value_Text_Y, Quant_Img (Quantize (T)));
               end;
            end if;

            if Col = Selected then
               --  Under the whole column, not just one value: left and
               --  right pick a column here, and up/down and A then act on
               --  everything in it.
               Screen.Draw_Line
                 ((X - 1, Select_Line_Y),
                  (X + Column_Width, Select_Line_Y));
            end if;
         end;
      end loop;
   end Draw_Tracks;

   --------------
   -- Draw_Arp --
   --------------

   procedure Draw_Arp is
      use WNM.Looper;

      Row_1 : constant := Box_Top + 3;
      Row_2 : constant := Box_Top + 12;
      Row_3 : constant := Box_Top + 21;
      Row_4 : constant := Box_Top + 30;
      Left  : constant := Box_Left + 4;
   begin
      if not WNM.Project.Looper_Arp_Available then
         --  The Chord track plays held notes as a plain poly chord and
         --  never arps, and a MIDI-out track has no arp instance.
         Draw_Str (Left, Row_1, "No arp on this track");
      else
         declare
            Chan : constant Arp_Channel :=
              Arp_Channel (WNM.Project.Looper_Arp_Channel);
         begin
            Draw_Str (Left, Row_1, "Arp " & Img (Arp_Style (Chan)));
            Draw_Str (Left, Row_2, "Div " & Img (Arp_Division (Chan)));
            Draw_Str (Left, Row_3,
                      "Oct " &
                        (if Arp_Octave_Down (Chan)
                           and then Arp_Octave_Up (Chan)
                         then "-1 +1"
                         elsif Arp_Octave_Down (Chan) then "-1"
                         elsif Arp_Octave_Up (Chan) then "+1"
                         else "none"));
         end;
      end if;

      --  The drum sidecar, which is what a held track pad pulses on. One
      --  setting for the whole looper, and A and up/down edit it here
      --  because the pads are already the note arp's surface.
      Draw_Str (Left, Row_4,
                "Pad " &
                  (if Drum_Pulse_Enabled
                   then "pulse " & Img (Drum_Division)
                   else "pulse off"));
   end Draw_Arp;

   ------------------
   -- Draw_Buttons --
   ------------------

   procedure Draw_Buttons is
      Left : constant := Box_Left + 4;
   begin
      Draw_Str (Left, Box_Top + 3,  "Play  arm play dub");
      Draw_Str (Left, Box_Top + 12, "Play2 stop clr undo");
      Draw_Str (Left, Box_Top + 21, "Edit  keyboard");
      Draw_Str (Left, Box_Top + 30, "B     clear track");
   end Draw_Buttons;

   ---------------
   -- Draw_Held --
   ---------------

   procedure Draw_Held is
      Left : constant := Box_Left + 4;
   begin
      Draw_Str (Left, Box_Top + 3,  "Step1-8  stutter");
      Draw_Str (Left, Box_Top + 12, "Step9-16 dub delay");
      Draw_Str (Left, Box_Top + 21, "Edit+Play clr trk");
      Draw_Str (Left, Box_Top + 30, "Play+arrw bpm/vol");
   end Draw_Held;

   ----------
   -- Draw --
   ----------

   overriding
   procedure Draw (This : in out Looper_Settings_Menu) is
      pragma Unreferenced (This);
   begin
      Draw_Menu_Box
        ((case Tab is
            when Tracks_Tab  => "Looper Tracks",
            when Arp_Tab     => "LiveArp",
            when Buttons_Tab => "Buttons",
            when Held_Tab    => "Hold"),
         Count => Top_Settings_Count,
         Index => Top_Settings'Pos (Tab));

      case Tab is
         when Tracks_Tab  => Draw_Tracks (Column);
         when Arp_Tab     => Draw_Arp;
         when Buttons_Tab => Draw_Buttons;
         when Held_Tab    => Draw_Held;
      end case;
   end Draw;

   --------------
   -- On_Event --
   --------------

   overriding
   procedure On_Event (This  : in out Looper_Settings_Menu;
                       Event : Menu_Event)
   is
      pragma Unreferenced (This);
      use WNM.Looper;

      procedure Sync_Selected_Track is
      begin
         --  Landing on a track column is what decides which track the
         --  Play button arms and clears, so the engine's own selection
         --  follows the cursor.
         if Column /= AUT_Column then
            Select_Track (Loop_Track (Column));
         end if;
      end Sync_Selected_Track;

      procedure Next_Tab is
      begin
         if Tab = Top_Settings'Last then
            if WNM.Persistent.Data.Tab_Wrap then
               Set_Tab (Top_Settings'First);
            end if;
         else
            Set_Tab (Top_Settings'Succ (Tab));
         end if;
      end Next_Tab;

      procedure Prev_Tab is
      begin
         if Tab = Top_Settings'First then
            if WNM.Persistent.Data.Tab_Wrap then
               Set_Tab (Top_Settings'Last);
            end if;
         else
            Set_Tab (Top_Settings'Pred (Tab));
         end if;
      end Prev_Tab;
   begin
      case Event.Kind is
         when Right_Press =>
            --  On the track grid, left and right walk the five columns
            --  first and only change tab once past the end, so the one
            --  tab with its own horizontal content still gets the arrows.
            if Tab = Tracks_Tab and then Column /= Column_Id'Last then
               Set_Column (Column + 1);
               Sync_Selected_Track;
            else
               Next_Tab;
            end if;

         when Left_Press =>
            if Tab = Tracks_Tab and then Column /= Column_Id'First then
               Set_Column (Column - 1);
               Sync_Selected_Track;
            else
               Prev_Tab;
            end if;

         when Up_Press =>
            if Tab = Arp_Tab then
               Set_Drum_Division
                 (if Drum_Division = Arp_Division_Kind'Last
                  then Arp_Division_Kind'First
                  else Arp_Division_Kind'Succ (Drum_Division));

            elsif Tab = Tracks_Tab then
               if Column = AUT_Column then
                  Set_Auto_Setting (Auto_Next (Auto_Setting));
               else
                  declare
                     T : constant Loop_Track := Loop_Track (Column);
                  begin
                     if Bars (T) /= Bar_Count'Last then
                        Set_Bars (T, Bars (T) + 1, WNM.Time.Clock, null);
                     end if;
                  end;
               end if;
            end if;

         when Down_Press =>
            if Tab = Arp_Tab then
               Set_Drum_Division
                 (if Drum_Division = Arp_Division_Kind'First
                  then Arp_Division_Kind'Last
                  else Arp_Division_Kind'Pred (Drum_Division));

            elsif Tab = Tracks_Tab then
               if Column = AUT_Column then
                  --  The other way round the four values, so down undoes
                  --  up instead of cycling on past it.
                  if Auto_Setting = Auto_Kind'First then
                     Set_Auto_Setting (Auto_Kind'Last);
                  else
                     Set_Auto_Setting (Auto_Kind'Pred (Auto_Setting));
                  end if;
               else
                  declare
                     T : constant Loop_Track := Loop_Track (Column);
                  begin
                     if Bars (T) /= Bar_Count'First then
                        Set_Bars (T, Bars (T) - 1, WNM.Time.Clock, null);
                     end if;
                  end;
               end if;
            end if;

         when A_Press =>
            if Tab = Arp_Tab then
               Set_Drum_Pulse_Enabled (not Drum_Pulse_Enabled);

            elsif Tab = Tracks_Tab and then Column /= AUT_Column then
               declare
                  T : constant Loop_Track := Loop_Track (Column);
               begin
                  Set_Quantize (T, Quantize_Next (Quantize (T)));
               end;
            end if;

         when B_Press =>
            if Tab = Tracks_Tab and then Column /= AUT_Column then
               --  Clears the selected track, or undoes that clear if it
               --  is already cleared and nothing has recorded over it.
               --  Same thing Edit held plus Play does, somewhere it can
               --  actually be found.
               WNM.Project.Looper_Clear_Track;
            end if;

         when Slider_Touch =>
            null;
      end case;
   end On_Event;

   ---------------
   -- On_Pushed --
   ---------------

   overriding
   procedure On_Pushed (This : in out Looper_Settings_Menu) is
      pragma Unreferenced (This);
   begin
      --  Opens on the track grid, with the cursor on whichever track the
      --  engine already has selected.
      Set_Tab (Tracks_Tab);
      Set_Column (Column_Id (WNM.Looper.Selected_Track));
   end On_Pushed;

   --------------
   -- On_Focus --
   --------------

   overriding
   procedure On_Focus (This       : in out Looper_Settings_Menu;
                       Exit_Value : Window_Exit_Value)
   is
      pragma Unreferenced (This, Exit_Value);
   begin
      null;
   end On_Focus;

end WNM.GUI.Menu.Looper_Settings;

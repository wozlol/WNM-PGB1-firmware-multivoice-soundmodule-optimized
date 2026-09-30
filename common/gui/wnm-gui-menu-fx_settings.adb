-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--                  Copyright (C) 2016-2026 Fabien Chouteau                  --
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

with MIDI.Time; use MIDI.Time;

with WNM.GUI.Menu.Drawing; use WNM.GUI.Menu.Drawing;
with WNM.Screen;
with WNM.GUI.Bitmap_Fonts;
with WNM.Project; use WNM.Project;

with WNM.Persistent;

package body WNM.GUI.Menu.FX_Settings is

   Singleton : aliased Instance;

   -----------------
   -- Push_Window --
   -----------------

   procedure Push_Window is
   begin
      Push (Singleton'Access);
   end Push_Window;

   ------------
   -- To_Top --
   ------------

   function To_Top (Sub : Sub_Settings) return Top_Settings
   is (case Sub is
          when Auto_Fill_Tracks_Select => Auto_Fill_Tracks_Select,
          when Auto_Fill_Low_Proba => Auto_Fill_Low_Proba,
          when Auto_Fill_High_Proba => Auto_Fill_High_Proba,
          when Auto_Fill_Build_Proba => Auto_Fill_Build_Proba,
          when Filter_LP_Cutoff | Filter_LP_Reso => Filter_LP,
          when Filter_BP_Cutoff | Filter_BP_Reso => Filter_BP,
          when Filter_HP_Cutoff | Filter_HP_Reso => Filter_HP,
          when Filter_Sweep_Rate | Filter_Sweep_Amp => Filter_Sweep,
          when Stutter_Pattern_A => Stutter_Pattern_A,
          when Stutter_Pattern_B => Stutter_Pattern_B,
          when Stutter_Attack | Stutter_Release => Stutter_Env);

   ------------------
   -- Draw_Pattern --
   ------------------

   procedure Draw_Pattern (Pattern : Stutter_Patterns;
                           Selected : Step_Count := Step_Count'Last)
   is
      X : Natural := Box_Left + 4;
      Y : constant Natural := Box_Center.Y + 5;
   begin
      for Idx in Stutter_Pattern_Range loop
         if Stutter_Step_Mute (Pattern, Idx) then
            --  Mute
            Screen.Fill_Rect (((X, Y), 3, 1));
         else
            --  Unmute
            Screen.Fill_Rect (((X, Y - 5), 3, 5));
         end if;

         if Idx = Selected then
            Draw_Str (X - 1, Y - 5 - Font_Height - 1,
                      (if not Stutter_Step_Mute (Pattern, Idx)
                       then "" & Bitmap_Fonts.Arrow_Down
                       else "" & Bitmap_Fonts.Arrow_Up));
            Draw_Str (Box_Left + 3, Value_Text_Y,
                      Step_Count'Image (Idx + 1) & "/24");
         end if;

         X := X + 5;
      end loop;
   end Draw_Pattern;

   ---------------------------
   -- Draw_Auto_Fill_Tracks --
   ---------------------------

   procedure Draw_Auto_Fill_Tracks (Selected : Tracks; Edit : Boolean) is
      X : Natural := Box_Left + 8;
      Y : constant Natural := Box_Center.Y + 5;
   begin
      for T in Tracks loop
         if Auto_Fill_Track (T) then
            --  On
            Screen.Fill_Rect (((X, Y - 5), 5, 5));
         else
            --  Off
            Screen.Fill_Rect (((X, Y), 5, 1));
         end if;

         if Edit and then T = Selected then
            Draw_Str (X, Y - 5 - Font_Height - 1,
                      (if Auto_Fill_Track (T)
                       then "" & Bitmap_Fonts.Arrow_Down
                       else "" & Bitmap_Fonts.Arrow_Up));
            Draw_Str (Box_Left + 3, Value_Text_Y, WNM.Project.Track_Name (T));
         end if;

         X := X + 7;
      end loop;
   end Draw_Auto_Fill_Tracks;

   ----------
   -- Draw --
   ----------

   overriding
   procedure Draw (This   : in out Instance) is
      Sub : constant Sub_Settings := This.Item;
      Top : constant Top_Settings :=
        (if This.On_Prefs then Preferences else To_Top (Sub));
   begin
      Draw_Menu_Box ("Live FX",
                     Count => Top_Count,
                     Index => Top_Settings'Pos (Top));

      if This.On_Prefs then
         declare
            Spacing : constant := 32;

            procedure Col (Pos   : Natural;
                           Label : String;
                           Val   : String;
                           Sel   : Boolean)
            is
               X : constant Natural := Box_Left + 6 + Pos * Spacing;
            begin
               Draw_Str (X, Value_Text_Y - 8, Val);
               Draw_Value_Pos (Label, X, Sel);
            end Col;
         begin
            Draw_Title
              ((case This.Pref_Sel is
                  when Pref_Tab_Wrap   => "Menu Tab Wrap-Around",
                  when Pref_Glide_Res  => "Glide Resolution",
                  when Pref_Bend_Res   => "Pitch Bend Res",
                  when Pref_Bend_Range => "Pitch Bend Range"),
               "");

            Col (0, "TAB",
                 (if WNM.Persistent.Data.Tab_Wrap then "On" else "Off"),
                 This.Pref_Sel = Pref_Tab_Wrap);
            Col (1, "GLD", Img (WNM.Persistent.Data.Glide_Res),
                 This.Pref_Sel = Pref_Glide_Res);
            Col (2, "BND", Img (WNM.Persistent.Data.Bend_Res),
                 This.Pref_Sel = Pref_Bend_Res);
            Col (3, "RNG", Img (WNM.Persistent.Data.Bend_Range),
                 This.Pref_Sel = Pref_Bend_Range);
         end;

         return;
      end if;

      case Top is
         when Auto_Fill_Tracks_Select =>
            Draw_Title ("Auto-Fill Tracks", "");
            Draw_Auto_Fill_Tracks (This.Track_Select, This.Edit_Pattern);

         when Auto_Fill_Low_Proba =>
            Draw_Title ("Auto-Fill Low", "(FX #10)");
            Draw_Value (WNM.Project.Get_Auto_Fill_Low'Img & "%");

         when Auto_Fill_High_Proba =>
            Draw_Title ("Auto-Fill High", "(FX #11)");
            Draw_Value (WNM.Project.Get_Auto_Fill_High'Img & "%");

         when Auto_Fill_Build_Proba =>
            Draw_Title ("Auto-Fill Build-up", "(FX #12)");
            Draw_Value (WNM.Project.Get_Auto_Fill_Buildup'Img & "%");

         when Filter_LP =>
            Draw_Title ("Low-Pass(FX #5 #13)", "");
            Draw_CC_Value (Id => B,
                           Value => Project.FX_Filter_LP_Cutoff,
                           Label => "CTF",
                           Selected => Sub = Filter_LP_Cutoff);
            Draw_CC_Value (Id => C,
                           Value => Project.FX_Filter_LP_Reso,
                           Label => "RES",
                           Selected => Sub = Filter_LP_Reso);

         when Filter_BP =>
            Draw_Title ("Band-Pass(FX #6 #14)", "");
            Draw_CC_Value (Id => B,
                           Value => Project.FX_Filter_BP_Cutoff,
                           Label => "CTF",
                           Selected => Sub = Filter_BP_Cutoff);
            Draw_CC_Value (Id => C,
                           Value => Project.FX_Filter_BP_Reso,
                           Label => "RES",
                           Selected => Sub = Filter_BP_Reso);

         when Filter_HP =>
            Draw_Title ("High-Pass(FX #7 #15)", "");
            Draw_CC_Value (Id => B,
                           Value => Project.FX_Filter_HP_Cutoff,
                           Label => "CTF",
                           Selected => Sub = Filter_HP_Cutoff);
            Draw_CC_Value (Id => C,
                           Value => Project.FX_Filter_HP_Reso,
                           Label => "RES",
                           Selected => Sub = Filter_HP_Reso);

         when Filter_Sweep =>
            Draw_Title ("Auto-Filter Sweep", "");
            Draw_CC_Value (Id => B,
                           Value => Project.FX_Filter_Sweep_Rate,
                           Label => "RAT",
                           Selected => Sub = Filter_Sweep_Rate);
            Draw_CC_Value (Id => C,
                           Value => Project.FX_Filter_Sweep_Amp,
                           Label => "AMP",
                           Selected => Sub = Filter_Sweep_Amp);

         when Stutter_Pattern_A =>
            Draw_Title ("Stutter A (FX #8)", "");
            Draw_Pattern (Stutter_Pattern_A,
                          (if This.Edit_Pattern
                           then This.Pattern_Step_Select
                           else Step_Count'Last));
         when Stutter_Pattern_B =>
            Draw_Title ("Stutter B (FX #16)", "");
            Draw_Pattern (Stutter_Pattern_B,
                          (if This.Edit_Pattern
                           then This.Pattern_Step_Select
                           else Step_Count'Last));

         when Stutter_Env =>
            Draw_Title ("Stutter Envelope", "");
            Draw_CC_Value (Id => B,
                           Value => Project.Stutter_Attack,
                           Label => "ATK",
                           Selected => Sub = Stutter_Attack);
            Draw_CC_Value (Id => C,
                           Value => Project.Stutter_Release,
                           Label => "REL",
                           Selected => Sub = Stutter_Release);


         when Preferences =>
            null;  --  handled above, before this case
      end case;

      if Sub in Auto_Fill_Tracks_Select |
                Stutter_Pattern_A |
                Stutter_Pattern_B
        and then
          not This.Edit_Pattern
      then
         Draw_Str (Box_Left + 3, Value_Text_Y, "Press A to edit");
      end if;

   end Draw;

   --------------
   -- On_Event --
   --------------

   overriding
     --------------
     -- On_Event --
     --------------

   procedure On_Event (This  : in out Instance;
                       Event : Menu_Event)
   is
      Sub : constant Sub_Settings := This.Item;
   begin
      if This.On_Prefs then
         declare
            procedure Toggle is
            begin
               case This.Pref_Sel is
                  when Pref_Tab_Wrap =>
                     WNM.Persistent.Data.Tab_Wrap :=
                       not WNM.Persistent.Data.Tab_Wrap;
                  when Pref_Glide_Res =>
                     WNM.Persistent.Data.Glide_Res :=
                       (if WNM.Persistent.Data.Glide_Res = High
                        then Low else High);
                  when Pref_Bend_Res =>
                     WNM.Persistent.Data.Bend_Res :=
                       (if WNM.Persistent.Data.Bend_Res = High
                        then Low else High);
                  when Pref_Bend_Range =>
                     WNM.Persistent.Data.Bend_Range :=
                       (if WNM.Persistent.Data.Bend_Range = One_Octave
                        then Two_Semitones else One_Octave);
               end case;
               --  Deliberately not saved here. Persistent.Save writes to
               --  flash, and the rest of the firmware only ever does that
               --  at shutdown, from Power_Control.Save_Before_Shutdown.
               --  Doing it from a keypress, while the code is executing
               --  from that same flash and audio is streaming, hangs the
               --  device. These settings persist on power down like every
               --  other global setting.
            end Toggle;
         begin
            case Event.Kind is
               when Right_Press =>
                  if This.Pref_Sel /= Pref_Item'Last then
                     This.Pref_Sel := Pref_Item'Succ (This.Pref_Sel);
                  elsif WNM.Persistent.Data.Tab_Wrap then
                     --  Off the end of the last tab, round to the first.
                     This.On_Prefs := False;
                     This.Item := Sub_Settings'First;
                  end if;

               when Left_Press =>
                  if This.Pref_Sel /= Pref_Item'First then
                     This.Pref_Sel := Pref_Item'Pred (This.Pref_Sel);
                  else
                     This.On_Prefs := False;
                     This.Item := Sub_Settings'Last;
                  end if;

               when A_Press | Up_Press | Down_Press =>
                  Toggle;

               when B_Press =>
                  Menu.Pop (Success);

               when others =>
                  null;
            end case;
         end;

         return;
      end if;

      case Event.Kind is
         when Right_Press =>
            if This.Edit_Pattern then
               if This.Pattern_Step_Select /= Stutter_Pattern_Range'Last then
                  This.Pattern_Step_Select := @ + 1;
               end if;
               if This.Track_Select /= Tracks'Last then
                  This.Track_Select := @ + 1;
               end if;
            elsif This.Item = Sub_Settings'Last then
               This.On_Prefs := True;
            else
               Next (This.Item);
            end if;

         when Left_Press =>
            if This.Edit_Pattern then
               if This.Pattern_Step_Select /= Stutter_Pattern_Range'First then
                  This.Pattern_Step_Select := @ - 1;
               end if;
               if This.Track_Select /= Tracks'First then
                  This.Track_Select := @ - 1;
               end if;
            elsif This.Item = Sub_Settings'First then
               if WNM.Persistent.Data.Tab_Wrap then
                  This.On_Prefs := True;
                  This.Pref_Sel := Pref_Item'Last;
               end if;
            else
               Prev (This.Item);
            end if;

         when Up_Press =>
            if This.Edit_Pattern then
               case Sub is
                  when Auto_Fill_Tracks_Select =>
                     Project.Auto_Fill_Track_Set (This.Track_Select);
                  when Stutter_Pattern_A =>
                     Project.Stutter_Step_Clear (Stutter_Pattern_A,
                                                 This.Pattern_Step_Select);
                  when Stutter_Pattern_B =>
                     Project.Stutter_Step_Clear (Stutter_Pattern_B,
                                                 This.Pattern_Step_Select);
                  when others =>
                     null;
               end case;
            else
               Project.Next_Value (This.Item);
            end if;

         when Down_Press =>
            if This.Edit_Pattern then
               case Sub is
                  when Auto_Fill_Tracks_Select =>
                     Project.Auto_Fill_Track_Clear (This.Track_Select);
                  when Stutter_Pattern_A =>
                     Project.Stutter_Step_Set (Stutter_Pattern_A,
                                               This.Pattern_Step_Select);
                  when Stutter_Pattern_B =>
                     Project.Stutter_Step_Set (Stutter_Pattern_B,
                                               This.Pattern_Step_Select);
                  when others =>
                     null;
               end case;
            else
               Project.Prev_Value (This.Item);
            end if;

         when A_Press =>
            case Sub is
               when Stutter_Pattern_A |
                    Stutter_Pattern_B |
                    Auto_Fill_Tracks_Select =>
                  This.Edit_Pattern := not @;
               when others =>
                  null;
            end case;

         when B_Press =>
            case Sub is
               when Stutter_Pattern_A |
                    Stutter_Pattern_B |
                    Auto_Fill_Tracks_Select =>
                  if This.Edit_Pattern then
                     This.Edit_Pattern := False;
                     return;
                  end if;
               when others =>
                  null;
            end case;

            Menu.Pop (Success);
         when Slider_Touch =>
            Project.Set (This.Item, Event.Slider_Value);
      end case;
   end On_Event;

   --------------
   -- On_Focus --
   --------------

   overriding
   procedure On_Focus (This       : in out Instance;
                       Exit_Value : Window_Exit_Value)
   is
   begin
      This.Edit_Pattern := False;
   end On_Focus;

end WNM.GUI.Menu.FX_Settings;

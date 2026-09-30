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

private with WNM.Project;
private with Enum_Next;

package WNM.GUI.Menu.FX_Settings is

   procedure Push_Window;

private
   type Top_Settings is (Auto_Fill_Tracks_Select,
                         Auto_Fill_Low_Proba,
                         Auto_Fill_High_Proba,
                         Auto_Fill_Build_Proba,
                         Filter_LP,
                         Filter_BP,
                         Filter_HP,
                         Filter_Sweep,
                         Stutter_Pattern_A,
                         Stutter_Pattern_B,
                         Stutter_Env,
                         Preferences);

   subtype Sub_Settings
     is WNM.Project.FX_Settings
     range WNM.Project.FX_Settings'First .. WNM.Project.Stutter_Release;
   --  We don't cover the Alt slider settings here because their are
   --  available in Alt/FX mode.

   package Sub_Settings_Next is new Enum_Next (Sub_Settings, Wrap => False);
   use Sub_Settings_Next;

   function Top_Count is new Enum_Count (Top_Settings);

   type Pref_Item is (Pref_Tab_Wrap, Pref_Glide_Res,
                      Pref_Bend_Res, Pref_Bend_Range);
   package Pref_Item_Next is new Enum_Next (Pref_Item, Wrap => True);

   type Instance is new Menu_Window with record
      Item : Sub_Settings;

      --  The Preferences tab holds global settings rather than project
      --  ones, so it sits past the end of the project settings instead of
      --  being one of them.
      On_Prefs : Boolean := False;
      Pref_Sel : Pref_Item := Pref_Tab_Wrap;

      Track_Select : Tracks := Tracks'First;
      Edit_Pattern : Boolean := False;
      Pattern_Step_Select : WNM.Project.Stutter_Pattern_Range
        := WNM.Project.Stutter_Pattern_Range'First;
   end record;

   overriding
   procedure Draw (This   : in out Instance);

   overriding
   procedure On_Event (This  : in out Instance;
                       Event : Menu_Event);

   overriding
   procedure On_Pushed (This  : in out Instance) is null;

   overriding
   procedure On_Focus (This       : in out Instance;
                       Exit_Value : Window_Exit_Value);

end WNM.GUI.Menu.FX_Settings;

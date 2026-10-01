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

with WNM.Looper;

package WNM.GUI.Menu.Looper_Settings is

   procedure Push_Window;
   --  What the Step button opens in Four_Track_Looper mode, in place of
   --  Step_Settings. The first tab is the five-column loop track editor,
   --  the second reads back the selected track's LiveArp state (which the
   --  sixteen pads change from here), and the last two are the button
   --  reference, unheld then held.

private

   type Top_Settings is (Tracks_Tab, Arp_Tab, Buttons_Tab, Held_Tab);
   function Top_Settings_Count is new Enum_Count (Top_Settings);

   subtype Column_Id is WNM.Looper.Menu_Column_Id;
   --  Four loop tracks then AUT, the five columns from the spec.

   type Looper_Settings_Menu is new Menu_Window with null record;
   --  No state of its own: the tab and column live in WNM.Looper's Steps
   --  overlay, so this window costs only its tag. Fields here would be
   --  permanent RAM in both modes and there is none spare.

   overriding
   procedure Draw (This : in out Looper_Settings_Menu);

   overriding
   procedure On_Event (This  : in out Looper_Settings_Menu;
                       Event : Menu_Event);

   overriding
   procedure On_Pushed (This  : in out Looper_Settings_Menu);

   overriding
   procedure On_Focus (This       : in out Looper_Settings_Menu;
                       Exit_Value : Window_Exit_Value);

end WNM.GUI.Menu.Looper_Settings;

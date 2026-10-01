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

package WNM.GUI.Menu.Root is

   procedure Push_Root_Window;

private

   type Menu_Items is (Projects,
                       Sequencer_Mode_Select,
                       Looper_Config,
                       Tracks_Mixer,
                       User_Waveform,
                       Live_FX,
                       Inputs,
                       MIDI_Settings,
                       DFU_Mode,
                       System_Info);

   function Menu_Items_Count is new Enum_Count (Menu_Items);

   --  Columns 1-4 are WNM.Looper.Loop_Track, column 5 is the shared AUT
   --  setting, matching the spec's "5 cols, 4 for looper tracks and a 5th
   --  AUT setting". A field here rather than a separate pushed window and
   --  its own singleton: a new Menu_Window costs a tag pointer plus its
   --  own state, around 10 bytes, and this firmware has none to spare
   --  (see LOOPER_MODE_PLAN.md). One more field on the window that already
   --  exists costs close to nothing.
   type Looper_Column_Id is range 1 .. 5;

   type Root_Menu is new Menu_Window with record
      Item : Menu_Items;
      Looper_Column  : Looper_Column_Id := Looper_Column_Id'First;
      Looper_Editing : Boolean := False;
      --  Left/Right already mean "switch root tabs" everywhere else on
      --  this screen, so the Looper tab's own column navigation needs to
      --  be entered first (A, same "Press A to edit" convention the
      --  Live FX tab already uses), same reasoning as Looper_Column above
      --  for why this is a field here and not a pushed window.
   end record;

   overriding
   procedure Draw (This : in out Root_Menu);

   overriding
   procedure On_Event (This  : in out Root_Menu;
                       Event : Menu_Event);

   overriding
   procedure On_Pushed (This  : in out Root_Menu);

   overriding
   procedure On_Focus (This       : in out Root_Menu;
                       Exit_Value : Window_Exit_Value);

   overriding
   procedure On_Pop (This : in out Root_Menu);

end WNM.GUI.Menu.Root;

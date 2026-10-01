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

--  The WNM storage format is a binary format that encodes projects.
--
--  The file is split in several sections (track settings, chords settings,
--  etc.). Sections are made of lists of setting identifier followed by a
--  value.
--
--  To reduce the output size, the sequences section is a bit different in
--  that only Steps that are different than the Default_Step will be encoded.
--
--  Except for string characters, data is always encoded using variable
--  length encoding (LEB128). This means that it will be possible to add
--  more settings in the future without breaking format.
--
--  For instance let's say in format version 1 (v1) there are only 2 chord
--  settings possible. It is tempting to encode the identifiers in the with
--  1-bit. However if a future version 2 (v2) of the format has, say, 8 chord
--  settings the encoding will have to be larger. This means that the decoder
--  for v2 can only read v2 format or needs to know that the file in v1 and
--  adjust accordingly.
--
--  Using LEB128 encoding, future versions of the format will be able
--  to introduce new setting identifiers without breaking backwards
--  compatibility. v2 decoder will still be able to read v1 identifiers.
--
--
--  Here is a basic layout of project format:
--
--  <Global Section>
--    <Setting ID><Value>
--    ...
--  <End of Section>
--  <Track Section>
--    <Track ID>
--    <Setting ID><Value>
--    ...
--  <End of Section>
--  <Pattern Section>
--    <Track ID>
--    <Pattern ID>
--    <Setting ID><Value>
--    ...
--  <End of Section>
--  <Parts Section>
--    <Part ID>
--    <Setting ID><Value>
--    ...
--  <End of Section>
--  <Chord Progression Section>
--    <Chord Progression ID>
--    <Chord Section>
--      <Setting ID><Value>
--      ...
--    <End of Section>
--    ...
--  <End of Section>
--  <Sequence Section>
--    <Seq Change Pattern> <Pattern ID>
--    <Seq Change Track> <TrackID>
--    <Step Section>
--       <Step ID >
--       <Setting ID><Value>
--       ...
--    <End of Section>
--    ...
--  <End of Section>
--  <End of File>

with Ada.Unchecked_Conversion;

with HAL; use HAL;
with WNM.Project_Load_Broadcast;
with WNM.File_System.LEB128_File_Out; use WNM.File_System.LEB128_File_Out;
with WNM.File_System.LEB128_File_In; use WNM.File_System.LEB128_File_In;
with WNM.Project.Storage.File_Out;
with WNM.Project.Storage.File_In;
with WNM.File_System; use WNM.File_System;
with WNM.Looper;

package body WNM.Project.Storage is

   Format_Version : constant := 1;

   procedure Read is new File_In.Read_Gen_Int (Tracks);
   procedure Read is new File_In.Read_Gen_Int (Patterns);
   procedure Read is new File_In.Read_Gen_Int (Sequencer_Steps);
   procedure Read is new File_In.Read_Gen_Enum (Part_Link_Kind);
   procedure Read is new File_In.Read_Gen_Int (Song_Element);
   procedure Read is new File_In.Read_Gen_Int (WNM.Duration_In_Steps);
   procedure Read is new File_In.Read_Gen_Enum (Boolean);
   procedure Read is new File_In.Read_Gen_Int (WNM.Pattern_Length);
   procedure Read is new File_In.Read_Gen_Mod (HAL.UInt8);
   procedure Read is new File_In.Read_Gen_Enum (Trigger_Kind);
   procedure Read is new File_In.Read_Gen_Mod (MIDI.MIDI_Data);
   procedure Read is new File_In.Read_Gen_Enum (Note_Duration);
   procedure Read is new File_In.Read_Gen_Mod (Repeat_Cnt);
   procedure Read is new File_In.Read_Gen_Enum (Repeat_Rate_Kind);
   procedure Read is new File_In.Read_Gen_Enum (Note_Mode_Kind);
   procedure Read is new File_In.Read_Gen_Enum (Sequencer_Mode_Kind);
   procedure Read is new File_In.Read_Gen_Int (WNM.Rand_Percent);
   procedure Read is new File_In.Read_Gen_Enum
     (WNM.Project.Alt_Slider_Control);

   ----------------
   -- Save_Steps --
   ----------------

   procedure Save_Steps (Output : in out File_Out.Instance) is
      use MIDI;

      Out_Pattern : Patterns := Patterns'First;
      Out_Track   : Tracks   := Tracks'First;
   begin
      Output.Start_Sequence;

      for T in Tracks loop
         for P in Patterns loop
            for S in Sequencer_Steps loop
               declare
                  Step : Step_Rec renames
                    G_Project.Steps (T)(P)(S);
               begin
                  if Step /= Default_Step then

                     if P /= Out_Pattern then
                        Output.Change_Pattern_In_Seq (P);
                        Out_Pattern := P;
                     end if;

                     if T /= Out_Track then
                        Output.Change_Track_In_Seq (T);
                        Out_Track := T;
                     end if;

                     Output.Start_Step_Settings (S);

                     --  Using a loop over all settings and a case statement,
                     --  we make sure all settings are handled. This will
                     --  hopefully prevent mistakes when new settings are
                     --  introduced.
                     for Set in Step_Settings loop

                        --  To save space in the output file, we only output
                        --  step setting values if they differ from the
                        --  default ones.

                        case Set is
                           when Condition =>
                              if Step.Trig /= Default_Step.Trig then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.Trig'Enum_Rep));
                              end if;
                           when Repeat =>

                              if Step.Repeat /= Default_Step.Repeat then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.Repeat'Enum_Rep));
                              end if;

                           when Repeat_Rate =>
                              if Step.Repeat_Rate /= Default_Step.Repeat_Rate
                              then
                                 Output.Push (Set);
                                 Output.Push
                                   (Out_UInt (Step.Repeat_Rate'Enum_Rep));
                              end if;

                           when Note_Mode =>
                              if Step.Note_Mode /= Default_Step.Note_Mode then
                                 Output.Push (Set);
                                 Output.Push
                                   (Out_UInt (Step.Note_Mode'Enum_Rep));
                              end if;

                           when Note =>
                              if Step.Note /= Default_Step.Note then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.Note));
                              end if;

                           when Octave_Shift =>
                              if Step.Oct /= Default_Step.Oct then
                                 Output.Push (Set);

                                 declare
                                    Oct : constant Integer :=
                                      Integer (Step.Oct) -
                                      Integer (Octave_Offset'First);
                                 begin
                                    Output.Push
                                      (Out_UInt (UInt8 (Oct)));
                                 end;
                              end if;

                           when Duration =>
                              if Step.Duration /= Default_Step.Duration then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt
                                              (Step.Duration'Enum_Rep));
                              end if;

                           when Velo =>
                              if Step.Velo /= Default_Step.Velo then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.Velo));
                              end if;

                           when CC_A =>
                              if Step.CC_Ena (A) then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.CC_Val (A)));
                              end if;

                           when CC_B =>
                              if Step.CC_Ena (B) then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.CC_Val (B)));
                              end if;

                           when CC_C =>
                              if Step.CC_Ena (C) then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.CC_Val (C)));
                              end if;

                           when CC_D =>
                              if Step.CC_Ena (D) then
                                 Output.Push (Set);
                                 Output.Push (Out_UInt (Step.CC_Val (D)));
                              end if;
                        end case;
                     end loop;
                     Output.End_Section;
                  end if;
               end;

               if Output.Status /= Ok then
                  return;
               end if;
            end loop;
         end loop;
      end loop;
      Output.End_Section;
   end Save_Steps;

   -------------------
   -- Save_Patterns --
   -------------------

   procedure Save_Patterns (Output : in out File_Out.Instance) is
   begin
      for T_Id in Tracks loop
         for P_Id in Patterns loop
            declare
               Pattern : Pattern_Rec renames
                 G_Project.Patterns (T_Id)(P_Id);
            begin
               Output.Start_Pattern_Settings (T_Id, P_Id);

               --  Using a loop over all settings and a case statement, we make
               --  sure all settings are handled. This will hopefully prevent
               --  mistakes when new settings are introduced.
               for Set in Pattern_Settings loop
                  Output.Push (Set);

                  case Set is
                  when Length => Output.Push (Pattern.Length);
                  when Has_Link => Output.Push (Pattern.Has_Link);
                  end case;
               end loop;
               Output.End_Section;
            end;

            if Output.Status /= Ok then
               return;
            end if;

         end loop;
      end loop;
   end Save_Patterns;

   -----------------
   -- Save_Tracks --
   -----------------

   procedure Save_Tracks (Output : in out File_Out.Instance) is
   begin
      for T_Id in Tracks loop
         declare
            Track : Track_Rec renames G_Project.Tracks (T_Id);
         begin
            Output.Start_Track_Settings (T_Id);

            --  Using a loop over all settings and a case statement, we make
            --  sure all settings are handled. This will hopefully prevent
            --  mistakes when new settings are introduced.
            for Set in Track_Settings loop
               Output.Push (Set);

               case Set is
                  when Track_Mode =>
                     Output.Push (Out_UInt (Track.MIDI_Enabled'Enum_Rep));

                  when Engine =>
                     Output.Push (Out_UInt (Track.Engine));

                  when Volume =>
                     Output.Push (Out_UInt (Track.Volume));

                  when Pan =>
                     Output.Push (Out_UInt (Track.Pan));

                  when Master_FX =>
                     Output.Push (Out_UInt (Track.FX'Enum_Rep));

                  when Track_Octave_Offset =>
                     Output.Push
                       (Out_UInt (Integer (Track.Offset) -
                          Integer (Octave_Offset'First)));

                  when Shuffle =>
                     Output.Push (Out_UInt (Track.Shuffle));

                  when LFO_Rate =>
                     Output.Push (Out_UInt (Track.LFO_Rate));

                  when LFO_Amplitude =>
                     Output.Push (Out_UInt (Track.LFO_Amp));

                  when LFO_Shape =>
                     Output.Push (Out_UInt (Track.LFO_Shape'Enum_Rep));

                  when LFO_Target =>
                     Output.Push (Out_UInt (Track.LFO_Target'Enum_Rep));

                  when LFO_Amp_Mode =>
                     Output.Push (Out_UInt (Track.LFO_Amp_Mode'Enum_Rep));

                  when LFO_Sync =>
                     Output.Push (Out_UInt (Track.LFO_Sync'Enum_Rep));

                  when LFO_Loop =>
                     Output.Push (Out_UInt (Track.LFO_Loop'Enum_Rep));

                  when Arp_Mode =>
                     Output.Push (Out_UInt (Track.Arp_Mode'Enum_Rep));

                  when Arp_Notes =>
                     Output.Push (Out_UInt (Track.Arp_Notes'Enum_Rep));

                  when Notes_Per_Chord =>
                     Output.Push (Out_UInt (Track.Notes_Per_Chord'Enum_Rep));

                  when Chord_Voicing =>
                     Output.Push (Out_UInt (Track.Chord_Voicing'Enum_Rep));

                  when Retrig_Enabled =>
                     Output.Push
                       (Out_UInt (Boolean'Pos (Track.Retrig_Enabled)));

                  when Chord_Voice_Count_Setting =>
                     Output.Push (Out_UInt (Integer (Track.Chord_Voices)));

                  when MIDI_Chan =>
                     Output.Push (Out_UInt (Track.Chan));

                  when CC_Default_A =>
                     Output.Push (Track.CC (A).Value);

                  when CC_Default_B =>
                     Output.Push (Track.CC (B).Value);

                  when CC_Default_C =>
                     Output.Push (Track.CC (C).Value);

                  when CC_Default_D =>
                     Output.Push (Track.CC (D).Value);

                  when CC_Ctrl_A =>
                     Output.Push (Track.CC (A).Controller);

                  when CC_Ctrl_B =>
                     Output.Push (Track.CC (B).Controller);

                  when CC_Ctrl_C =>
                     Output.Push (Track.CC (C).Controller);

                  when CC_Ctrl_D =>
                     Output.Push (Track.CC (D).Controller);

                  when CC_Label_A =>
                     Output.Push (Track.CC (A).Label);

                  when CC_Label_B =>
                     Output.Push (Track.CC (D).Label);

                  when CC_Label_C =>
                     Output.Push (Track.CC (C).Label);

                  when CC_Label_D =>
                     Output.Push (Track.CC (D).Label);

                  when MIDI_Instrument =>
                     null; -- We don't save this
               end case;

               if Output.Status /= Ok then
                  return;
               end if;
            end loop;

            Output.End_Section;
         end;

         if Output.Status /= Ok then
            return;
         end if;
      end loop;

   end Save_Tracks;

   ----------------
   -- Save_Parts --
   ----------------

   procedure Save_Parts (Output : in out File_Out.Instance) is
   begin
      for P_Id in Parts loop
         declare
            Part : Song_Part_Rec renames
              G_Project.Parts (P_Id);
         begin
            Output.Start_Part_Settings (P_Id);

            --  Using a loop over all settings and a case statement, we make
            --  sure all settings are handled. This will hopefully prevent
            --  mistakes when new settings are introduced.
            for Set in Part_Settings loop
               Output.Push (Set);

               case Set is
                  when Part_Patterns =>
                     for T_Id in Tracks loop
                        if Part.Track_Mute (T_Id) then
                           Output.Push (Out_UInt (0));
                        else
                           Output.Push
                             (Out_UInt (Part.Pattern_Select (T_Id)'Enum_Rep));
                        end if;
                     end loop;

                  when Part_Length =>
                     Output.Push (Part.Len);

                  when Part_Progression =>
                     Output.Push (Out_UInt (Part.Progression'Enum_Rep));

                  when Part_Link =>
                     Output.Push (Out_UInt (Part.Link'Enum_Rep));
               end case;
            end loop;
            Output.End_Section;
         end;

         if Output.Status /= Ok then
            return;
         end if;

      end loop;
   end Save_Parts;

   -----------------
   -- Save_Chords --
   -----------------

   procedure Save_Chord (Output : in out File_Out.Instance;
                         Chord  :        Chord_Rec)
   is
   begin
      Output.Start_Chord_Settings;

      --  Using a loop over all settings and a case statement, we make sure all
      --  settings are handled. This will hopefully prevent mistakes when new
      --  settings are introduced.
      for Set in Chord_Setting_Kind loop
         Output.Push (Out_UInt (Set'Enum_Rep));
         case Set is
            when Tonic =>
               Output.Push (Out_UInt (Chord.Tonic));
            when Name =>
               Output.Push (Out_UInt (Chord.Name'Enum_Rep));
            when Duration =>
               Output.Push (Out_UInt (Chord.Duration));
         end case;
         if Output.Status /= Ok then
            return;
         end if;
      end loop;
      Output.End_Section;
   end Save_Chord;

   -----------------------
   -- Save_Progressions --
   -----------------------

   procedure Save_Progressions (Output : in out File_Out.Instance) is
   begin
      for P_Id in Chord_Progressions loop
         Output.Start_Chord_Progression (P_Id);

         for C_Id in Chord_Slot_Id'First .. G_Project.Progressions (P_Id).Len
         loop
            Save_Chord (Output,
                        G_Project.Progressions (P_Id).Chords (C_Id));
         end loop;
         Output.End_Section;
      end loop;
   end Save_Progressions;

   -----------------
   -- Save_Global --
   -----------------

   procedure Save_Global (Output : in out File_Out.Instance) is
   begin
      Output.Start_Global;
      Output.Push (Out_UInt (Global_Settings'Enum_Rep (BPM)));

      --  Only store the integer part of the BPM
      Output.Push (Out_UInt (G_Project.BPM));

      Output.Push
        (Out_UInt (Global_Settings'Enum_Rep (Sequencer_Mode_Setting)));
      Output.Push (Out_UInt (Sequencer_Mode_Kind'Enum_Rep (G_Project.Mode)));

      Output.End_Section;
   end Save_Global;

   ------------------------
   -- Save_User_Waveform --
   ------------------------

   procedure Save_User_Waveform (Output : in out File_Out.Instance) is
      function To_U16 is new Ada.Unchecked_Conversion (Tresses.S16,
                                                       Tresses.U16);
   begin
      Output.Start_User_Waveform;
      for Frame of WNM.Synth.User_Waveform loop
         Output.Push (Out_UInt (To_U16 (Frame)));
      end loop;
      Output.End_Section;
   end Save_User_Waveform;

   ----------------
   -- Save_Mixer --
   ----------------

   procedure Save_Mixer (Output : in out File_Out.Instance) is
   begin
      Output.Start_Mixer;

      for S in Project_Mixer_Settings loop
         Output.Push (Out_UInt (S'Enum_Rep));
         Output.Push (Out_UInt (G_Project.Gains (S)));
      end loop;

      Output.End_Section;
   end Save_Mixer;

   -------------
   -- Save_FX --
   -------------

   procedure Save_FX (Output : in out File_Out.Instance) is
   begin
      Output.Start_FX_Settings;

      for S in Project.FX_Settings loop
         Output.Push (Out_UInt (S'Enum_Rep));
         case S is
            when Auto_Fill_Tracks_Select =>
               for Elt of G_Project.FX.Auto_Fill_Tracks loop
                  Output.Push (Elt);
               end loop;
            when Auto_Fill_Low_Proba =>
               Output.Push (G_Project.FX.Auto_Fill_Low_Proba);
            when Auto_Fill_High_Proba =>
               Output.Push (G_Project.FX.Auto_Fill_High_Proba);
            when Auto_Fill_Build_Proba =>
               Output.Push (G_Project.FX.Auto_Fill_Build_Up_Start_Proba);

            when Stutter_Pattern_A =>
               for Elt of G_Project.FX.Pattern_A loop
                  Output.Push (Elt);
               end loop;
            when Stutter_Pattern_B =>
               for Elt of G_Project.FX.Pattern_B loop
                  Output.Push (Elt);
               end loop;

            when Stutter_Attack =>
               Output.Push (G_Project.FX.Stutter_Atk);
            when Stutter_Release =>
               Output.Push (G_Project.FX.Stutter_Rel);

            when Filter_LP_Cutoff =>
               Output.Push (G_Project.FX.LP_Cutoff);
            when Filter_BP_Cutoff =>
               Output.Push (G_Project.FX.BP_Cutoff);
            when Filter_HP_Cutoff =>
               Output.Push (G_Project.FX.HP_Cutoff);

            when Filter_LP_Reso =>
               Output.Push (G_Project.FX.LP_Reso);
            when Filter_BP_Reso =>
               Output.Push (G_Project.FX.BP_Reso);
            when Filter_HP_Reso =>
               Output.Push (G_Project.FX.HP_Reso);

            when Filter_Sweep_Rate =>
               Output.Push (G_Project.FX.Sweep_Rate);
            when Filter_Sweep_Amp =>
               Output.Push (G_Project.FX.Sweep_Amp);

            when Alt_Slider_Track =>
               Output.Push (G_Project.FX.Alt_Slider_Track);

            when Alt_Slider_Ctrl =>
               Output.Push (G_Project.FX.Alt_Slider_Target);
         end case;
      end loop;

      Output.End_Section;
   end Save_FX;

   -------------------
   -- Save_Looper   --
   -------------------

   --  WNM.Looper.Visit_Events calls back with no way to pass this specific
   --  Output instance through (Emit_Proc has the same shape Tick's own
   --  callback does, on purpose, and Tick has no such instance to pass
   --  either), so the instance currently being written to is kept here
   --  for the callback to reach, valid only for the duration of one
   --  Save_Looper call.
   Looper_Save_Output : access File_Out.Instance := null;

   procedure Save_Looper_Event (Track : WNM.Looper.Loop_Track;
                                At_Us : HAL.UInt32;
                                Event : WNM.Looper.MIDI_Event)
   is
      pragma Unreferenced (Track);
   begin
      if Looper_Save_Output = null then
         return;
      end if;
      Looper_Save_Output.Push (Out_UInt (At_Us));
      Looper_Save_Output.Push (Out_UInt (Event.Status));
      Looper_Save_Output.Push (Out_UInt (Event.Data_1));
      Looper_Save_Output.Push (Out_UInt (Event.Data_2));
   end Save_Looper_Event;

   procedure Save_Looper (Output : in out File_Out.Instance) is
   begin
      Output.Start_Looper_Section;
      Output.Push (Out_UInt (WNM.Looper.Auto_Kind'Pos
                     (WNM.Looper.Auto_Setting)));

      for T in WNM.Looper.Loop_Track loop
         Output.Start_Looper_Track (T);

         Output.Push (LT_Length_Us);
         Output.Push (Out_UInt (WNM.Looper.Track_Length_Us (T)));

         Output.Push (LT_Stored_Length_Us);
         Output.Push (Out_UInt (WNM.Looper.Track_Stored_Length_Us (T)));

         Output.Push (LT_Generation);
         Output.Push (Out_UInt (WNM.Looper.Track_Generation (T)));

         Output.Push (LT_Muted);
         Output.Push (WNM.Looper.Track_Muted (T));

         Output.Push (LT_Solo);
         Output.Push (WNM.Looper.Track_Solo (T));

         Output.Push (LT_Hidden);
         Output.Push (WNM.Looper.Track_Hidden (T));

         Output.Push (LT_Start_Offset_Us);
         Output.Push (Out_UInt (WNM.Looper.Track_Start_Offset_Us (T)));

         Output.Push (LT_Bars);
         Output.Push (Out_UInt (WNM.Looper.Bars (T)));

         Output.Push (LT_Quant);
         Output.Push (Out_UInt
                       (WNM.Looper.Quantize_Kind'Pos
                         (WNM.Looper.Quantize (T))));

         Output.Push (LT_Event_Count);
         Output.Push (Out_UInt (WNM.Looper.Track_Event_Count (T)));

         Looper_Save_Output := Output'Unchecked_Access;
         WNM.Looper.Visit_Events (T, Save_Looper_Event'Access);
         Looper_Save_Output := null;

         Output.End_Section;

         exit when Output.Status /= Ok;
      end loop;

      Output.End_Section;
   end Save_Looper;

   ----------
   -- Save --
   ----------

   function Save (Filename :     String;
                  Size     : out File_System.File_Signed_Size)
                  return File_System.Storage_Error
   is

      Output : File_Out.Instance;
   begin
      Output.Open (Filename);

      Size := 0;

      --  First, set the format version
      Output.Push (Out_UInt (Format_Version));

      if Output.Status = Ok then
         Save_Global (Output);
      end if;

      if Output.Status = Ok then
         Save_Tracks (Output);
      end if;

      --  Patterns and Steps hold the step sequencer's own data. In
      --  Four_Track_Looper mode that same RAM is overlaid by the loop
      --  engine's event pool (see WNM.Project.Steps_Storage_Address), so
      --  reading it here as Step_Rec values would decode raw loop event
      --  bytes as sequencer settings, and an out-of-range enum
      --  representation would crash the save. Skip both while Looper owns
      --  that RAM.
      if Output.Status = Ok
        and then Sequencer_Mode = OG_Sequencer
      then
         Save_Patterns (Output);
      end if;

      if Output.Status = Ok then
         Save_Parts (Output);
      end if;

      if Output.Status = Ok then
         Save_Progressions (Output);
      end if;

      if Output.Status = Ok
        and then Sequencer_Mode = OG_Sequencer
      then
         Save_Steps (Output);
      end if;

      if Output.Status = Ok
        and then Sequencer_Mode = Four_Track_Looper
      then
         Save_Looper (Output);
      end if;

      if Output.Status = Ok then
         Save_User_Waveform (Output);
      end if;

      if Output.Status = Ok then
         Save_Mixer (Output);
      end if;

      if Output.Status = Ok then
         Save_FX (Output);
      end if;

      Output.End_File;

      if Output.Status = Ok then
         Size := WNM.File_System.Size;
      end if;

      Output.Close;
      return Output.Status;
   end Save;

   ----------------
   -- Load_Track --
   ----------------

   procedure Load_Track (Input : in out File_In.Instance) is
      procedure To_Track_Settings is new Convert_To_Enum (Track_Settings);

      procedure Read is new File_In.Read_Gen_Enum (Boolean);
      procedure Read is new File_In.Read_Gen_Int (Tracks);
      procedure Read is new File_In.Read_Gen_Int (Audio_Volume);
      procedure Read is new File_In.Read_Gen_Int (Audio_Pan);
      procedure Read is new File_In.Read_Gen_Enum (LFO_Shape_Kind);
      procedure Read is new File_In.Read_Gen_Enum (LFO_Target_Kind);
      procedure Read is new File_In.Read_Gen_Enum (LFO_Amp_Kind);
      procedure Read is new File_In.Read_Gen_Enum (LFO_Loop_Kind);
      procedure Read is new File_In.Read_Gen_Enum (LFO_Sync_Kind);
      procedure Read is new File_In.Read_Gen_Enum (FX_Kind);
      procedure Read is new File_In.Read_Gen_Enum (Arp_Mode_Kind);
      procedure Read is new File_In.Read_Gen_Enum (Arp_Notes_Kind);
      procedure Read is new File_In.Read_Gen_Mod (MIDI.MIDI_Channel);
      procedure Read is new File_In.Read_Gen_Mod (MIDI.MIDI_Data);
      procedure Read is new File_In.Read_Gen_Int
        (Chord_Settings.Chord_Index_Range);
      procedure Read is new File_In.Read_Gen_Int (Shuffle_Value);
      procedure Read is new File_In.Read_Gen_Enum (Chord_Voicing_Kind);
      procedure Read is new File_In.Read_Gen_Int (Chord_Voice_Count);

      T_Id : Tracks;
      S : Track_Settings;
      Raw : In_UInt := 0;
      Success : Boolean;
   begin
      Read (Input, T_Id);

      if Input.Status /= Ok then
         return;
      end if;

      declare
         Track : Track_Rec renames G_Project.Tracks (T_Id);
      begin

         Track := Default_Track;

         loop
            Input.Read (Raw);

            exit when Input.Status /= Ok
              or else Raw = End_Of_Section_Value;

            To_Track_Settings (Raw, S, Success);

            exit when not Success;

            case S is
               when Track_Mode  => Read (Input, Track.MIDI_Enabled);
               when Engine      => Read (Input, Track.Engine);
               when Volume      => Read (Input, Track.Volume);
               when Pan         => Read (Input, Track.Pan);
               when Master_FX   => Read (Input, Track.FX);
               when Track_Octave_Offset =>
                  --  TODO: Implement generic read and write for signed int
                  Input.Read (Raw);
                  declare
                     Tmp : constant Integer :=
                       Integer (Raw) + Integer (Octave_Offset'First);
                  begin
                     if Tmp in Integer (Octave_Offset'First) ..
                       Integer (Octave_Offset'Last)
                     then
                        Track.Offset := Octave_Offset (Tmp);
                     else
                        Input.Set_Format_Error;
                     end if;
                  end;
               when Shuffle     => Read (Input, Track.Shuffle);
               when LFO_Rate    => Read (Input, Track.LFO_Rate);
               when LFO_Amplitude => Read (Input, Track.LFO_Amp);
               when LFO_Shape => Read (Input, Track.LFO_Shape);
               when LFO_Target => Read (Input, Track.LFO_Target);
               when LFO_Amp_Mode => Read (Input, Track.LFO_Amp_Mode);
               when LFO_Sync    => Read (Input, Track.LFO_Sync);
               when LFO_Loop    => Read (Input, Track.LFO_Loop);
               when Arp_Mode    => Read (Input, Track.Arp_Mode);
               when Arp_Notes   => Read (Input, Track.Arp_Notes);
               when Notes_Per_Chord => Read (Input, Track.Notes_Per_Chord);
               when Chord_Voicing => Read (Input, Track.Chord_Voicing);
               when Retrig_Enabled => Read (Input, Track.Retrig_Enabled);
               when Chord_Voice_Count_Setting =>
                  Read (Input, Track.Chord_Voices);
               when MIDI_Chan   => Read (Input, Track.Chan);
               when MIDI_Instrument => null;
               when CC_Default_A => Read (Input, Track.CC (A).Value);
               when CC_Default_B => Read (Input, Track.CC (B).Value);
               when CC_Default_C => Read (Input, Track.CC (C).Value);
               when CC_Default_D => Read (Input, Track.CC (D).Value);
               when CC_Ctrl_A    => Read (Input, Track.CC (A).Controller);
               when CC_Ctrl_B    => Read (Input, Track.CC (B).Controller);
               when CC_Ctrl_C    => Read (Input, Track.CC (C).Controller);
               when CC_Ctrl_D    => Read (Input, Track.CC (D).Controller);
               when CC_Label_A   => File_In.Read (Input, Track.CC (A).Label);
               when CC_Label_B   => File_In.Read (Input, Track.CC (B).Label);
               when CC_Label_C   => File_In.Read (Input, Track.CC (C).Label);
               when CC_Label_D   => File_In.Read (Input, Track.CC (D).Label);
            end case;

            exit when Input.Status /= Ok;
         end loop;
      end;
   end Load_Track;

   ---------------
   -- Load_Part --
   ---------------

   procedure Load_Part (Input : in out File_In.Instance) is
      procedure To_Part_Settings is new Convert_To_Enum (Part_Settings);

      Elt : Song_Element;
      P_Id : Parts;
      S : Part_Settings;
      Raw : In_UInt := 0;
      Success : Boolean;
   begin
      Read (Input, Elt);

      if Elt not in Parts then
         Input.Set_Format_Error;
      else
         P_Id := Elt;
      end if;

      if Input.Status /= Ok then
         return;
      end if;

      declare
         Part : Song_Part_Rec renames G_Project.Parts (P_Id);
      begin

         Part := Default_Part;

         loop
            Input.Read (Raw);

            exit when Input.Status /= Ok
              or else Raw = End_Of_Section_Value;

            To_Part_Settings (Raw, S, Success);

            exit when not Success;

            case S is
               when Part_Patterns =>
                  for Track_Id in Tracks loop
                     declare
                        P_Id : In_UInt;
                     begin
                        Input.Read (P_Id);

                        if P_Id not in
                          In_UInt (Patterns'First) .. In_UInt (Patterns'Last)
                        then
                           Part.Track_Mute (Track_Id) := True;
                           Part.Pattern_Select (Track_Id) := Patterns'First;
                        else
                           Part.Track_Mute (Track_Id) := False;
                           Part.Pattern_Select (Track_Id) := Patterns (P_Id);
                        end if;
                     end;
                  end loop;

               when Part_Length =>
                  Read (Input, Part.Len);

               when Part_Progression =>

                  Read (Input, Elt);

                  if Elt not in Chord_Progressions then
                     Input.Set_Format_Error;
                  else
                     Part.Progression := Elt;
                  end if;

               when Part_Link =>
                  Read (Input, Part.Link);
            end case;

            exit when Input.Status /= Ok;
         end loop;
      end;
   end Load_Part;

   ----------------
   -- Load_Chord --
   ----------------

   procedure Load_Chord (Input : in out File_In.Instance;
                         Chord : in out Chord_Rec)
   is
      procedure To_Chord_Settings
      is new Convert_To_Enum (Chord_Setting_Kind);
      procedure Read is new File_In.Read_Gen_Mod (MIDI.MIDI_Key);
      procedure Read is new File_In.Read_Gen_Enum
        (WNM.Chord_Settings.Chord_Name);
      procedure Read is new File_In.Read_Gen_Int (Duration_In_Steps);

      S : Chord_Setting_Kind;
      Raw : In_UInt;
      Success : Boolean;
   begin
      Chord := Default_Chord;
      loop
         Input.Read (Raw);

         exit when Input.Status /= Ok
           or else Raw = End_Of_Section_Value;

         To_Chord_Settings (Raw, S, Success);

         exit when not Success;

         case S is
            when Tonic    => Read (Input, Chord.Tonic);
            when Name     => Read (Input, Chord.Name);
            when Duration => Read (Input, Chord.Duration);
         end case;
         exit when Input.Status /= Ok;
      end loop;
   end Load_Chord;

   ----------------------
   -- Load_Progression --
   ----------------------

   procedure Load_Progression (Input : in out File_In.Instance) is
      procedure Read is new File_In.Read_Gen_Int (Chord_Progressions);

      P_Id : Chord_Progressions;
      Token : Token_Kind;
   begin
      Read (Input, P_Id);

      if Input.Status /= Ok then
         return;
      end if;

      declare
         Prog : Chord_Progression_Rec renames G_Project.Progressions (P_Id);
         Chord_Id : Natural := Natural (Chord_Slot_Id'First);
      begin

         Prog := Default_Chord_Progression;

         loop
            Input.Read (Token);

            exit when Input.Status /= Ok
              or else Token = End_Of_Section;

            if Chord_Id > Natural (Chord_Slot_Id'Last) then
               Input.Set_Format_Error;
               return;
            end if;

            if Token = Chord_Section then
               Load_Chord (Input, Prog.Chords (Chord_Slot_Id (Chord_Id)));
               Prog.Len := Chord_Slot_Id (Chord_Id);
               Chord_Id := @ + 1;
            else
               Input.Set_Format_Error;
            end if;

            exit when Input.Status /= Ok;
         end loop;
      end;
   end Load_Progression;

   ------------------
   -- Load_Pattern --
   ------------------

   procedure Load_Pattern (Input : in out File_In.Instance) is
      procedure To_Pattern_Settings is new Convert_To_Enum (Pattern_Settings);

      T_Id : Tracks;
      P_Id : Patterns;
      S : Pattern_Settings;
      Raw : In_UInt := 0;
      Success : Boolean;
   begin
      Read (Input, T_Id);
      Read (Input, P_Id);

      if Input.Status /= Ok then
         return;
      end if;

      declare
         Pattern : Pattern_Rec renames G_Project.Patterns (T_Id)(P_Id);
      begin

         Pattern := Default_Pattern;

         loop
            Input.Read (Raw);

            exit when Input.Status /= Ok
              or else Raw = End_Of_Section_Value;

            To_Pattern_Settings (Raw, S, Success);

            exit when not Success;

            case S is
               when Length   => Read (Input, Pattern.Length);
               when Has_Link => Read (Input, Pattern.Has_Link);
            end case;

            exit when Input.Status /= Ok;
         end loop;
      end;
   end Load_Pattern;

   ---------------
   -- Load_Step --
   ---------------

   procedure Load_Step (Input : in out File_In.Instance;
                        P : Patterns; T : Tracks; S : Sequencer_Steps)
   is
      procedure To_Step_Settings is new Convert_To_Enum (Step_Settings);

      Step : Step_Rec renames G_Project.Steps (T)(P)(S);
      Set : Step_Settings;
      Raw : In_UInt;
      Success : Boolean;

      Val : UInt8;
   begin
      loop
         Input.Read (Raw);

         exit when Input.Status /= Ok
           or else Raw = End_Of_Section_Value;

         To_Step_Settings (Raw, Set, Success);

         exit when not Success;

         case Set is
            when Condition    => Read (Input, Step.Trig);
            when Note         => Read (Input, Step.Note);

            when Octave_Shift =>
               Read (Input, Val);
               declare
                  Oct : constant Integer :=
                    Integer (Val) + Integer (Octave_Offset'First);
               begin
                  Step.Oct := Octave_Offset (Oct);
               end;

            when Duration     => Read (Input, Step.Duration);
            when Velo         => Read (Input, Step.Velo);
            when Repeat       => Read (Input, Step.Repeat);
            when Repeat_Rate  => Read (Input, Step.Repeat_Rate);
            when CC_A         =>
               Step.CC_Ena (A) := True;
               Read (Input, Step.CC_Val (A));
            when CC_B         =>
               Step.CC_Ena (B) := True;
               Read (Input, Step.CC_Val (B));
            when CC_C         =>
               Step.CC_Ena (C) := True;
               Read (Input, Step.CC_Val (C));
            when CC_D         =>
               Step.CC_Ena (D) := True;
               Read (Input, Step.CC_Val (D));

            when Note_Mode => Read (Input, Step.Note_Mode);
         end case;

         exit when Input.Status /= Ok;
      end loop;
   end Load_Step;

   --------------------
   -- Load_Sequences --
   --------------------

   procedure Load_Sequences (Input : in out File_In.Instance) is
      Token : Token_Kind;

      In_Pattern : Patterns        := Patterns'First;
      In_Track   : Tracks          := Tracks'First;
      In_Step    : Sequencer_Steps := Sequencer_Steps'First;
   begin
      --  Init all steps to the default value
      for P in Patterns loop
         for T in Tracks loop
            for S in Sequencer_Steps loop
               G_Project.Steps (T)(P)(S) := Default_Step;
            end loop;
         end loop;
      end loop;

      loop

         Input.Read (Token);

         if Input.Status /= Ok then
            return;
         end if;

         case Token is
            when Seq_Change_Track =>
               Read (Input, In_Track);

            when Seq_Change_Pattern =>
               Read (Input, In_Pattern);

            when Step_Section =>
               Read (Input, In_Step);

               exit when Input.Status /= Ok;

               Load_Step (Input, In_Pattern, In_Track, In_Step);

            when End_Of_Section =>
               return;

            when others =>
               Input.Set_Format_Error;
               return;
         end case;

         exit when Input.Status /= Ok;
      end loop;
   end Load_Sequences;

   -----------------
   -- Load_Global --
   -----------------

   procedure Load_Global (Input : in out File_In.Instance) is
      procedure To_Global_Settings is new Convert_To_Enum (Global_Settings);

      Set : Global_Settings;
      Raw : In_UInt;
      Success : Boolean;
   begin
      loop
         Input.Read (Raw);

         exit when Input.Status /= Ok
           or else Raw = End_Of_Section_Value;

         To_Global_Settings (Raw, Set, Success);

         exit when not Success;

         case Set is
            when BPM  => Input.Read (Raw);
               if Raw
                      in In_UInt (Beat_Per_Minute'First) ..
                        In_UInt (Beat_Per_Minute'Last)
               then
                  G_Project.BPM := Beat_Per_Minute (Raw);
               end if;

            when Sequencer_Mode_Setting =>
               Read (Input, G_Project.Mode);
         end case;

         exit when Input.Status /= Ok;
      end loop;
   end Load_Global;

   ------------------------
   -- Load_User_Waveform --
   ------------------------

   procedure Load_User_Waveform (Input : in out File_In.Instance) is
      function To_S16 is new Ada.Unchecked_Conversion (Tresses.U16,
                                                       Tresses.S16);

      Raw : In_UInt;
   begin
      for Frame of WNM.Synth.User_Waveform loop
         Input.Read (Raw);

         if Raw > In_UInt (Tresses.U16'Last) then
            Input.Set_Format_Error;
         else
            Frame := To_S16 (Tresses.U16 (Raw));
         end if;

         exit when Input.Status /= Ok;
      end loop;

      Input.Read (Raw);
      if Raw /= End_Of_Section_Value then
         Input.Set_Format_Error;
      end if;
   end Load_User_Waveform;

   ----------------
   -- Load_Mixer --
   ----------------

   procedure Load_Mixer (Input : in out File_In.Instance) is
      procedure To_Mixer_Settings
      is new Convert_To_Enum (Project_Mixer_Settings);

      procedure Read is new File_In.Read_Gen_Int (Audio_Volume);

      Set : Project_Mixer_Settings;
      Raw : In_UInt;
      Success : Boolean;
   begin

      loop
         Input.Read (Raw);

         exit when Input.Status /= Ok
           or else Raw = End_Of_Section_Value;

         To_Mixer_Settings (Raw, Set, Success);

         exit when not Success;

         Read (Input, G_Project.Gains (Set));

         exit when Input.Status /= Ok;
      end loop;
   end Load_Mixer;

   -------------
   -- Load_FX --
   -------------

   procedure Load_FX (Input : in out File_In.Instance) is
      procedure To_FX_Settings is new Convert_To_Enum (Project.FX_Settings);

      Set : Project.FX_Settings;
      Raw : In_UInt;
      Success : Boolean;
   begin
      loop
         Input.Read (Raw);

         exit when Input.Status /= Ok
           or else Raw = End_Of_Section_Value;

         To_FX_Settings (Raw, Set, Success);

         exit when not Success;

         case Set is
            when Auto_Fill_Tracks_Select =>
               for Elt of G_Project.FX.Auto_Fill_Tracks loop
                  Read (Input, Elt);
                  exit when Input.Status /= Ok;
               end loop;
            when Auto_Fill_Low_Proba =>
               Read (Input, G_Project.FX.Auto_Fill_Low_Proba);
            when Auto_Fill_High_Proba =>
               Read (Input, G_Project.FX.Auto_Fill_High_Proba);
            when Auto_Fill_Build_Proba =>
               Read (Input, G_Project.FX.Auto_Fill_Build_Up_Start_Proba);

            when Stutter_Pattern_A =>
               for Elt of G_Project.FX.Pattern_A loop
                  Read (Input, Elt);
                  exit when Input.Status /= Ok;
               end loop;
            when Stutter_Pattern_B =>
               for Elt of G_Project.FX.Pattern_B loop
                  Read (Input, Elt);
                  exit when Input.Status /= Ok;
               end loop;

            when Stutter_Attack =>
               Read (Input, G_Project.FX.Stutter_Atk);
            when Stutter_Release =>
               Read (Input, G_Project.FX.Stutter_Rel);

            when Filter_LP_Cutoff =>
               Read (Input, G_Project.FX.LP_Cutoff);
            when Filter_BP_Cutoff =>
               Read (Input, G_Project.FX.BP_Cutoff);
            when Filter_HP_Cutoff =>
               Read (Input, G_Project.FX.HP_Cutoff);

            when Filter_LP_Reso =>
               Read (Input, G_Project.FX.LP_Reso);
            when Filter_BP_Reso =>
               Read (Input, G_Project.FX.BP_Reso);
            when Filter_HP_Reso =>
               Read (Input, G_Project.FX.HP_Reso);

            when Filter_Sweep_Rate =>
               Read (Input, G_Project.FX.Sweep_Rate);
            when Filter_Sweep_Amp =>
               Read (Input, G_Project.FX.Sweep_Amp);

            when Alt_Slider_Track =>
               Read (Input, G_Project.FX.Alt_Slider_Track);
            when Alt_Slider_Ctrl =>
               Read (Input, G_Project.FX.Alt_Slider_Target);
         end case;

         exit when Input.Status /= Ok;
      end loop;
   end Load_FX;

   ------------------------
   -- Load_Looper_Track  --
   ------------------------

   procedure Load_Looper_Track (Input : in out File_In.Instance;
                                Track : WNM.Looper.Loop_Track)
   is
      procedure To_LT_Settings is new Convert_To_Enum (Looper_Track_Settings);
      procedure Read is new File_In.Read_Gen_Enum (WNM.Looper.Quantize_Kind);
      procedure Read is new File_In.Read_Gen_Int (WNM.Looper.Bar_Count);

      Set : Looper_Track_Settings;
      Raw : In_UInt;
      Success : Boolean;

      Length_Us, Stored_Length_Us, Start_Offset_Us : HAL.UInt32 := 0;
      Generation : HAL.UInt16 := 0;
      Muted, Solo, Hidden : Boolean := False;
      Bars  : WNM.Looper.Bar_Count     := WNM.Looper.Bar_Count'First;
      Quant : WNM.Looper.Quantize_Kind := WNM.Looper.Off;
   begin
      loop
         Input.Read (Raw);

         exit when Input.Status /= Ok
           or else Raw = End_Of_Section_Value;

         To_LT_Settings (Raw, Set, Success);

         exit when not Success;

         case Set is
            when LT_Length_Us =>
               declare
                  V : In_UInt;
               begin
                  Input.Read (V);
                  Length_Us := HAL.UInt32 (V);
               end;
            when LT_Stored_Length_Us =>
               declare
                  V : In_UInt;
               begin
                  Input.Read (V);
                  Stored_Length_Us := HAL.UInt32 (V);
               end;
            when LT_Start_Offset_Us =>
               declare
                  V : In_UInt;
               begin
                  Input.Read (V);
                  Start_Offset_Us := HAL.UInt32 (V);
               end;
            when LT_Generation =>
               declare
                  V : In_UInt;
               begin
                  Input.Read (V);
                  Generation := HAL.UInt16 (V);
               end;
            when LT_Muted => Read (Input, Muted);
            when LT_Solo  => Read (Input, Solo);
            when LT_Hidden => Read (Input, Hidden);
            when LT_Bars => Read (Input, Bars);
            when LT_Quant => Read (Input, Quant);

            when LT_Event_Count =>
               declare
                  Count : In_UInt;
               begin
                  Input.Read (Count);
                  exit when Input.Status /= Ok;

                  for I in 1 .. Count loop
                     declare
                        At_Us : In_UInt;
                        Status, Data_1, Data_2 : In_UInt;
                        Dummy : Boolean;
                     begin
                        Input.Read (At_Us);
                        Input.Read (Status);
                        Input.Read (Data_1);
                        Input.Read (Data_2);
                        exit when Input.Status /= Ok;

                        Dummy := WNM.Looper.Restore_Event
                          (Track, HAL.UInt32 (At_Us),
                           (Status => HAL.UInt8 (Status),
                            Data_1 => HAL.UInt8 (Data_1),
                            Data_2 => HAL.UInt8 (Data_2)));
                     end;
                  end loop;
               end;
         end case;

         exit when Input.Status /= Ok;
      end loop;

      WNM.Looper.Set_Restored_Track_State
        (Track, Length_Us, Stored_Length_Us, Generation,
         Muted, Solo, Hidden, Start_Offset_Us);
      --  Bars and Quant are the Looper tab's own UI settings, not part of
      --  Set_Restored_Track_State's reference-engine-shaped signature, so
      --  they are set separately.
      WNM.Looper.Set_Bars (Track, Bars, 0, null);
      WNM.Looper.Set_Quantize (Track, Quant);
   end Load_Looper_Track;

   --------------------
   -- Load_Looper    --
   --------------------

   procedure Load_Looper (Input : in out File_In.Instance) is
      Token : Token_Kind;
      Auto_Raw : In_UInt;
   begin
      WNM.Looper.Reset;

      --  The shared AUT setting, a single raw value right after the
      --  section token, not wrapped in a settings ID the way the
      --  per-track fields are: there is only ever the one.
      Input.Read (Auto_Raw);
      if Input.Status = Ok
        and then Auto_Raw <=
          In_UInt (WNM.Looper.Auto_Kind'Pos (WNM.Looper.Auto_Kind'Last))
      then
         WNM.Looper.Set_Auto_Setting
           (WNM.Looper.Auto_Kind'Val (Natural (Auto_Raw)));
      end if;

      loop
         Input.Read (Token);

         exit when Input.Status /= Ok or else Token = End_Of_Section;

         if Token = Looper_Track then
            declare
               Track_Raw : In_UInt;
            begin
               Input.Read (Track_Raw);
               exit when Input.Status /= Ok;

               if Track_Raw in
                 In_UInt (WNM.Looper.Loop_Track'First) ..
                   In_UInt (WNM.Looper.Loop_Track'Last)
               then
                  Load_Looper_Track
                    (Input, WNM.Looper.Loop_Track (Track_Raw));
               else
                  Input.Set_Format_Error;
               end if;
            end;
         else
            Input.Set_Format_Error;
         end if;

         exit when Input.Status /= Ok;
      end loop;
   end Load_Looper;

   ----------
   -- Load --
   ----------

   function Load (Filename :     String;
                  Size     : out File_System.File_Signed_Size)
                  return File_System.Storage_Error
   is
      Input : File_In.Instance;
      Token : Token_Kind;

      Version : In_UInt;

      Saw_Looper_Section : Boolean := False;
      --  Load_Looper resets the loop engine itself, but only runs if the
      --  file actually has that section. A file that says Four_Track_Looper
      --  in its Global section and then has no Looper section (truncated,
      --  hand-made, or written by a build from before that section
      --  existed) would otherwise leave the engine pointed at whatever
      --  Clear_Sequences just wrote, which is valid step data read as loop
      --  state: garbage lengths, garbage slot links, a crash waiting for
      --  the first tick. Checked after the loop below instead.
   begin
      Input.Open (Filename);
      Size := 0;

      --  The first data in a project file is a version number for the format.
      --  Right now it should always be 1 and we don't use this information.
      Input.Read (Version);

      --  Set default gains in case there is no mixer section saved
      G_Project.Gains := Default_Gains;

      --  An absent mode token has to mean OG Sequencer, which is what
      --  every file written before that token existed is. Without this the
      --  mode carries over from whatever was loaded before: opening an OG
      --  project straight after a Looper one would leave the mode saying
      --  Looper while Steps holds real step data, and the loop engine
      --  would then reset the overlay and take the sequence with it.
      Set_Sequencer_Mode (OG_Sequencer);

      --  Likewise for Steps/Patterns: a Four_Track_Looper project has no
      --  Pattern or Sequence section at all (see the Save guard above), so
      --  without this whatever a previously loaded project left behind,
      --  step data or raw loop event bytes, would carry over unchanged.
      Clear_Sequences;

      loop

         Input.Read (Token);

         exit when Input.Status /= Ok;

         case Token is
            when Global_Section =>
               Load_Global (Input);

            when Track_Section =>
               Load_Track (Input);

            when Pattern_Section =>
               Load_Pattern (Input);

            when Part_Section =>
               Load_Part (Input);

            when Chord_Progression_Section =>
               Load_Progression (Input);

            when Sequence_Section =>
               Load_Sequences (Input);

            when User_Waveform =>
               Load_User_Waveform (Input);

            when Mixer =>
               Load_Mixer (Input);

            when FX_Settings =>
               Load_FX (Input);

            when Looper_Section =>
               Load_Looper (Input);
               Saw_Looper_Section := True;

            when End_Of_File =>
               exit;

            when others =>
               Input.Set_Format_Error;
               exit;
         end case;

         exit when Input.Status /= Ok;

      end loop;

      if Sequencer_Mode = Four_Track_Looper
        and then not Saw_Looper_Section
      then
         --  See Saw_Looper_Section above: the mode says the loop engine
         --  owns the Steps storage, but nothing in the file ever
         --  initialised it, so do it here rather than let the first tick
         --  read step data as loop state.
         WNM.Looper.Reset;
      end if;

      Size := WNM.File_System.Size;

      File_System.Close;

      --  Signal project load
      WNM.Project_Load_Broadcast.Broadcast;

      return Input.Status;
   end Load;

end WNM.Project.Storage;

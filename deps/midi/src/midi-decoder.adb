with Ada.Unchecked_Conversion;

with HAL; use HAL;

package body MIDI.Decoder is

   ----------
   -- Push --
   ----------

   procedure Push (This : in out Instance; Byte : HAL.UInt8) is

      function Is_Status return Boolean
      is ((Byte and 2#1000_0000#) /= 0);

      ---------------
      -- Msg_Ready --
      ---------------

      procedure Msg_Ready is
         function To_MIDI_Message
         is new Ada.Unchecked_Conversion (MIDI_Data_Array,
                                          Message);
      begin
         Message_Decoded (To_MIDI_Message (This.Data));
         This.Data := (others => 0);
      end Msg_Ready;

      ---------------
      -- Start_Msg --
      ---------------

      procedure Start_Msg (Expected_Len : Positive) is
      begin
         This.Data (1) := Byte;
         This.Index := 2;

         if Expected_Len /= 1 then
            This.Count := Expected_Len - 1;
            This.Expect_Data := True;
         else
            Msg_Ready;
         end if;
      end Start_Msg;

      Cmd : constant UInt4 := UInt4 (Shift_Right (Byte, 4) and 2#1111#);
      Sub : constant UInt4 := UInt4 (Byte and 2#1111#);
   begin

      if This.Expect_Data then

         if Is_Status or else This.Count = 0 then
            --  There is an issue with the current message, ignore it
            This.Expect_Data := False;

            --  Fallback to status byte processing below
         else

            --  Save incomming data byte
            This.Data (This.Index) := Byte;
            This.Count := This.Count - 1;
            This.Index := This.Index + 1;

            --  Check if we have a complete message
            if This.Count = 0 then
               Msg_Ready;
               This.Expect_Data := False;
            end if;

            --  Data handled, we can return
            return;
         end if;
      end if;

      if Is_Status then
         case Cmd is
            when Note_Off'Enum_Rep | Note_On'Enum_Rep |
                 Aftertouch'Enum_Rep | Continous_Controller'Enum_Rep =>
               --  Channel message with two data bytes
               Start_Msg (Expected_Len => 3);

            when Patch_Change'Enum_Rep | Channel_Pressure'Enum_Rep =>
               --  Channel message with one data byte
               Start_Msg (Expected_Len => 2);

            when Pitch_Bend'Enum_Rep =>
               --  Channel message with two data bytes, LSB then MSB.
               --  This was previously decoded as one, which kept the LSB
               --  and dropped the MSB, so the actual bend value never
               --  reached the application.
               Start_Msg (Expected_Len => 3);

            when Sys'Enum_Rep => --  System messages
               case MIDI_Channel (Sub) is
                  when Exclusive'Enum_Rep | End_Exclusive'Enum_Rep =>
                     --  Ignore SysEx start and stop, we do not support those
                     --  messages.
                     null;

                  when Song_Position'Enum_Rep =>
                     --  Sys message with two data bytes
                     Start_Msg (Expected_Len => 3);

                  when Song_Select'Enum_Rep | Bus_Select'Enum_Rep =>
                     --  Sys message with one data byte
                     Start_Msg (Expected_Len => 2);

                  when Tune_Request'Enum_Rep | Timming_Tick'Enum_Rep |
                       Start_Song'Enum_Rep | Continue_Song'Enum_Rep |
                             Stop_Song'Enum_Rep | Active_Sensing'Enum_Rep |
                       Reset'Enum_Rep =>
                     --  Sys message without data byte
                     Start_Msg (Expected_Len => 1);

                  when others =>
                     --  Unknown/unsupported sys message
                     null;
               end case;

            when others =>
               --  Unknown/unsupported message
               null;
         end case;

      else
         --  Unexpected data byte
         null;
      end if;
   end Push;

end MIDI.Decoder;

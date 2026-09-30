with HAL;

package MIDI.Decoder is

   type Instance
   is tagged limited
   private;

   generic
      with procedure Message_Decoded (Msg : Message);
   procedure Push (This : in out Instance; Byte : HAL.UInt8);
   --  Instantiate this procedure with a sub-program to handle decoded
   --  messages. Then use it to push incomming MIDI bytes into the decoder.
   --
   --  When a full MIDI message is recieved, the Message_Decoded sub-program is
   --  called.

private

   type MIDI_Data_Array is new HAL.UInt8_Array (1 .. Message'Object_Size / 8);

   type Instance
   is tagged limited
           record
              Expect_Data : Boolean := False;
              Count : Natural := 0;
              Data  : MIDI_Data_Array := (others => 0);
              Index : Positive := 1;
           end record;

end MIDI.Decoder;

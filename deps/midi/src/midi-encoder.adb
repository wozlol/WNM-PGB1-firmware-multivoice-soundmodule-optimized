package body MIDI.Encoder is

   ------------
   -- Encode --
   ------------

   function Encode (Msg : Message) return HAL.UInt8_Array is
      Result : HAL.UInt8_Array (1 .. Rep_Size (Msg))
        with Address => Msg'Address;
   begin
      return Result;
   end Encode;

   ------------
   -- Encode --
   ------------

   function Encode (Msg : Message) return System.Storage_Elements.Storage_Array
   is
      use System.Storage_Elements;
      Result : Storage_Array  (1 .. Storage_Offset (Rep_Size (Msg)))
        with Address => Msg'Address;
   begin
      return Result;
   end Encode;

end MIDI.Encoder;

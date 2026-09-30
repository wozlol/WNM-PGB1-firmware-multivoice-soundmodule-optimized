with HAL;
with System.Storage_Elements;

package MIDI.Encoder is

   function Encode (Msg : Message) return HAL.UInt8_Array;
   --  Return the encoded MIDI message in an array

   function Encode (Msg : Message)
                    return System.Storage_Elements.Storage_Array;
   --  Return the encoded MIDI message in an array

end MIDI.Encoder;

with BBqueue;

package MIDI.Decoder.Queue is

   type Instance (Capacity : BBqueue.Count)
   is tagged limited
   private;

   procedure Push (This : in out Instance; Byte : HAL.UInt8);

   procedure Pop (This    : in out Instance;
                  Msg     :    out Message;
                  Success :    out Boolean);

   generic
      with procedure Message_Decoded (Msg : Message);
   procedure Flush (This : in out Instance);

private

   type Message_Array is array (BBqueue.Count range <>) of Message;

   type Instance (Capacity : BBqueue.Count)
   is tagged limited
           record
              Dec      : Decoder.Instance;
              Messages : Message_Array (1 .. Capacity);
              Queue    : BBqueue.Offsets_Only (Capacity);
           end record;

end MIDI.Decoder.Queue;

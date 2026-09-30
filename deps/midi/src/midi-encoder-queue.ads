with BBqueue.Buffers;

package MIDI.Encoder.Queue is

   type Instance (Capacity : BBqueue.Buffer_Size)
   is tagged limited
   private;

   procedure Push (This : in out Instance; Msg : Message);

   procedure Read (This : in out Instance;
                   G    : in out BBqueue.Buffers.Read_Grant);

   procedure Release (This : in out Instance;
                      G    : in out BBqueue.Buffers.Read_Grant);

private

   type Instance (Capacity : BBqueue.Buffer_Size)
   is tagged limited record
      Queue : BBqueue.Buffers.Buffer (Capacity);
   end record;

end MIDI.Encoder.Queue;

with BBqueue.Buffers; use BBqueue.Buffers;

package body MIDI.Encoder.Queue is

   ----------
   -- Push --
   ----------

   procedure Push (This : in out Instance; Msg : Message) is
      use type BBqueue.Result_Kind;

      Size : constant Natural := Rep_Size (Msg);
      WG : Write_Grant;
   begin

      Grant (This.Queue, WG, BBqueue.Count (Size));

      if State (WG) = BBqueue.Valid then

         declare
            Dst : HAL.UInt8_Array (1 .. Size)
              with Address => Slice (WG).Addr;

            Src : HAL.UInt8_Array (1 .. Size)
              with Address => Msg'Address;
         begin
            Dst := Src;
         end;

         Commit (This.Queue, WG);
      end if;
   end Push;

   ----------
   -- Read --
   ----------

   procedure Read (This : in out Instance;
                   G    : in out BBqueue.Buffers.Read_Grant)
   is
   begin
      Read (This.Queue, G);
   end Read;

   -------------
   -- Release --
   -------------

   procedure Release (This : in out Instance;
                      G    : in out BBqueue.Buffers.Read_Grant)
   is
   begin
      Release (This.Queue, G);
   end Release;

end MIDI.Encoder.Queue;

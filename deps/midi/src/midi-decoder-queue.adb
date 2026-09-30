with System.Storage_Elements; use System.Storage_Elements;

with BBqueue; use BBqueue;

package body MIDI.Decoder.Queue is

   ----------
   -- Push --
   ----------

   procedure Push (This : in out Instance; Byte : HAL.UInt8) is

      ------------------
      -- Add_To_Queue --
      ------------------

      procedure Add_To_Queue (Msg : Message) is

         WG : Write_Grant;
      begin
         Grant (This.Queue, WG, Size => 1);

         if State (WG) = Valid then
            This.Messages (This.Messages'First + Slice (WG).From) := Msg;
            Commit (This.Queue, WG);
         end if;
      end Add_To_Queue;

      procedure Dec_Push is new MIDI.Decoder.Push (Add_To_Queue);

   begin
      Dec_Push (This.Dec, Byte);
   end Push;

   ---------
   -- Pop --
   ---------

   procedure Pop (This    : in out Instance;
                  Msg     :    out Message;
                  Success :    out Boolean)
   is
      RG : Read_Grant;
   begin

      Read (This.Queue, RG, 1);

      if State (RG) = Valid then

         Msg := This.Messages (This.Messages'First + Slice (RG).From);
         Success := True;
         Release (This.Queue, RG);
      else
         Success := False;
      end if;

   end Pop;

   -----------
   -- Flush --
   -----------

   procedure Flush (This : in out Instance) is
      RG : Read_Grant;
   begin

      loop

         Read (This.Queue, RG);

         exit when State (RG) /= Valid;

         declare
            First : constant Count := This.Messages'First + Slice (RG).From;
            Last  : constant Count := This.Messages'First + Slice (RG).To;
         begin
            for Elt of This.Messages (First .. Last) loop
               Message_Decoded (Elt);
            end loop;
         end;

         Release (This.Queue, RG);

      end loop;

   end Flush;

end MIDI.Decoder.Queue;

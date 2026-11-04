with Ada.IO_Exceptions;

package body Epub.Buffered_Streams is
   use Ada.Streams;
   use type Zip_Streams.ZS_Size_Type;

   procedure Check_Target (Item : Writer) is
   begin
      if Item.Failed then
         raise Ada.IO_Exceptions.Use_Error with "Buffered output has a failed target write";
      elsif Item.Target.all.Index /= Item.Expected_Index or else
        Item.Target.all.Size /= Item.Expected_Index - 1
      then
         raise Ada.IO_Exceptions.Mode_Error with "Buffered output requires exclusive append-only access";
      end if;
   end Check_Target;

   procedure Flush (Item : in out Writer) is
   begin
      Check_Target (Item);
      if Item.Used > 0 then
         Item.Failed := True;
         Item.Target.all.Write (Item.Buffer (1 .. Item.Used));
         Item.Expected_Index := Item.Expected_Index + Zip_Streams.ZS_Size_Type (Item.Used);
         Item.Used := 0;
         Item.Failed := False;
      end if;
   end Flush;

   overriding procedure Write (Item : in out Writer; Buffer : Stream_Element_Array) is
      Cursor : Stream_Element_Offset := Buffer'First;
   begin
      Check_Target (Item);
      if Buffer'Length > Zip_Streams.ZS_Size_Type'Last - Item.Index then
         raise Ada.IO_Exceptions.Use_Error with "Buffered output index overflow";
      end if;
      while Cursor <= Buffer'Last loop
         declare
            Remaining : constant Stream_Element_Offset := Buffer'Last - Cursor + 1;
            Chunk : constant Stream_Element_Offset :=
              Stream_Element_Offset'Min (Remaining, Item.Capacity - Item.Used);
         begin
            if Item.Used = 0 and then Remaining >= Item.Capacity then
               --  Large existing buffers need neither another copy nor
               --  splitting: the target already supports bulk writes.
               Item.Failed := True;
               Item.Target.all.Write (Buffer (Cursor .. Buffer'Last));
               Item.Expected_Index := Item.Expected_Index + Zip_Streams.ZS_Size_Type (Remaining);
               Item.Failed := False;
               return;
            end if;
            Item.Buffer (Item.Used + 1 .. Item.Used + Chunk) := Buffer (Cursor .. Cursor + Chunk - 1);
            Item.Used := Item.Used + Chunk;
            if Item.Used = Item.Capacity then
               Item.Flush;
            end if;
            exit when Chunk = Remaining;
            Cursor := Cursor + Chunk;
         end;
      end loop;
   end Write;

   overriding procedure Read
     (Item : in out Writer; Buffer : out Stream_Element_Array; Last : out Stream_Element_Offset) is
      pragma Unreferenced (Item, Buffer, Last);
   begin
      raise Ada.IO_Exceptions.Mode_Error with "Buffered output cannot be read";
   end Read;

   overriding procedure Set_Index (Item : in out Writer; To : Zip_Streams.ZS_Index_Type) is
   begin
      Check_Target (Item);
      if To /= Item.Index then
         raise Ada.IO_Exceptions.Mode_Error with "Buffered output cannot seek";
      end if;
   end Set_Index;
   overriding function Index (Item : Writer) return Zip_Streams.ZS_Index_Type is
     (Item.Expected_Index + Zip_Streams.ZS_Size_Type (Item.Used));
   overriding function Size (Item : Writer) return Zip_Streams.ZS_Size_Type is (Item.Index - 1);
   overriding function End_Of_Stream (Item : Writer) return Boolean is (Item.Index > Item.Size);
end Epub.Buffered_Streams;

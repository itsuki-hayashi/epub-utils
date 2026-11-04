with Ada.IO_Exceptions;

package body Epub.Hash_Streams is
   use type Zip_Streams.ZS_Size_Type;
   overriding procedure Read
     (Item : in out Stream; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset) is
      pragma Unreferenced (Item, Buffer, Last);
   begin
      raise Ada.IO_Exceptions.Mode_Error with "Hash output stream cannot be read";
   end Read;
   overriding procedure Write (Item : in out Stream; Buffer : Ada.Streams.Stream_Element_Array) is
   begin
      if Item.Target.all.Index /= Item.Target.all.Size + 1 then
         raise Ada.IO_Exceptions.Mode_Error with "Hash output stream requires append-only writes";
      end if;
      Item.Target.all.Write (Buffer);
      Epub.Digests.Update (Item.Hash, Buffer);
   end Write;
   overriding procedure Set_Index (Item : in out Stream; To : Zip_Streams.ZS_Index_Type) is
   begin
      if To /= Item.Target.all.Index then
         raise Ada.IO_Exceptions.Mode_Error with "Hash output stream cannot seek";
      end if;
   end Set_Index;
   overriding function Index (Item : Stream) return Zip_Streams.ZS_Index_Type is (Item.Target.all.Index);
   overriding function Size (Item : Stream) return Zip_Streams.ZS_Size_Type is (Item.Target.all.Size);
   overriding function End_Of_Stream (Item : Stream) return Boolean is (Item.Target.all.End_Of_Stream);
   function Digest (Item : Stream) return String is
     (Epub.Digests.Digest (Item.Hash));
end Epub.Hash_Streams;

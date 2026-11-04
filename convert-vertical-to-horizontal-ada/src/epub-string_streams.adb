with Ada.IO_Exceptions;

package body Epub.String_Streams is
   use Ada.Streams;
   use type Zip_Streams.ZS_Size_Type;
   overriding procedure Read
     (Item : in out Reader; Buffer : out Stream_Element_Array; Last : out Stream_Element_Offset) is
      Count : Natural := 0;
   begin
      pragma Compile_Time_Error (Character'Size /= Stream_Element'Size, "Byte views require matching octets");
      Last := Buffer'First - 1;
      if Item.Position <= Item.Data.all'Length then
         Count := Natural (Stream_Element_Offset'Min (Buffer'Length,
           Stream_Element_Offset (Item.Data.all'Length) - Stream_Element_Offset (Item.Position) + 1));
      end if;
      if Count > 0 then
         declare
            View : String (1 .. Count) with Import, Address => Buffer (Buffer'First)'Address;
            First : constant Positive := Item.Data.all'First + (Natural (Item.Position) - 1);
         begin
            View := Item.Data.all (First .. First + (Count - 1));
         end;
         Last := Buffer'First + Stream_Element_Offset (Count - 1);
         Item.Position := Item.Position + Zip_Streams.ZS_Size_Type (Count);
      end if;
   end Read;
   overriding procedure Write (Item : in out Reader; Buffer : Stream_Element_Array) is
      pragma Unreferenced (Item, Buffer);
   begin
      raise Ada.IO_Exceptions.Mode_Error with "Read-only byte stream cannot be written";
   end Write;
   overriding procedure Set_Index (Item : in out Reader; To : Zip_Streams.ZS_Index_Type) is
   begin
      if To > Item.Size + 1 then
         raise Ada.IO_Exceptions.Use_Error with "Read-only byte stream index exceeds its bounds";
      end if;
      Item.Position := To;
   end Set_Index;
   overriding function Index (Item : Reader) return Zip_Streams.ZS_Index_Type is (Item.Position);
   overriding function Size (Item : Reader) return Zip_Streams.ZS_Size_Type is (Item.Data.all'Length);
   overriding function End_Of_Stream (Item : Reader) return Boolean is (Item.Position > Item.Size);
end Epub.String_Streams;

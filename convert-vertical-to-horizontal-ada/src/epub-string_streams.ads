with Ada.Streams;
with Zip_Streams;

package Epub.String_Streams is
   --  The access discriminant ties the stream to its byte string's lifetime.
   --  Production callers use aliased constants; no copied buffer or heap owner
   --  is needed for a read-only, bounded bulk view.
   type Reader (Data : not null access constant String) is
     new Zip_Streams.Root_Zipstream_Type with private;
   overriding procedure Read
     (Item : in out Reader; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);
   overriding procedure Write (Item : in out Reader; Buffer : Ada.Streams.Stream_Element_Array);
   overriding procedure Set_Index (Item : in out Reader; To : Zip_Streams.ZS_Index_Type);
   overriding function Index (Item : Reader) return Zip_Streams.ZS_Index_Type;
   overriding function Size (Item : Reader) return Zip_Streams.ZS_Size_Type;
   overriding function End_Of_Stream (Item : Reader) return Boolean;
private
   type Reader (Data : not null access constant String) is
     new Zip_Streams.Root_Zipstream_Type with record
      Position : Zip_Streams.ZS_Index_Type := 1;
   end record;
end Epub.String_Streams;

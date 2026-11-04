with Ada.Streams;
with Zip_Streams;

package Epub.Buffered_Streams is
   subtype Capacity_Type is Ada.Streams.Stream_Element_Offset range 1 .. 1_048_576;
   --  Borrow an append-only target and combine small writes in bounded RAM.
   --  Flush is explicit: callers must finish it successfully before using the
   --  target's digest, flushing its file handle, or starting verification.
   --  A failed target write poisons the proxy; retrying could duplicate bytes.
   type Writer
     (Target : not null access Zip_Streams.Root_Zipstream_Type'Class;
      Capacity : Capacity_Type) is new Zip_Streams.Root_Zipstream_Type with private;
   procedure Flush (Item : in out Writer);
   overriding procedure Read
     (Item : in out Writer; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);
   overriding procedure Write (Item : in out Writer; Buffer : Ada.Streams.Stream_Element_Array);
   overriding procedure Set_Index (Item : in out Writer; To : Zip_Streams.ZS_Index_Type);
   overriding function Index (Item : Writer) return Zip_Streams.ZS_Index_Type;
   overriding function Size (Item : Writer) return Zip_Streams.ZS_Size_Type;
   overriding function End_Of_Stream (Item : Writer) return Boolean;
private
   type Writer
     (Target : not null access Zip_Streams.Root_Zipstream_Type'Class;
      Capacity : Capacity_Type) is new Zip_Streams.Root_Zipstream_Type with record
      Used : Ada.Streams.Stream_Element_Offset := 0;
      Expected_Index : Zip_Streams.ZS_Index_Type := Target.all.Index;
      Failed : Boolean := False;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. Capacity);
   end record;
end Epub.Buffered_Streams;

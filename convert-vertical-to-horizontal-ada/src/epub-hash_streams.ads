with Ada.Streams;
with Epub.Digests;
with Zip_Streams;

package Epub.Hash_Streams is
   --  Append-only proxy: hash precisely the intended writes before the saved
   --  file is independently reopened and checked. Rewriting would invalidate
   --  an incremental digest and is explicitly rejected.
   type Stream (Target : not null access Zip_Streams.Root_Zipstream_Type'Class) is
     new Zip_Streams.Root_Zipstream_Type with private;
   function Digest (Item : Stream) return String;
   overriding procedure Read
     (Item : in out Stream; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);
   overriding procedure Write (Item : in out Stream; Buffer : Ada.Streams.Stream_Element_Array);
   overriding procedure Set_Index (Item : in out Stream; To : Zip_Streams.ZS_Index_Type);
   overriding function Index (Item : Stream) return Zip_Streams.ZS_Index_Type;
   overriding function Size (Item : Stream) return Zip_Streams.ZS_Size_Type;
   overriding function End_Of_Stream (Item : Stream) return Boolean;
private
   type Stream (Target : not null access Zip_Streams.Root_Zipstream_Type'Class) is
     new Zip_Streams.Root_Zipstream_Type with record
      Hash : Epub.Digests.Context := Epub.Digests.Initial_Context;
   end record;
end Epub.Hash_Streams;

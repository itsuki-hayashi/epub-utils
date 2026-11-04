with Ada.Finalization;
with Epub.File_Streams;
with Interfaces;
with Zip.Headers;
with Zip_Streams;
with Ada.Streams;
with Epub.Synchronization;

--  References share ownership of the original open file. Bounded readers own
--  references and private cursors; only the underlying seek/read is serialized.
package Epub.Archive_Sources is
   type Reference is new Ada.Finalization.Controlled with private;
   function Open (Path : String) return Reference;
   function Is_Open (Item : Reference) return Boolean;
   --  Used after all borrowed views have drained, notably before publishing a
   --  persisted temporary file. A close failure remains a checked operation.
   procedure Close_Checked (Item : in out Reference);
   function Size (Item : Reference) return Interfaces.Unsigned_64;
   type Reader is new Zip_Streams.Root_Zipstream_Type with private;
   function View (Item : Reference'Class; Offset : Zip_Streams.ZS_Index_Type;
                  Count : Interfaces.Unsigned_64) return Reader;
   overriding procedure Read
     (Item : in out Reader; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);
   overriding procedure Write (Item : in out Reader; Buffer : Ada.Streams.Stream_Element_Array);
   overriding procedure Set_Index (Item : in out Reader; To : Zip_Streams.ZS_Index_Type);
   overriding function Index (Item : Reader) return Zip_Streams.ZS_Index_Type;
   overriding function Size (Item : Reader) return Zip_Streams.ZS_Size_Type;
   overriding function End_Of_Stream (Item : Reader) return Boolean;
   function Digest (Item : Reference) return String;
   procedure Copy (Item : Reference; Output : in out Zip_Streams.Root_Zipstream_Type'Class);
   procedure Copy_Range
     (Item : Reference; Offset : Zip_Streams.ZS_Index_Type; Count : Interfaces.Unsigned_64;
      Output : in out Zip_Streams.Root_Zipstream_Type'Class);
   function Decode
     (Item : Reference; Offset : Zip_Streams.ZS_Index_Type;
      Metadata : Zip.Headers.Local_File_Header) return String;
   generic
      with procedure Action (Stream : in out Zip_Streams.Root_Zipstream_Type'Class);
   procedure Inspect (Item : Reference);
private
   protected type Ownership is
      procedure Retain;
      procedure Release (Last : out Boolean);
      function Unique return Boolean;
   private
      Count : Natural := 1;
   end Ownership;
   type Context is limited record
      Stream : Epub.File_Streams.Stream;
      Owners : Ownership;
      IO_Lock : aliased Epub.Synchronization.Mutex;
      Length : Interfaces.Unsigned_64 := 0;
   end record;
   type Context_Access is access Context;
   type Reference is new Ada.Finalization.Controlled with record
      Data : Context_Access;
   end record;
   overriding procedure Adjust (Item : in out Reference);
   overriding procedure Finalize (Item : in out Reference);
   type Reader is new Zip_Streams.Root_Zipstream_Type with record
      Owner : Reference;
      First : Zip_Streams.ZS_Index_Type := 1;
      Length : Zip_Streams.ZS_Size_Type := 0;
      Position : Zip_Streams.ZS_Index_Type := 1;
   end record;
end Epub.Archive_Sources;

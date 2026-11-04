with Ada.Finalization;
with Epub.File_Streams;
with Interfaces;
with Zip.Headers;
with Zip_Streams;

--  Shared ownership keeps a source handle alive while any catalogue member
--  refers to it. Operations are deliberately single-threaded and seek before
--  each read; no borrowed stream or payload pointer escapes this package.
package Epub.Archive_Sources is
   type Reference is new Ada.Finalization.Controlled with private;
   function Open (Path : String) return Reference;
   function Is_Open (Item : Reference) return Boolean;
   function Size (Item : Reference) return Interfaces.Unsigned_64;
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
   type Context is limited record
      Stream : Epub.File_Streams.Stream;
      Owners : Positive := 1;
   end record;
   type Context_Access is access Context;
   type Reference is new Ada.Finalization.Controlled with record
      Data : Context_Access;
   end record;
   overriding procedure Adjust (Item : in out Reference);
   overriding procedure Finalize (Item : in out Reference);
end Epub.Archive_Sources;

with Ada.Strings.Unbounded;
with Interfaces;
with Zip_Streams;

generic
   with procedure Build
     (Output : in out Zip_Streams.Root_Zipstream_Type'Class;
      Expected_SHA256 : out Ada.Strings.Unbounded.Unbounded_String);
   with procedure Verify (Input : in out Zip_Streams.Root_Zipstream_Type'Class);
procedure Epub.Files.Write_Stream_Checked
  (Destination : String; Output_Bytes : out Interfaces.Unsigned_64;
   Output_SHA256 : out Ada.Strings.Unbounded.Unbounded_String);

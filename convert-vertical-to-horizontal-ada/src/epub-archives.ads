with Ada.Strings.Unbounded;
with Interfaces;
with Zip.Headers;
with Zip_Streams;
with Epub.Lists;
with Epub.Archive_Sources;

package Epub.Archives is
   type Member is record
      Name, Raw_Name, Payload : Ada.Strings.Unbounded.Unbounded_String;
      Header : Zip.Headers.Central_File_Header :=
        (made_by_version => 20,
         short_info =>
           (needed_extract_version => 20, bit_flag => 0, zip_type => 0,
            file_timedate => Zip_Streams.default_time,
            dd => (crc_32 => 0, compressed_size => 0, uncompressed_size => 0),
            filename_length => 0, extra_field_length => 0),
         comment_length => 0, disk_number_start => 0,
         internal_attributes => 0, external_attributes => 0, local_header_offset => 0);
      Was_Zip64 : Boolean := False;
      Source : Epub.Archive_Sources.Reference;
      Payload_Offset : Zip_Streams.ZS_Index_Type := 1;
      Payload_Loaded : Boolean := True;
      Payload_SHA256 : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   package Member_Lists is new Epub.Lists (Member);
   subtype Catalogue is Member_Lists.Vector;
   function Read (Bytes : String) return Catalogue;
   function Read_File (Path : String) return Catalogue;
   function Source_Size (Items : Catalogue) return Interfaces.Unsigned_64;
   function Source_Digest (Items : Catalogue) return String;
   procedure Copy_Source (Items : Catalogue; Output : in out Zip_Streams.Root_Zipstream_Type'Class);
   function Rebuild (Items : Catalogue) return String;
   procedure Rebuild (Items : Catalogue; Output : in out Zip_Streams.Root_Zipstream_Type'Class);
   procedure Verify (Bytes : String; Expected : Catalogue);
   procedure Verify
     (Stream : in out Zip_Streams.Root_Zipstream_Type'Class; Expected : Catalogue);
   function Find (Items : Catalogue; Name : String) return Natural;
   function Contents (Items : Catalogue; Name : String) return String;
   function Create_Member
     (Name, Payload : String; Attributes : Interfaces.Unsigned_32 := 0)
      return Member;
   Invalid_Archive : exception;
end Epub.Archives;

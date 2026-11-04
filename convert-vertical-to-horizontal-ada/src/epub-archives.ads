with Ada.Strings.Unbounded;
with Epub.Name_Indexes;
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
   type Catalogue is tagged private
     with Constant_Indexing => Element,
       Iterable => (First => First, Next => Next, Has_Element => Has_Element, Element => Element);
   function Element (Container : Catalogue; Position : Natural) return Member;
   function First (Container : Catalogue) return Natural;
   function Next (Container : Catalogue; Position : Natural) return Natural;
   function Has_Element (Container : Catalogue; Position : Natural) return Boolean;
   function Is_Empty (Container : Catalogue) return Boolean;
   function Last_Index (Container : Catalogue) return Natural;
   function Last_Element (Container : Catalogue) return Member;
   procedure Append (Container : in out Catalogue; Item : Member);
   procedure Replace_Element
     (Container : in out Catalogue; Position : Positive; Item : Member);
   procedure Delete_Last (Container : in out Catalogue);
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
private
   type Catalogue is tagged record
      Members : Member_Lists.Vector;
      Names : Epub.Name_Indexes.Index;
      Structure_Error_Ordinal : Natural := 0;
      Structure_Error : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   --  Parallel callers validate payloads separately and report a deferred local
   --  metadata failure only after preceding entry validation jobs have drained.
   procedure Read_Structure (Source : Epub.Archive_Sources.Reference; Result : out Catalogue);
   type Prepared_Entry is record
      Value : Member;
      Bytes : Ada.Strings.Unbounded.Unbounded_String;
      Keep_Original : Boolean := False;
   end record;
   type Writer_State is limited record
      Written : Catalogue;
      Force_Zip64 : Boolean := False;
   end record;
   procedure Begin_Rebuild
     (Items : Catalogue; Output : in out Zip_Streams.Root_Zipstream_Type'Class;
      State : out Writer_State);
   function Prepare_Entry (Items : Catalogue; Ordinal : Positive) return Prepared_Entry;
   procedure Append_Entry
     (State : in out Writer_State; Output : in out Zip_Streams.Root_Zipstream_Type'Class;
      Data : Prepared_Entry);
   procedure Finish_Rebuild
     (State : Writer_State; Output : in out Zip_Streams.Root_Zipstream_Type'Class);
end Epub.Archives;

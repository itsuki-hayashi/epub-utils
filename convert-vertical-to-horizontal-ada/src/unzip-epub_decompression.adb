with Ada.Finalization;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces;
with UnZip.Decompress;
with Epub.Inflate;
with Epub.Synchronization;

package body UnZip.Epub_Decompression is
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_16;
   use type Zip.Headers.Data_Descriptor;
   Compatibility_Lock : aliased Epub.Synchronization.Mutex;

   type Output_Stream is new Ada.Streams.Root_Stream_Type with record
      Bytes : Unbounded_String;
      Maximum, Written : Interfaces.Unsigned_64 := 0;
   end record;
   overriding procedure Read
     (Stream : in out Output_Stream; Item : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);
   overriding procedure Write
     (Stream : in out Output_Stream; Item : Ada.Streams.Stream_Element_Array);

   overriding procedure Read
     (Stream : in out Output_Stream; Item : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset) is
      pragma Unreferenced (Stream, Item, Last);
   begin
      raise Program_Error with "Archive decompression sink cannot be read";
   end Read;

   overriding procedure Write
     (Stream : in out Output_Stream; Item : Ada.Streams.Stream_Element_Array) is
   begin
      if Interfaces.Unsigned_64 (Item'Length) > Stream.Maximum - Stream.Written then
         raise Invalid_Payload with "Decompressed payload exceeds its declared size";
      end if;
      declare
         Bytes : String (1 .. Item'Length);
         Cursor : Positive := 1;
      begin
         for Byte of Item loop
            Bytes (Cursor) := Character'Val (Byte);
            Cursor := Cursor + 1;
         end loop;
         Append (Stream.Bytes, Bytes);
      end;
      Stream.Written := Stream.Written + Interfaces.Unsigned_64 (Item'Length);
   end Write;

   type Output_Access is access all Output_Stream;
   procedure Free is new Ada.Unchecked_Deallocation (Output_Stream, Output_Access);
   type Output_Owner is new Ada.Finalization.Limited_Controlled with record
      Sink : Output_Access := new Output_Stream;
   end record;
   overriding procedure Finalize (Owner : in out Output_Owner);
   overriding procedure Finalize (Owner : in out Output_Owner) is
   begin
      Free (Owner.Sink);
   end Finalize;

   function Decode_Compatibility
     (Source_Stream : in out Zip_Streams.Root_Zipstream_Type'Class;
      Metadata : Zip.Headers.Local_File_Header) return String is
      Owner : Output_Owner;
      Hint : Zip.Headers.Local_File_Header := Metadata;
      Ignored_Memory : UnZip.p_Stream_Element_Array;
      Password : Unbounded_String;
      Lock : Epub.Synchronization.Guard (Compatibility_Lock'Access);
      pragma Unreferenced (Lock);
   begin
      Owner.Sink.all.Maximum := Metadata.dd.uncompressed_size;
      UnZip.Decompress.Decompress_Data
        (zip_file => Source_Stream,
         format => Zip.Format_from_Code (Metadata.zip_type),
         write_mode => UnZip.write_to_stream,
         output_file_name => "",
         output_memory_access => Ignored_Memory,
         output_stream_access => UnZip.p_Stream (Owner.Sink),
         feedback => null,
         explode_literal_tree => (Metadata.bit_flag and 4) /= 0,
         explode_slide_8KB_LZMA_EOS => (Metadata.bit_flag and Zip.Headers.LZMA_EOS_Flag_Bit) /= 0,
         data_descriptor_after_data => False,
         is_encrypted => False,
         password => Password,
         get_new_password => null,
         hint => Hint);
      pragma Assert (Hint.dd = Metadata.dd);
      pragma Assert (Ignored_Memory = null and then Length (Password) = 0);
      if Owner.Sink.all.Written /= Metadata.dd.uncompressed_size then
         raise Invalid_Payload with "Decompressed payload is shorter than its declared size";
      end if;
      return To_String (Owner.Sink.all.Bytes);
   end Decode_Compatibility;

   function Decode
     (Source_Stream : in out Zip_Streams.Root_Zipstream_Type'Class;
      Metadata : Zip.Headers.Local_File_Header) return String is
   begin
      if Metadata.zip_type in 0 | 8 then
         begin
            return Epub.Inflate.Decode (Source_Stream, Metadata);
         exception
            when Error : Epub.Inflate.Invalid_Stream =>
               raise Invalid_Payload with Ada.Exceptions.Exception_Message (Error);
         end;
      end if;
      return Decode_Compatibility (Source_Stream, Metadata);
   end Decode;
end UnZip.Epub_Decompression;

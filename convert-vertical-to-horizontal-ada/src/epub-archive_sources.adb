with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Epub.Stream_IO;
with Ada.Streams;
with UnZip.Epub_Decompression;

package body Epub.Archive_Sources is
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_16;
   use type Zip_Streams.ZS_Size_Type;
   use type Ada.Streams.Stream_Element_Offset;
   overriding procedure Adjust (Item : in out Reference) is
   begin
      if Item.Data /= null then
         Item.Data.all.Owners := Item.Data.all.Owners + 1;
      end if;
   end Adjust;
   overriding procedure Finalize (Item : in out Reference) is
      procedure Free is new Ada.Unchecked_Deallocation (Context, Context_Access);
      Data : Context_Access := Item.Data;
   begin
      Item.Data := null;
      if Data /= null then
         if Data.all.Owners = 1 then
            Free (Data);
         else
            Data.all.Owners := Data.all.Owners - 1;
         end if;
      end if;
   end Finalize;

   function Open (Path : String) return Reference is
   begin
      return Result : Reference do
         Result.Data := new Context;
         Result.Data.all.Stream.Open (Path);
      end return;
   end Open;
   function Is_Open (Item : Reference) return Boolean is (Item.Data /= null);
   function Size (Item : Reference) return Interfaces.Unsigned_64 is
     (Interfaces.Unsigned_64 (Item.Data.all.Stream.Size));

   function Digest (Item : Reference) return String is
   begin
      return Epub.Stream_IO.Digest (Item.Data.all.Stream);
   end Digest;

   procedure Copy (Item : Reference; Output : in out Zip_Streams.Root_Zipstream_Type'Class) is
   begin
      Epub.Stream_IO.Copy (Item.Data.all.Stream, Output);
   end Copy;

   procedure Copy_Range
     (Item : Reference; Offset : Zip_Streams.ZS_Index_Type; Count : Interfaces.Unsigned_64;
      Output : in out Zip_Streams.Root_Zipstream_Type'Class) is
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 65_536);
      Last : Ada.Streams.Stream_Element_Offset;
      Remaining : Interfaces.Unsigned_64 := Count;
      First : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Offset - 1);
   begin
      if First > Size (Item) or else Count > Size (Item) - First then
         raise Epub.File_Streams.File_Error with "Copied payload exceeds source bounds";
      end if;
      Item.Data.all.Stream.Set_Index (Offset);
      while Remaining > 0 loop
         declare
            Chunk : constant Ada.Streams.Stream_Element_Offset := Ada.Streams.Stream_Element_Offset
              (Interfaces.Unsigned_64'Min (Remaining, Buffer'Length));
         begin
            Item.Data.all.Stream.Read (Buffer (1 .. Chunk), Last);
            if Last < 1 or else Last > Chunk then
               raise Epub.File_Streams.File_Error with "Cannot read complete source payload";
            end if;
            Output.Write (Buffer (1 .. Last));
            Remaining := Remaining - Interfaces.Unsigned_64 (Last);
         end;
      end loop;
   end Copy_Range;

   function Decode
     (Item : Reference; Offset : Zip_Streams.ZS_Index_Type;
      Metadata : Zip.Headers.Local_File_Header) return String is
   begin
      if Interfaces.Unsigned_64 (Offset - 1) > Size (Item) or else
        Metadata.dd.compressed_size > Size (Item) - Interfaces.Unsigned_64 (Offset - 1)
      then
         raise Epub.File_Streams.File_Error with "Compressed payload exceeds source size";
      end if;
      Item.Data.all.Stream.Set_Index (Offset);
      if Metadata.zip_type in 0 | 8 then
         return UnZip.Epub_Decompression.Decode (Item.Data.all.Stream, Metadata);
      end if;
      declare
         Stream : Zip_Streams.Memory_Zipstream;
         Buffer : Zip.Byte_Buffer (1 .. Natural (Metadata.dd.compressed_size));
         Bytes : String (Buffer'Range);
      begin
         if Buffer'Length > 0 then
            Zip.Block_Read (Item.Data.all.Stream, Buffer);
         end if;
         for Position in Bytes'Range loop
            Bytes (Position) := Character'Val (Buffer (Position));
         end loop;
         Stream.Set (Ada.Strings.Unbounded.To_Unbounded_String (Bytes));
         return UnZip.Epub_Decompression.Decode (Stream, Metadata);
      end;
   end Decode;

   procedure Inspect (Item : Reference) is
   begin
      Action (Item.Data.all.Stream);
   end Inspect;
end Epub.Archive_Sources;

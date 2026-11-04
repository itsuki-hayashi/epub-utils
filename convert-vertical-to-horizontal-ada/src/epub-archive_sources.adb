with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Epub.Stream_IO;
with UnZip.Epub_Decompression;

package body Epub.Archive_Sources is
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_16;
   use type Zip_Streams.ZS_Size_Type;
   use type Ada.Streams.Stream_Element_Offset;
   protected body Ownership is
      procedure Retain is
      begin
         pragma Assert (Count > 0);
         Count := Count + 1;
      end Retain;
      procedure Release (Last : out Boolean) is
      begin
         pragma Assert (Count > 0);
         Count := Count - 1;
         Last := Count = 0;
      end Release;
      function Unique return Boolean is (Count = 1);
   end Ownership;
   overriding procedure Adjust (Item : in out Reference) is
   begin
      if Item.Data /= null then
         Item.Data.all.Owners.Retain;
      end if;
   end Adjust;
   overriding procedure Finalize (Item : in out Reference) is
      procedure Free is new Ada.Unchecked_Deallocation (Context, Context_Access);
      Data : Context_Access := Item.Data;
      Last : Boolean := False;
   begin
      Item.Data := null;
      if Data /= null then
         Data.all.Owners.Release (Last);
         if Last then
            Free (Data);
         end if;
      end if;
   end Finalize;

   function Open (Path : String) return Reference is
   begin
      return Result : Reference do
         Result.Data := new Context;
         Result.Data.all.Stream.Open (Path);
         Result.Data.all.Length := Interfaces.Unsigned_64 (Result.Data.all.Stream.Size);
      end return;
   end Open;
   function Is_Open (Item : Reference) return Boolean is (Item.Data /= null);
   procedure Close_Checked (Item : in out Reference) is
   begin
      if Item.Data /= null then
         if not Item.Data.all.Owners.Unique then
            raise Program_Error with "Source readers must drain before checked close";
         end if;
         Item.Data.all.Stream.Close;
         Finalize (Item);
      end if;
   end Close_Checked;
   function Size (Item : Reference) return Interfaces.Unsigned_64 is
     (Item.Data.all.Length);

   function View (Item : Reference'Class; Offset : Zip_Streams.ZS_Index_Type;
                  Count : Interfaces.Unsigned_64) return Reader is
      First : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Offset - 1);
   begin
      if not Is_Open (Item) or else First > Size (Item) or else Count > Size (Item) - First
        or else Count >= Interfaces.Unsigned_64 (Zip_Streams.ZS_Size_Type'Last)
      then
         raise Epub.File_Streams.File_Error with "Reader exceeds source bounds";
      end if;
      return Result : Reader do
         Result.Owner := Reference (Item);
         Result.First := Offset;
         Result.Length := Zip_Streams.ZS_Size_Type (Count);
         Result.Set_Name (Item.Data.all.Stream.Get_Name);
      end return;
   end View;

   overriding procedure Read
     (Item : in out Reader; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset) is
      Cursor : Ada.Streams.Stream_Element_Offset := Buffer'First;
   begin
      Last := Buffer'First - 1;
      while Cursor <= Buffer'Last and then not Item.End_Of_Stream loop
         declare
            Amount : constant Ada.Streams.Stream_Element_Offset :=
              Ada.Streams.Stream_Element_Offset'Min (65_536,
                Ada.Streams.Stream_Element_Offset'Min (Buffer'Last - Cursor + 1,
                  Ada.Streams.Stream_Element_Offset (Item.Length - Item.Position + 1)));
            Got : Ada.Streams.Stream_Element_Offset;
            Lock : Epub.Synchronization.Guard (Item.Owner.Data.all.IO_Lock'Access);
            pragma Unreferenced (Lock);
         begin
            Item.Owner.Data.all.Stream.Set_Index (Item.First + Item.Position - 1);
            Item.Owner.Data.all.Stream.Read (Buffer (Cursor .. Cursor + Amount - 1), Got);
            if Got < Cursor then
               raise Epub.File_Streams.File_Error with "Cannot read complete source range";
            end if;
            Item.Position := Item.Position + Zip_Streams.ZS_Size_Type (Got - Cursor + 1);
            Last := Got;
            Cursor := Got + 1;
         end;
      end loop;
   end Read;
   overriding procedure Write (Item : in out Reader; Buffer : Ada.Streams.Stream_Element_Array) is
      pragma Unreferenced (Item, Buffer);
   begin
      raise Epub.File_Streams.File_Error with "Source reader is read-only";
   end Write;
   overriding procedure Set_Index (Item : in out Reader; To : Zip_Streams.ZS_Index_Type) is
   begin
      if To > Item.Length + 1 then
         raise Epub.File_Streams.File_Error with "Seek exceeds source reader bounds";
      end if;
      Item.Position := To;
   end Set_Index;
   overriding function Index (Item : Reader) return Zip_Streams.ZS_Index_Type is (Item.Position);
   overriding function Size (Item : Reader) return Zip_Streams.ZS_Size_Type is (Item.Length);
   overriding function End_Of_Stream (Item : Reader) return Boolean is (Item.Position > Item.Length);

   function Digest (Item : Reference) return String is
   begin
      declare
         Stream : Reader := View (Item, 1, Size (Item));
      begin
         return Epub.Stream_IO.Digest (Stream);
      end;
   end Digest;

   procedure Copy (Item : Reference; Output : in out Zip_Streams.Root_Zipstream_Type'Class) is
   begin
      declare
         Stream : Reader := View (Item, 1, Size (Item));
      begin
         Epub.Stream_IO.Copy (Stream, Output);
         pragma Assert (Stream.End_Of_Stream);
      end;
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
      declare
         Stream : Reader := View (Item, Offset, Count);
      begin
         while Remaining > 0 loop
            declare
               Chunk : constant Ada.Streams.Stream_Element_Offset := Ada.Streams.Stream_Element_Offset
                 (Interfaces.Unsigned_64'Min (Remaining, Buffer'Length));
            begin
               Stream.Read (Buffer (1 .. Chunk), Last);
               if Last < 1 or else Last > Chunk then
                  raise Epub.File_Streams.File_Error with "Cannot read complete source payload";
               end if;
               Output.Write (Buffer (1 .. Last));
               Remaining := Remaining - Interfaces.Unsigned_64 (Last);
            end;
         end loop;
      end;
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
      declare
         Input : Reader := View (Item, Offset, Metadata.dd.compressed_size);
      begin
         if Metadata.zip_type in 0 | 8 then
            return UnZip.Epub_Decompression.Decode (Input, Metadata);
         end if;
         declare
            Stream : Zip_Streams.Memory_Zipstream;
            Buffer : Zip.Byte_Buffer (1 .. Natural (Metadata.dd.compressed_size));
            Bytes : String (Buffer'Range);
         begin
            if Buffer'Length > 0 then Zip.Block_Read (Input, Buffer); end if;
            for Position in Bytes'Range loop
               Bytes (Position) := Character'Val (Buffer (Position));
            end loop;
            Stream.Set (Ada.Strings.Unbounded.To_Unbounded_String (Bytes));
            return UnZip.Epub_Decompression.Decode (Stream, Metadata);
         end;
      end;
   end Decode;

   procedure Inspect (Item : Reference) is
   begin
      declare
         Stream : Reader := View (Item, 1, Size (Item));
      begin
         Action (Stream);
         pragma Assert (Stream.Index <= Stream.Size + 1);
      end;
   end Inspect;
end Epub.Archive_Sources;

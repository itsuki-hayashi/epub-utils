with GNAT.SHA256;
with UnZip.Epub_Decompression;
with Zip.Compress;
with Epub.Encoding;

package body Epub.Archives is
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Zip_Streams.ZS_Size_Type;
   use type Zip_Streams.Time;
   use type Zip.Headers.Data_Descriptor;

   function Get_Bytes
     (Stream : in out Zip_Streams.Root_Zipstream_Type'Class; Count : Natural)
      return String is
      Buffer : Zip.Byte_Buffer (1 .. Count);
      Result : String (1 .. Count);
   begin
      if Count > 0 then
         Zip.Block_Read (Stream, Buffer);
         for Position in Result'Range loop
            Result (Position) := Character'Val (Buffer (Position));
         end loop;
      end if;
      return Result;
   end Get_Bytes;

   procedure Put_Bytes
     (Stream : in out Zip_Streams.Root_Zipstream_Type'Class; Bytes : String) is
      Buffer : Zip.Byte_Buffer (Bytes'Range);
   begin
      if Bytes'Length > 0 then
         for Position in Bytes'Range loop
            Buffer (Position) := Character'Pos (Bytes (Position));
         end loop;
         Zip.Block_Write (Stream, Buffer);
      end if;
   end Put_Bytes;

   function Number (Bytes : String; Position, Width : Positive)
      return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      if Position < Bytes'First or else Position > Bytes'Last - Width + 1 then
         raise Invalid_Archive with "Truncated ZIP extra field";
      end if;
      for Offset in reverse 0 .. Width - 1 loop
         Result := Result * 256 + Interfaces.Unsigned_64
           (Character'Pos (Bytes (Position + Offset)));
      end loop;
      return Result;
   end Number;

   procedure Apply_Zip64 (Item : in out Member; Extra : String) is
      Position : Integer := Extra'First;
      Found : Boolean := False;
   begin
      while Position <= Extra'Last loop
         declare
            Tag : constant Interfaces.Unsigned_64 := Number (Extra, Position, 2);
            Count : constant Natural := Natural (Number (Extra, Position + 2, 2));
            Value_Position : Natural := Position + 4;
         begin
            if Count > Extra'Last - Position - 3 then
               raise Invalid_Archive with "Truncated ZIP extra data";
            end if;
            if Tag = 1 then
               if Found then
                  raise Invalid_Archive with "Duplicate ZIP64 extra field";
               end if;
               Found := True;
               Item.Was_Zip64 := True;
               declare
                  Field : constant String := Extra (Value_Position .. Value_Position + Count - 1);
               begin
                  if Item.Header.short_info.dd.uncompressed_size = 16#FFFF_FFFF# then
                     Item.Header.short_info.dd.uncompressed_size := Number (Field, Value_Position, 8);
                     Value_Position := Value_Position + 8;
                  end if;
                  if Item.Header.short_info.dd.compressed_size = 16#FFFF_FFFF# then
                     Item.Header.short_info.dd.compressed_size := Number (Field, Value_Position, 8);
                     Value_Position := Value_Position + 8;
                  end if;
                  if Item.Header.local_header_offset = 16#FFFF_FFFF# then
                     Item.Header.local_header_offset := Number (Field, Value_Position, 8);
                     Value_Position := Value_Position + 8;
                  end if;
                  if Item.Header.disk_number_start = 16#FFFF# then
                     if Number (Field, Value_Position, 4) /= 0 then
                        raise Invalid_Archive with "Multi-disk ZIP64 entry";
                     end if;
                     Item.Header.disk_number_start := 0;
                  end if;
               end;
            end if;
            Position := Position + 4 + Count;
         end;
      end loop;
      if not Found and then
        (Item.Header.short_info.dd.uncompressed_size = 16#FFFF_FFFF#
         or else Item.Header.short_info.dd.compressed_size = 16#FFFF_FFFF#
         or else Item.Header.local_header_offset = 16#FFFF_FFFF#
         or else Item.Header.disk_number_start = 16#FFFF#)
      then
         raise Invalid_Archive with "Missing ZIP64 extra field";
      end if;
   end Apply_Zip64;

   function Find (Items : Catalogue; Name : String) return Natural is
   begin
      for Position in 1 .. Items.Last_Index loop
         if To_String (Items (Position).Name) = Name then
            return Position;
         end if;
      end loop;
      return 0;
   end Find;

   function Contents (Items : Catalogue; Name : String) return String is
      Position : constant Natural := Find (Items, Name);
   begin
      if Position = 0 then
         raise Invalid_Archive with "Missing EPUB resource: " & Name;
      end if;
      return To_String (Items (Position).Payload);
   end Contents;

   function Read (Bytes : String) return Catalogue is
      Stream : Zip_Streams.Memory_Zipstream;
      Ending : Zip.Headers.End_of_Central_Dir;
      Result : Catalogue;
      Central_First, Central_Last : Interfaces.Unsigned_64;
      Limit : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Bytes'Length);
      type Entry_Region is record
         Start_Offset, End_Offset : Interfaces.Unsigned_64;
      end record;
      package Region_Lists is new Epub.Lists (Entry_Region);
      Regions : Region_Lists.Vector;

      procedure Check_Range (First, Count, Last : Interfaces.Unsigned_64) is
      begin
         if First > Last or else Count > Last - First then
            raise Invalid_Archive with "ZIP structure extends outside its containing region";
         end if;
      end Check_Range;
   begin
      Stream.Set (To_Unbounded_String (Bytes));
      Zip.Headers.Load (Stream, Ending);
      if Ending.disknum /= 0 or else Ending.disknum_with_start /= 0
        or else Ending.disk_total_entries /= Ending.total_entries
      then
         raise Invalid_Archive with "Multi-disk EPUB archives are unsupported";
      end if;
      Check_Range (Ending.central_dir_offset, Interfaces.Unsigned_64 (Ending.offset_shifting), Limit);
      Central_First := Ending.central_dir_offset + Interfaces.Unsigned_64 (Ending.offset_shifting);
      Check_Range (Central_First, Ending.central_dir_size, Limit);
      Central_Last := Central_First + Ending.central_dir_size;
      Stream.Set_Index (Zip_Streams.ZS_Index_Type (Ending.central_dir_offset)
                        + Ending.offset_shifting + 1);
      for Ordinal in 1 .. Natural (Ending.total_entries) loop
         declare
            Item : Member;
         begin
            Check_Range (Interfaces.Unsigned_64 (Stream.Index - 1), 46, Central_Last);
            Zip.Headers.Read_and_Check (Stream, Item.Header);
            Check_Range (Interfaces.Unsigned_64 (Stream.Index - 1),
              Interfaces.Unsigned_64 (Item.Header.short_info.filename_length) +
              Interfaces.Unsigned_64 (Item.Header.short_info.extra_field_length) +
              Interfaces.Unsigned_64 (Item.Header.comment_length), Central_Last);
            Item.Raw_Name := To_Unbounded_String
              (Get_Bytes (Stream, Natural (Item.Header.short_info.filename_length)));
            Item.Name := Item.Raw_Name;
            if Length (Item.Raw_Name) = 0 or else
              Ada.Strings.Unbounded.Index (Item.Raw_Name, [1 => Character'Val (0)]) /= 0
            then
               raise Invalid_Archive with "Empty or NUL-containing ZIP entry name";
            end if;
            if (Item.Header.short_info.bit_flag and Zip.Headers.Language_Encoding_Flag_Bit) /= 0 then
               Item.Name := To_Unbounded_String
                 (Epub.Encoding.From_UTF8 (To_String (Item.Raw_Name), Epub.Encoding.UTF8));
            end if;
            Apply_Zip64 (Item, Get_Bytes (Stream, Natural (Item.Header.short_info.extra_field_length)));
            Stream.Set_Index (Stream.Index + Zip_Streams.ZS_Size_Type (Item.Header.comment_length));
            if Item.Header.disk_number_start /= 0 then
               raise Invalid_Archive with "Multi-disk ZIP entry";
            end if;
            if Find (Result, To_String (Item.Name)) /= 0 then
               raise Invalid_Archive with "Duplicate ZIP entry: " & To_String (Item.Name);
            end if;
            Result.Append (Item);
         end;
      end loop;
      for Ordinal in 1 .. Result.Last_Index loop
         declare
            Item : Member := Result (Ordinal);
            Local_Header : Zip.Headers.Local_File_Header;
            Local_Item : Member;
            Compressed_Start : Zip_Streams.ZS_Index_Type;
            Region_End : Interfaces.Unsigned_64;
         begin
            Check_Range (Item.Header.local_header_offset,
              Interfaces.Unsigned_64 (Ending.offset_shifting), Central_First);
            Check_Range (Item.Header.local_header_offset + Interfaces.Unsigned_64 (Ending.offset_shifting),
              30, Central_First);
            Stream.Set_Index (Zip_Streams.ZS_Index_Type
              (Zip_Streams.ZS_Size_Type (Item.Header.local_header_offset)
               + Ending.offset_shifting + 1));
            Zip.Headers.Read_and_Check (Stream, Local_Header);
            if Get_Bytes (Stream, Natural (Local_Header.filename_length)) /= To_String (Item.Raw_Name)
              or else Local_Header.bit_flag /= Item.Header.short_info.bit_flag
              or else Local_Header.zip_type /= Item.Header.short_info.zip_type
              or else Local_Header.file_timedate /= Item.Header.short_info.file_timedate
            then
               raise Invalid_Archive with "Local/central ZIP header mismatch";
            end if;
            if (Local_Header.bit_flag and 1) /= 0 then
               raise Invalid_Archive with "Encrypted ZIP entry is unsupported";
            end if;
            Check_Range (Interfaces.Unsigned_64 (Stream.Index - 1),
              Interfaces.Unsigned_64 (Local_Header.extra_field_length), Central_First);
            Local_Item.Header.short_info := Local_Header;
            Apply_Zip64 (Local_Item, Get_Bytes (Stream, Natural (Local_Header.extra_field_length)));
            if (Local_Header.bit_flag and 8) = 0 then
               if Local_Item.Header.short_info.dd /= Item.Header.short_info.dd then
                  raise Invalid_Archive with "Local/central ZIP CRC or size mismatch";
               end if;
            elsif (Local_Item.Header.short_info.dd.crc_32 /= 0 and then
                     Local_Item.Header.short_info.dd.crc_32 /= Item.Header.short_info.dd.crc_32)
              or else (Local_Item.Header.short_info.dd.compressed_size /= 0 and then
                       Local_Item.Header.short_info.dd.compressed_size /= Item.Header.short_info.dd.compressed_size)
              or else (Local_Item.Header.short_info.dd.uncompressed_size /= 0 and then
                       Local_Item.Header.short_info.dd.uncompressed_size /= Item.Header.short_info.dd.uncompressed_size)
            then
               raise Invalid_Archive with "Invalid ZIP data-descriptor placeholders";
            end if;
            Check_Range (Interfaces.Unsigned_64 (Stream.Index - 1),
              Item.Header.short_info.dd.compressed_size, Central_First);
            Compressed_Start := Stream.Index;
            Region_End := Interfaces.Unsigned_64 (Compressed_Start - 1) +
              Item.Header.short_info.dd.compressed_size;
            if (Local_Header.bit_flag and 8) /= 0 then
               declare
                  Data_End : constant Interfaces.Unsigned_64 :=
                    Interfaces.Unsigned_64 (Stream.Index - 1) + Item.Header.short_info.dd.compressed_size;
                  Width : constant Positive := (if Local_Item.Was_Zip64 then 8 else 4);
                  Marker : Interfaces.Unsigned_64;

                  function Matches_Descriptor (Signed : Boolean) return Boolean is
                     Skip : constant Interfaces.Unsigned_64 := (if Signed then 4 else 0);
                     Count : constant Positive := 4 + 2 * Width;
                  begin
                     if Skip + Interfaces.Unsigned_64 (Count) > Central_First - Data_End then
                        return False;
                     end if;
                     Stream.Set_Index (Zip_Streams.ZS_Index_Type (Data_End + Skip + 1));
                     declare
                        Data : constant String := Get_Bytes (Stream, Count);
                     begin
                        return Number (Data, 1, 4) = Interfaces.Unsigned_64 (Item.Header.short_info.dd.crc_32)
                          and then Number (Data, 5, Width) = Item.Header.short_info.dd.compressed_size
                          and then Number (Data, 5 + Width, Width) = Item.Header.short_info.dd.uncompressed_size;
                     end;
                  end Matches_Descriptor;
               begin
                  Check_Range (Data_End, 4, Central_First);
                  Stream.Set_Index (Zip_Streams.ZS_Index_Type (Data_End + 1));
                  Marker := Number (Get_Bytes (Stream, 4), 1, 4);
                  if Matches_Descriptor (False) then
                     Region_End := Data_End + Interfaces.Unsigned_64 (4 + 2 * Width);
                  elsif Marker = 16#0807_4B50# and then Matches_Descriptor (True) then
                     Region_End := Data_End + Interfaces.Unsigned_64 (8 + 2 * Width);
                  else
                     raise Invalid_Archive with "ZIP data descriptor disagrees with the central directory";
                  end if;
               end;
            end if;
            declare
               Current : constant Entry_Region :=
                 (Start_Offset => Item.Header.local_header_offset + Interfaces.Unsigned_64 (Ending.offset_shifting),
                  End_Offset => Region_End);
            begin
               for Previous of Regions loop
                  if Current.Start_Offset < Previous.End_Offset and then
                    Previous.Start_Offset < Current.End_Offset
                  then
                     raise Invalid_Archive with "Overlapping ZIP entries";
                  end if;
               end loop;
               Regions.Append (Current);
            end;
            declare
               Payload_Stream : Zip_Streams.Memory_Zipstream;
            begin
               Stream.Set_Index (Compressed_Start);
               Payload_Stream.Set (To_Unbounded_String
                 (Get_Bytes (Stream, Natural (Item.Header.short_info.dd.compressed_size))));
               Local_Header.dd := Item.Header.short_info.dd;
               Item.Payload := To_Unbounded_String
                 (UnZip.Epub_Decompression.Decode (Payload_Stream, Local_Header));
            end;
            Result.Replace_Element (Ordinal, Item);
         end;
      end loop;
      return Result;
   end Read;

   function Create_Member
     (Name, Payload : String; Attributes : Interfaces.Unsigned_32 := 0)
      return Member is
      Result : Member;
   begin
      Result.Name := To_Unbounded_String (Name);
      Result.Raw_Name := Result.Name;
      Result.Payload := To_Unbounded_String (Payload);
      Result.Header.external_attributes := Attributes;
      for Value of Name loop
         if Character'Pos (Value) >= 128 then
            Result.Header.short_info.bit_flag := Zip.Headers.Language_Encoding_Flag_Bit;
         end if;
      end loop;
      return Result;
   end Create_Member;

   function Rebuild (Items : Catalogue) return String is
      Output : Zip_Streams.Memory_Zipstream;
      Written : Catalogue;
      Ending : Zip.Headers.End_of_Central_Dir;
      Force_Zip64 : Boolean := False;
   begin
      if Items.Is_Empty or else To_String (Items (1).Name) /= "mimetype" then
         raise Invalid_Archive with "Expected mimetype as the first ZIP entry";
      elsif To_String (Items (1).Payload) /= "application/epub+zip" then
         raise Invalid_Archive with "Invalid EPUB mimetype payload";
      end if;
      Output.Set (Null_Unbounded_String);
      for Ordinal in 1 .. Items.Last_Index loop
         declare
            Item : Member := Items (Ordinal);
            Input, Compressed : Zip_Streams.Memory_Zipstream;
            Compressed_Size : Zip.Zip_64_Data_Size_Type;
            Compressed_Bytes : Unbounded_String;
            CRC : Interfaces.Unsigned_32;
            Method : Interfaces.Unsigned_16;
         begin
            if Find (Written, To_String (Item.Name)) /= 0 then
               raise Invalid_Archive with "Duplicate ZIP entry";
            end if;
            Input.Set (Item.Payload);
            Compressed.Set (Null_Unbounded_String);
            Zip.Compress.Compress_Data
              (Input, Compressed, True, Interfaces.Unsigned_64 (Length (Item.Payload)),
               (if Ordinal = 1 then Zip.Compress.Store else Zip.Compress.Deflate_R),
               null, "", Zip.Compress.neutral, CRC, Compressed_Size, Method);
            if Input.Index /= Zip_Streams.ZS_Size_Type (Length (Item.Payload)) + 1 then
               raise Invalid_Archive with "Compression did not consume the complete payload";
            end if;
            Compressed.Get (Compressed_Bytes);
            Item.Header.local_header_offset := Interfaces.Unsigned_64 (Output.Index - 1);
            Item.Header.short_info.dd :=
              (crc_32 => CRC, compressed_size => Compressed_Size,
               uncompressed_size => Interfaces.Unsigned_64 (Length (Item.Payload)));
            Item.Header.short_info.zip_type := Method;
            Item.Header.short_info.bit_flag :=
              (if Ordinal = 1 then 0 else
                 Item.Header.short_info.bit_flag and Zip.Headers.Language_Encoding_Flag_Bit);
            Item.Header.short_info.filename_length := Interfaces.Unsigned_16 (Length (Item.Raw_Name));
            Item.Header.short_info.extra_field_length := 0;
            Item.Header.comment_length := 0;
            Item.Header.disk_number_start := 0;
            Item.Was_Zip64 := Item.Was_Zip64 and then Ordinal /= 1;
            Item.Header.short_info.needed_extract_version := (if Item.Was_Zip64 then 45 else 20);
            Force_Zip64 := Force_Zip64 or else Item.Was_Zip64;
            Zip.Headers.Write (Output, Item.Header.short_info,
              (if Item.Was_Zip64 then Zip.Headers.force_zip_64 else Zip.Headers.force_empty));
            Put_Bytes (Output, To_String (Item.Raw_Name));
            if Item.Was_Zip64 then
               Zip.Headers.Write (Output,
                 Zip.Headers.Local_File_Header_Extension'
                   (tag => 1, size => 16,
                    value_64 => [Item.Header.short_info.dd.uncompressed_size,
                                 Item.Header.short_info.dd.compressed_size, 0]), True);
            end if;
            Put_Bytes (Output, Slice (Compressed_Bytes, 1, Natural (Compressed_Size)));
            Written.Append (Item);
         end;
      end loop;
      Ending.central_dir_offset := Interfaces.Unsigned_64 (Output.Index - 1);
      for Item of Written loop
         declare
            Header : Zip.Headers.Central_File_Header := Item.Header;
         begin
            if Item.Was_Zip64 then
               Header.short_info.dd.compressed_size := 16#FFFF_FFFF#;
               Header.short_info.dd.uncompressed_size := 16#FFFF_FFFF#;
               Header.local_header_offset := 16#FFFF_FFFF#;
               Header.short_info.extra_field_length := 28;
            end if;
            Zip.Headers.Write (Output, Header);
            Put_Bytes (Output, To_String (Item.Raw_Name));
            if Item.Was_Zip64 then
               Zip.Headers.Write (Output,
                 Zip.Headers.Local_File_Header_Extension'
                   (tag => 1, size => 24,
                    value_64 => [Item.Header.short_info.dd.uncompressed_size,
                                 Item.Header.short_info.dd.compressed_size,
                                 Item.Header.local_header_offset]), False);
            end if;
         end;
      end loop;
      Ending.central_dir_size := Interfaces.Unsigned_64 (Output.Index - 1) - Ending.central_dir_offset;
      Ending.disknum := 0;
      Ending.disknum_with_start := 0;
      Ending.total_entries := Interfaces.Unsigned_64 (Written.Last_Index);
      Ending.disk_total_entries := Ending.total_entries;
      Ending.main_comment_length := 0;
      Ending.offset_shifting := 0;
      if Force_Zip64 or else Written.Last_Index >= 65535 then
         declare
            Offset : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Output.Index - 1);
         begin
            Zip.Headers.Write (Output, Zip.Headers.Zip64_End_of_Central_Dir'
              (size => 44, version_made_by => 45, version_needed_to_extract => 45,
               number_of_this_disk => 0,
               number_of_the_disk_with_the_start_of_the_central_directory => 0,
               total_number_of_entries_in_the_central_directory_on_this_disk => Ending.total_entries,
               total_number_of_entries_in_the_central_directory => Ending.total_entries,
               size_of_the_central_directory => Ending.central_dir_size,
               offset_of_start_of_central_directory => Ending.central_dir_offset));
            Zip.Headers.Write (Output, Zip.Headers.Zip64_End_of_Central_Dir_Locator'
              (number_of_the_disk_with_the_start_of_the_zip64_end_of_central_dir => 0,
               relative_offset_of_the_zip64_end_of_central_dir_record => Offset,
               total_number_of_disks => 1));
            Ending.total_entries := 65535;
            Ending.disk_total_entries := 65535;
            Ending.central_dir_offset := 16#FFFF_FFFF#;
            Ending.central_dir_size := 16#FFFF_FFFF#;
         end;
      end if;
      Zip.Headers.Write (Output, Ending);
      declare
         Bytes : Unbounded_String;
      begin
         Output.Get (Bytes);
         Verify (To_String (Bytes), Items);
         return To_String (Bytes);
      end;
   end Rebuild;

   procedure Verify (Bytes : String; Expected : Catalogue) is
      Actual : constant Catalogue := Read (Bytes);
   begin
      if Actual.Last_Index /= Expected.Last_Index then
         raise Invalid_Archive with "Verification failed: entry count changed";
      end if;
      for Ordinal in 1 .. Expected.Last_Index loop
         declare
            Left : constant Member := Actual (Ordinal);
            Right : constant Member := Expected (Ordinal);
         begin
            if Left.Name /= Right.Name or else Left.Raw_Name /= Right.Raw_Name
              or else Left.Header.short_info.file_timedate /= Right.Header.short_info.file_timedate
              or else Left.Header.external_attributes /= Right.Header.external_attributes
              or else Length (Left.Payload) /= Length (Right.Payload)
              or else GNAT.SHA256.Digest (To_String (Left.Payload)) /=
                GNAT.SHA256.Digest (To_String (Right.Payload))
            then
               raise Invalid_Archive with "Verification failed: " & To_String (Right.Name);
            end if;
         end;
      end loop;
      if Actual.Is_Empty or else To_String (Actual (1).Name) /= "mimetype"
        or else Actual (1).Header.short_info.zip_type /= 0
        or else Actual (1).Header.short_info.bit_flag /= 0
        or else Actual (1).Header.short_info.extra_field_length /= 0
      then
         raise Invalid_Archive with "Invalid EPUB mimetype ZIP header";
      end if;
   end Verify;
end Epub.Archives;

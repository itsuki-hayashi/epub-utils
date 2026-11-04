with Ada.Strings.Unbounded;
with AUnit.Assertions;
with Epub.Compression;
with Epub.Checksums;
with Epub.Inflate;
with Interfaces;
with UnZip.Epub_Decompression;
with Zip.Compress;
with Zip.Headers;
with Zip_Streams;
with Epub.Archives;
with Epub.Books;
with Epub.Files;

package body Inflate_Cases is
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;
   use Interfaces;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Inflate: " & Item.Kind'Image));

   function Header (Raw : String; Length : Unsigned_64; CRC : Unsigned_32 := 0;
                    Method : Unsigned_16 := 8) return Zip.Headers.Local_File_Header is
     (needed_extract_version => 20, bit_flag => 0, zip_type => Method,
      file_timedate => Zip_Streams.default_time,
      dd => (crc_32 => CRC, compressed_size => Raw'Length, uncompressed_size => Length),
      filename_length => 0, extra_field_length => 0);

   function Decode (Raw : String; Metadata : Zip.Headers.Local_File_Header; Reference : Boolean := False) return String is
      Stream : Zip_Streams.Memory_Zipstream;
   begin
      Stream.Set (To_Unbounded_String (Raw));
      declare
         Result : constant String :=
           (if Reference then UnZip.Epub_Decompression.Decode_Compatibility (Stream, Metadata)
            else UnZip.Epub_Decompression.Decode (Stream, Metadata));
      begin
         pragma Assert (Stream.Size >= Raw'Length);
         return Result;
      end;
   end Decode;

   type Writer is record
      Bytes : Unbounded_String;
      Bits : Unsigned_32 := 0;
      Used : Natural := 0;
   end record;
   procedure Put (Item : in out Writer; Value : Unsigned_32; Count : Natural) is
   begin
      for Offset in 0 .. Count - 1 loop
         Item.Bits := Item.Bits or Shift_Left (Shift_Right (Value, Offset) and 1, Item.Used);
         Item.Used := Item.Used + 1;
         if Item.Used = 8 then
            Append (Item.Bytes, Character'Val (Item.Bits));
            Item.Used := 0;
            Item.Bits := 0;
         end if;
      end loop;
   end Put;
   procedure Code (Item : in out Writer; Value : Unsigned_32; Count : Positive) is
   begin
      for Offset in reverse 0 .. Count - 1 loop
         Put (Item, Shift_Right (Value, Offset) and 1, 1);
      end loop;
   end Code;
   function Finish (Item : in out Writer) return String is
   begin
      if Item.Used > 0 then
         Append (Item.Bytes, Character'Val (Item.Bits));
         Item.Used := 0;
         Item.Bits := 0;
      end if;
      return To_String (Item.Bytes);
   end Finish;

   procedure Reject (Raw : String; Length : Unsigned_64 := 0; Method : Unsigned_16 := 8) is
      Stream : Zip_Streams.Memory_Zipstream;
   begin
      Stream.Set (To_Unbounded_String (Raw));
      declare
         Result : constant String := Epub.Inflate.Decode (Stream, Header (Raw, Length, Method => Method));
      begin
         pragma Assert (Stream.Size >= Raw'Length);
         Assert (False, "Malformed stream accepted, output bytes=" & Result'Length'Image);
      end;
   exception
      when Epub.Inflate.Invalid_Stream => null;
   end Reject;

   overriding procedure Run_Test (Item : in out Unit_Case) is
   begin
      case Item.Kind is
         when Original_Representation =>
            declare
               Payload : constant String (1 .. 600) := [others => 'a'];
               Path : constant String := "../test-results/original-deflate.epub";
               Bits : Writer;
               Archive : Zip_Streams.Memory_Zipstream;
               Original : Epub.Archives.Catalogue;
               Ending : Zip.Headers.End_of_Central_Dir;
               Stored_Bytes : Unbounded_String;
               procedure Put_Bytes (Bytes : String) is
                  Buffer : constant Zip.Byte_Buffer (Bytes'Range) with Import, Address => Bytes'Address;
               begin
                  if Bytes'Length > 0 then Zip.Block_Write (Archive, Buffer); end if;
               end Put_Bytes;
               procedure Local (Member_Info : in out Epub.Archives.Member; Raw : String; Method : Unsigned_16) is
               begin
                  Member_Info.Header.local_header_offset := Unsigned_64 (Archive.Index - 1);
                  Member_Info.Header.short_info := Header
                    (Raw, Unsigned_64 (Length (Member_Info.Payload)), Epub.Checksums.CRC32 (To_String (Member_Info.Payload)), Method);
                  Member_Info.Header.short_info.filename_length := Unsigned_16 (Length (Member_Info.Raw_Name));
                  Zip.Headers.Write (Archive, Member_Info.Header.short_info, Zip.Headers.force_empty);
                  Put_Bytes (To_String (Member_Info.Raw_Name));
                  Put_Bytes (Raw);
               end Local;
            begin
               --  An independently constructed, valid eight-byte fixed
               --  stream beats the current encoder's nine-byte result.
               Put (Bits, 1, 1); Put (Bits, 1, 2);
               Code (Bits, 16#91#, 8); -- one 'a'
               for Index in 1 .. 2 loop
                  Code (Bits, 16#C5#, 8); Code (Bits, 0, 5); -- length 258, distance 1
               end loop;
               Code (Bits, 22, 7); Put (Bits, 0, 4); Code (Bits, 0, 5); -- length 83
               Code (Bits, 0, 7);
               declare
                  Raw : constant String := Finish (Bits);
                  Mime : Epub.Archives.Member := Epub.Archives.Create_Member ("mimetype", "application/epub+zip");
                  Data : Epub.Archives.Member := Epub.Archives.Create_Member ("OPS/payload.bin", Payload);
               begin
                  Assert (Raw'Length = 8 and then Decode
                    (Raw, Header (Raw, Payload'Length, Epub.Checksums.CRC32 (Payload)), Reference => True) = Payload,
                    "Independent compact source representation");
                  Archive.Set (Null_Unbounded_String);
                  Local (Mime, "application/epub+zip", 0);
                  Local (Data, Raw, 8);
                  Original.Append (Mime); Original.Append (Data);
               end;
               Ending.central_dir_offset := Unsigned_64 (Archive.Index - 1);
               for Member_Info of Original loop
                  Zip.Headers.Write (Archive, Member_Info.Header);
                  Put_Bytes (To_String (Member_Info.Raw_Name));
               end loop;
               Ending.central_dir_size := Unsigned_64 (Archive.Index - 1) - Ending.central_dir_offset;
               Ending.disknum := 0; Ending.disknum_with_start := 0;
               Ending.total_entries := 2; Ending.disk_total_entries := 2;
               Ending.main_comment_length := 0; Ending.offset_shifting := 0;
               Zip.Headers.Write (Archive, Ending);
               Archive.Get (Stored_Bytes);
               Epub.Files.Remove (Path);
               Epub.Files.Write_Exclusive (Path, To_String (Stored_Bytes));
               declare
                  Source : constant Epub.Archives.Catalogue := Epub.Archives.Read_File (Path);
                  Rebuilt : constant String := Epub.Archives.Rebuild (Source);
                  Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Rebuilt);
                  Plan : Epub.Books.Book_Plan;
                  Generated : constant Epub.Archives.Catalogue := Epub.Archives.Read (Epub.Archives.Rebuild (Original));
               begin
                  Assert (Generated (2).Header.short_info.dd.compressed_size > 8,
                          "Test exercises a strictly smaller original encoding");
                  Assert (Actual (2).Header.short_info.dd.compressed_size = 8,
                          "Unchanged resource retains the smaller validated DEFLATE stream");
                  Epub.Archives.Verify (Rebuilt, Source);
                  Plan.Patches.Append ((To_Unbounded_String ("OPS/payload.bin"), To_Unbounded_String ([1 .. 600 => 'b'])));
                  declare
                     Patched : constant Epub.Archives.Catalogue := Epub.Books.Apply (Source, Plan);
                     Modified : constant String := Epub.Archives.Rebuild (Patched);
                  begin
                     Assert (Epub.Archives.Contents (Epub.Archives.Read (Modified), "OPS/payload.bin") = [1 .. 600 => 'b'],
                             "Changed resources cannot reuse original compressed bytes");
                     Epub.Archives.Verify (Modified, Patched);
                  end;
               end;
               Epub.Files.Remove (Path);
            end;
         when Bounded_Input =>
            declare
               type Methods is array (Positive range <>) of Unsigned_16;
               Prefix : constant String (1 .. 16) := [others => 'p'];
               Following : constant String (1 .. 4096) := [others => Character'Val (204)];
            begin
               for Method of Methods'[0, 8] loop
                  declare
                     Raw : constant String := (if Method = 0 then "abc" else
                       Character'Val (1) & Character'Val (3) & Character'Val (0) &
                       Character'Val (252) & Character'Val (255) & "abc");
                     Metadata : Zip.Headers.Local_File_Header := Header
                       (Raw, 3, Epub.Checksums.CRC32 ("abc"), Method);
                     Source : Zip_Streams.Memory_Zipstream;
                  begin
                     Source.Set (To_Unbounded_String (Prefix & Raw & Following));
                     Source.Set_Index (17);
                     declare
                        Result : constant String := Epub.Inflate.Decode (Source, Metadata);
                     begin
                        Assert (Result = "abc" and then Source.Index = Prefix'Length + Raw'Length + 1,
                                "Decoder refills stop at the declared payload boundary");
                     end;
                     Metadata.dd.compressed_size := Metadata.dd.compressed_size - 1;
                     Source.Set_Index (17);
                     begin
                        declare
                           Result : constant String := Epub.Inflate.Decode (Source, Metadata);
                        begin
                           Assert (Source.Index <= Prefix'Length + Raw'Length, "No refill crosses a truncated boundary");
                           Assert (False, "Following archive bytes cannot repair a truncated payload: " & Result'Length'Image);
                        end;
                     exception
                        when Epub.Inflate.Invalid_Stream => null;
                     end;
                     Assert (Source.Index <= Prefix'Length + Raw'Length, "Rejected input stays within its entry");
                  end;
               end loop;
               declare
                  Source : Zip_Streams.Memory_Zipstream;
               begin
                  Source.Set (To_Unbounded_String (Following));
                  declare
                     Empty : constant String := Epub.Inflate.Decode (Source, Header ("", 0, Method => 0));
                  begin
                     Assert (Empty'Length = 0 and then Source.Index = 1, "Empty stored entries do not read following headers");
                  end;
               end;
            end;
         when Mutations =>
            declare
               Data : String (1 .. 8192);
               Random : Unsigned_32 := 16#4A17_C3F1#;
               Source, Compressed : Zip_Streams.Memory_Zipstream;
               CRC : Unsigned_32;
               Count : Zip.Zip_64_Data_Size_Type;
               Method : Unsigned_16;
               Storage : Unbounded_String;
            begin
               for Index in Data'Range loop
                  Random := Random * 1_664_525 + 1_013_904_223;
                  Data (Index) := Character'Val (Shift_Right (Random, 27));
               end loop;
               Source.Set (To_Unbounded_String (Data));
               Compressed.Set (Null_Unbounded_String);
               Zip.Compress.Compress_Data
                 (Source, Compressed, True, Data'Length, Zip.Compress.Deflate_0,
                  null, "", Zip.Compress.neutral, CRC, Count, Method);
               pragma Assert (Source.Index >= Data'Length + 1);
               Compressed.Get (Storage);
               Assert (Method = 8, "Mutation source is a DEFLATE stream");
               declare
                  Raw : constant String := Slice (Storage, 1, Natural (Count));
                  Metadata : constant Zip.Headers.Local_File_Header := Header (Raw, Data'Length, CRC);
                  Rejected : Natural := 0;
                  procedure Check (Bytes : String; Must_Reject : Boolean := False) is
                     Input : Zip_Streams.Memory_Zipstream;
                  begin
                     Input.Set (To_Unbounded_String (Bytes));
                     declare
                        Result : constant String := Epub.Inflate.Decode (Input, Metadata);
                     begin
                        pragma Assert (Input.Size >= Bytes'Length);
                        Assert (not Must_Reject and then Result = Data,
                                "Accepted mutations must preserve every source byte and CRC");
                     end;
                  exception
                     when Epub.Inflate.Invalid_Stream => Rejected := Rejected + 1;
                  end Check;
               begin
                  for Trial in 0 .. 127 loop
                     for Bit in 0 .. 7 loop
                        declare
                           Changed : String := Raw;
                           Position : constant Positive := 1 + Trial * (Raw'Length - 1) / 127;
                        begin
                           Changed (Position) := Character'Val
                             (Unsigned_32 (Character'Pos (Changed (Position))) xor Shift_Left (Unsigned_32'(1), Bit));
                           Check (Changed);
                        end;
                     end loop;
                  end loop;
                  for Trial in 0 .. 64 loop
                     Check (Raw (1 .. Trial * (Raw'Length - 1) / 64), Must_Reject => True);
                  end loop;
                  Assert (Rejected >= 65, "Truncated streams and corrupt payload mutations are rejected");
               end;
            end;
         when Differential | Compatibility_Method =>
            declare
               Data : String (1 .. 131_073);
               Random : Unsigned_32 := 16#71A8_D31F#;
               type Sizes is array (Positive range <>) of Natural;
               type Modes is (Owned, Fixed, Huffman_Only, Stored, Shrink);
               procedure Compare (Bytes : String; Mode : Modes) is
                  Source, Output : Zip_Streams.Memory_Zipstream;
                  CRC : Unsigned_32;
                  Length : Zip.Zip_64_Data_Size_Type;
                  Method : Unsigned_16;
                  Compressed : Unbounded_String;
               begin
                  Source.Set (To_Unbounded_String (Bytes));
                  Output.Set (Null_Unbounded_String);
                  if Mode = Owned then
                     Epub.Compression.Compress (Source, Output, Bytes'Length, False, CRC, Length, Method);
                  else
                     Zip.Compress.Compress_Data
                       (Source, Output, True, Bytes'Length,
                        (case Mode is when Fixed => Zip.Compress.Deflate_Fixed,
                         when Huffman_Only => Zip.Compress.Deflate_0,
                         when Shrink => Zip.Compress.Shrink_1, when others => Zip.Compress.Store),
                        null, "", Zip.Compress.neutral, CRC, Length, Method);
                  end if;
                  pragma Assert (Source.Index >= Bytes'Length + 1);
                  Output.Get (Compressed);
                  declare
                     Raw : constant String := Slice (Compressed, 1, Natural (Length));
                     Metadata : constant Zip.Headers.Local_File_Header := Header (Raw, Bytes'Length, CRC, Method);
                  begin
                     Assert (Decode (Raw, Metadata) = Bytes, "Owned decoder or method fallback reproduces input");
                     Assert (Decode (Raw, Metadata, Reference => True) = Bytes, "Independent compatibility decoder agrees");
                     if Mode = Shrink then
                        Assert (Method = 1, "Uncommon ZIP method exercises the retained compatibility path");
                     end if;
                  end;
               end Compare;
            begin
               if Item.Kind = Compatibility_Method then
                  Data := [others => 'a'];
                  Compare (Data, Shrink);
               else
                  for Pattern in 1 .. 3 loop
                     for Index in Data'Range loop
                        Random := Random * 1_664_525 + 1_013_904_223;
                        Data (Index) := Character'Val
                          ((case Pattern is when 1 => Natural (Shift_Right (Random, 24)),
                            when 2 => Index mod 13,
                            when others => (if (Index / 3000) mod 2 = 0 then Index mod 7 else Natural (Random and 255))));
                     end loop;
                     for Size of Sizes'[0, 1, 2, 3, 31, 32, 257, 258, 259, 4096, 32_767, 32_768,
                       32_769, 65_535, 65_536, 65_537, 131_073]
                     loop
                        for Mode in Owned .. Stored loop
                           Compare (Data (1 .. Size), Mode);
                        end loop;
                     end loop;
                  end loop;
               end if;
            end;
         when Long_Codes =>
            declare
               Bits : Writer;
               Payload : String (1 .. 15);
               Order : constant array (0 .. 18) of Natural :=
                 [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
            begin
               Put (Bits, 1, 1); Put (Bits, 2, 2); -- final dynamic block
               Put (Bits, 0, 5); Put (Bits, 0, 5); Put (Bits, 15, 4);
               for Symbol of Order loop
                  Put (Bits, (if Symbol <= 15 then 4 else 0), 3);
               end loop;
               for Symbol in 0 .. 256 loop
                  Code (Bits, (if Symbol < 14 then Unsigned_32 (Symbol + 1)
                               elsif Symbol in 14 | 256 then 15 else 0), 4);
               end loop;
               Code (Bits, 1, 4); -- one distance code, unused by this stream
               for Symbol in 0 .. 14 loop
                  Payload (Symbol + 1) := Character'Val (Symbol);
                  Code (Bits, (if Symbol = 14 then 32_766 else 2 ** (Symbol + 1) - 2),
                        (if Symbol = 14 then 15 else Symbol + 1));
               end loop;
               Code (Bits, 32_767, 15); -- end of block
               declare
                  Raw : constant String := Finish (Bits);
                  Metadata : constant Zip.Headers.Local_File_Header := Header
                    (Raw, Payload'Length, Epub.Checksums.CRC32 (Payload));
               begin
                  Assert (Decode (Raw, Metadata) = Payload, "Codes of lengths ten through fifteen use the slow lookup path");
                  Assert (Decode (Raw, Metadata, Reference => True) = Payload, "Independent long-code decoding");
               end;
            end;
         when Malformed =>
            Reject ("");
            Reject ([1 => Character'Val (7)]); -- reserved block type
            Reject ([1 => Character'Val (3)]); -- truncated fixed EOB
            Reject (Character'Val (1) & Character'Val (3) & Character'Val (0) &
                    Character'Val (0) & Character'Val (0) & "abc", 3); -- bad LEN complement
            Reject ("abc", 4, 0); -- stored size mismatch
            Reject ("abc", 3, 0); -- bad CRC
            Reject (Character'Val (1) & Character'Val (3) & Character'Val (0) &
                    Character'Val (252) & Character'Val (255) & "abc", 2); -- output overflow
            Reject (Character'Val (1) & Character'Val (3) & Character'Val (0) &
                    Character'Val (252) & Character'Val (255) & "abc", 4); -- output underflow
            Reject ("", Unsigned_64 (Natural'Last) + 1); -- reject before allocation
            Reject (Character'Val (3) & Character'Val (0), 1_000_000); -- impossible expansion claim
            for Variant in 0 .. 7 loop
               declare
                  Bits : Writer;
               begin
                  Put (Bits, 1, 1);
                  if Variant <= 2 then
                     Put (Bits, 1, 2);
                     if Variant = 0 then
                        Code (Bits, 16#C6#, 8); -- reserved literal 286
                     else
                        Code (Bits, 1, 7); -- length three
                        Code (Bits, (if Variant = 1 then 30 else 0), 5);
                     end if;
                  else
                     Put (Bits, 2, 2);
                     Put (Bits, 0, 5); Put (Bits, 0, 5); Put (Bits, 0, 4);
                     case Variant is
                        when 3 => -- empty code-length tree
                           for Index in 1 .. 4 loop Put (Bits, 0, 3); end loop;
                        when 4 => -- oversubscribed code-length tree
                           for Index in 1 .. 4 loop Put (Bits, 1, 3); end loop;
                        when 5 => -- incomplete code-length tree
                           Put (Bits, 1, 3); Put (Bits, 0, 9);
                        when 6 => -- repeat 16 before the first length
                           Put (Bits, 1, 3); Put (Bits, 0, 3); Put (Bits, 1, 3); Put (Bits, 0, 3);
                           Code (Bits, 0, 1);
                        when others => -- repeated zeros exceed the alphabet
                           Put (Bits, 0, 3); Put (Bits, 0, 3); Put (Bits, 1, 3); Put (Bits, 1, 3);
                           Code (Bits, 1, 1); Put (Bits, 127, 7);
                           Code (Bits, 1, 1); Put (Bits, 127, 7);
                     end case;
                  end if;
                  Reject (Finish (Bits), (if Variant in 1 .. 2 then 3 else 0));
               end;
            end loop;
      end case;
   end Run_Test;
end Inflate_Cases;

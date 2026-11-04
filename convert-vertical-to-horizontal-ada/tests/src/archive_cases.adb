with Ada.Directories;
with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with Epub.Archives;
with Epub.Books;
with Epub.Classification;
with Interfaces;
with Test_Files;
with Zip_Streams;
with Zip.CRC_Crypto;
with Epub.Files;
with GNAT.SHA256;
with Epub.Files.Write_Stream_Checked;
with Epub.Hash_Streams;

package body Archive_Cases is
   use AUnit.Assertions;
   use type Ada.Exceptions.Exception_Id;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_64;
   use type Epub.Classification.Layout;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind)
      return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Archive: " & Item.Kind'Image));

   function Synthetic (Force64 : Boolean := False) return Epub.Archives.Catalogue is
      Result : Epub.Archives.Catalogue;
      Text : constant String (1 .. 4096) := [others => 'a'];
      Page : Epub.Archives.Member := Epub.Archives.Create_Member
        ("OPS/page.xhtml", Text, 16#81A4_0020#);
   begin
      Result.Append (Epub.Archives.Create_Member ("mimetype", "application/epub+zip"));
      Page.Header.short_info.file_timedate :=
        Zip_Streams.Calendar.Convert (Interfaces.Unsigned_32'(16#5678_4321#));
      Page.Was_Zip64 := Force64;
      Result.Append (Page);
      return Result;
   end Synthetic;

   function Header_Position (Bytes : String; Central : Boolean; Ordinal : Positive := 1)
      return Positive is
      Signature : constant String := "PK" &
        (if Central then Character'Val (1) & Character'Val (2)
         else Character'Val (3) & Character'Val (4));
      Found : Natural := 0;
      Start : Positive := Bytes'First;
   begin
      for Count in 1 .. Ordinal loop
         Found := Ada.Strings.Fixed.Index (Bytes, Signature, Start);
         Assert (Found /= 0, "Synthetic ZIP header is present");
         Start := Found + 1;
      end loop;
      return Found;
   end Header_Position;

   procedure Set_Number (Bytes : in out String; Position, Width : Positive;
                         Value : Interfaces.Unsigned_64) is
      Remaining : Interfaces.Unsigned_64 := Value;
   begin
      for Offset in 0 .. Width - 1 loop
         Bytes (Position + Offset) := Character'Val (Remaining mod 256);
         Remaining := Remaining / 256;
      end loop;
      Assert (Remaining = 0, "Mutation value fits the ZIP field");
   end Set_Number;

   function Descriptor_Archive (Signed, Force64 : Boolean) return String is
      Original : constant String := Epub.Archives.Rebuild (Synthetic (Force64));
      Expected : constant Epub.Archives.Catalogue := Epub.Archives.Read (Original);
      Central_Start : constant Positive := Header_Position (Original, True);
      Width : constant Positive := (if Force64 then 8 else 4);
      CRC_Position : constant Positive := (if Signed then 5 else 1);
      Descriptor : String (1 .. CRC_Position - 1 + 4 + 2 * Width) := [others => Character'Val (0)];
   begin
      if Signed then
         Descriptor (1 .. 4) := "PK" & Character'Val (7) & Character'Val (8);
      end if;
      Set_Number (Descriptor, CRC_Position, 4,
        Interfaces.Unsigned_64 (Expected (2).Header.short_info.dd.crc_32));
      Set_Number (Descriptor, CRC_Position + 4, Width, Expected (2).Header.short_info.dd.compressed_size);
      Set_Number (Descriptor, CRC_Position + 4 + Width, Width, Expected (2).Header.short_info.dd.uncompressed_size);
      declare
         Bytes : String := Original (1 .. Central_Start - 1) & Descriptor & Original (Central_Start .. Original'Last);
         Local_Position : constant Positive := Header_Position (Bytes, False, 2);
         Central : constant Positive := Header_Position (Bytes, True, 2);
         Ending : constant Natural := Ada.Strings.Fixed.Index
           (Bytes, "PK" & Character'Val (5) & Character'Val (6));
      begin
         Set_Number (Bytes, Local_Position + 6, 2, 8);
         Set_Number (Bytes, Central + 8, 2, 8);
         Set_Number (Bytes, Local_Position + 14, 4, 0);
         if Force64 then
            declare
               Extended_End : constant Natural := Ada.Strings.Fixed.Index
                 (Bytes, "PK" & Character'Val (6) & Character'Val (6));
               Locator : constant Natural := Ada.Strings.Fixed.Index
                 (Bytes, "PK" & Character'Val (6) & Character'Val (7));
               Extra_Values : constant Positive := Local_Position + 30 +
                 Ada.Strings.Unbounded.Length (Expected (2).Raw_Name) + 4;
            begin
               Assert (Extended_End > 0 and then Locator > 0, "ZIP64 ending exists");
               Set_Number (Bytes, Extra_Values, 8, 0);
               Set_Number (Bytes, Extra_Values + 8, 8, 0);
               Set_Number (Bytes, Extended_End + 48, 8,
                 Interfaces.Unsigned_64 (Central_Start - 1 + Descriptor'Length));
               Set_Number (Bytes, Locator + 8, 8, Interfaces.Unsigned_64 (Extended_End - 1));
            end;
         else
            Set_Number (Bytes, Local_Position + 18, 4, 0);
            Set_Number (Bytes, Local_Position + 22, 4, 0);
            Assert (Ending > 0, "ZIP ending exists");
            Set_Number (Bytes, Ending + 16, 4,
              Interfaces.Unsigned_64 (Central_Start - 1 + Descriptor'Length));
         end if;
         return Bytes;
      end;
   end Descriptor_Archive;

   procedure Reject (Bytes, Description : String; Expected_Message : String := "") is
      Rejected : Boolean := False;
      Accepted_Count : Natural := 0;
   begin
      begin
         declare
            Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Bytes);
         begin
            Accepted_Count := Actual.Last_Index;
         end;
      exception
         when Error : others =>
            Rejected := True;
            if Expected_Message /= "" then
               Assert (Ada.Exceptions.Exception_Identity (Error) = Epub.Archives.Invalid_Archive'Identity,
                 "Expected archive structure error: " & Ada.Exceptions.Exception_Name (Error));
               Assert (Ada.Strings.Fixed.Index (Ada.Exceptions.Exception_Message (Error), Expected_Message) > 0,
                 "Expected archive diagnostic: " & Expected_Message);
            end if;
      end;
      Assert (Rejected, Description & "; accepted entries:" & Accepted_Count'Image);
   end Reject;

   procedure Header_Mutations is
      Original : constant String := Epub.Archives.Rebuild (Synthetic);
      type Field_Positions is array (Positive range <>) of Positive;
      Fields : constant Field_Positions := [7, 9, 11, 15, 19, 23, 31];
   begin
      for Field of Fields loop
         declare
            Bytes : String := Original;
         begin
            Bytes (Field) := Character'Val ((Character'Pos (Bytes (Field)) + 1) mod 256);
            Reject (Bytes, "Inconsistent local field" & Field'Image);
         end;
      end loop;
      for Invalid_Name in 0 .. 1 loop
         declare
            Bytes : String := Original;
            Central : constant Positive := Header_Position (Bytes, True);
         begin
            if Invalid_Name = 0 then
               Bytes (31) := Character'Val (0);
               Bytes (Central + 46) := Character'Val (0);
            else
               Set_Number (Bytes, 7, 2, 16#800#);
               Set_Number (Bytes, Central + 8, 2, 16#800#);
               Bytes (31 .. 32) := Character'Val (16#C0#) & Character'Val (16#AF#);
               Bytes (Central + 46 .. Central + 47) := Bytes (31 .. 32);
            end if;
            Reject (Bytes, "Invalid ZIP name");
         end;
      end loop;
   end Header_Mutations;

   procedure Zip64_Mutations is
      Items : constant Epub.Archives.Catalogue := Synthetic (True);
      Original : constant String := Epub.Archives.Rebuild (Items);
      Name_Length : constant Natural := Ada.Strings.Unbounded.Length (Items (2).Raw_Name);
   begin
      for Mutation in 1 .. 7 loop
         declare
            Bytes : String := Original;
            Local_Position : constant Positive := Header_Position (Bytes, False, 2);
            Central : constant Positive := Header_Position (Bytes, True, 2);
            Local_Extra : constant Positive := Local_Position + 30 + Name_Length;
            Central_Extra : constant Positive := Central + 46 + Name_Length;
         begin
            case Mutation is
               when 1 => Set_Number (Bytes, Local_Extra + 2, 2, 8);
               when 2 => Set_Number (Bytes, Local_Extra + 2, 2, 0);
               when 3 => Set_Number (Bytes, Local_Extra, 2, 2);
               when 4 => Set_Number (Bytes, Local_Position + 28, 2, 0);
               when 5 => Set_Number (Bytes, Central_Extra + 2, 2, 16);
               when 6 => Set_Number (Bytes, Central_Extra, 2, 2);
               when 7 => Set_Number (Bytes, Central_Extra + 2, 2, 29);
            end case;
            Reject (Bytes, "Malformed ZIP64 field" & Mutation'Image);
         end;
      end loop;
   end Zip64_Mutations;

   procedure Region_Mutations is
      Original : constant String := Epub.Archives.Rebuild (Synthetic);
   begin
      for Mutation in 1 .. 8 loop
         declare
            Bytes : String := Original;
            Central : constant Positive := Header_Position (Bytes, True);
         begin
            case Mutation is
               when 1 => Set_Number (Bytes, Central + 42, 4, 16#FFFF_FFFE#);
               when 2 =>
                  Set_Number (Bytes, 19, 4, 16#FFFF_FFFE#);
                  Set_Number (Bytes, Central + 20, 4, 16#FFFF_FFFE#);
               when 3 => Set_Number (Bytes, Central + 28, 2, 16#FFFF#);
               when 4 => Set_Number (Bytes, Central + 30, 2, 16#FFFF#);
               when 5 => Set_Number (Bytes, Central + 32, 2, 16#FFFF#);
               when 6 | 7 =>
                  Set_Number (Bytes, 23, 4, (if Mutation = 6 then 19 else 21));
                  Set_Number (Bytes, Central + 24, 4, (if Mutation = 6 then 19 else 21));
               when 8 =>
                  Set_Number (Bytes, 9, 2, 16#FFFF#);
                  Set_Number (Bytes, Central + 10, 2, 16#FFFF#);
            end case;
            Reject (Bytes, "ZIP structure outside containing region" & Mutation'Image);
         end;
      end loop;
      for Cut in 1 .. 30 loop
         Reject (Original (1 .. Cut), "Truncated ZIP header");
      end loop;
   end Region_Mutations;

   procedure Descriptor_Tests is
   begin
      for Force64 in Boolean loop
         for Signed in Boolean loop
            declare
               Original : constant String := Descriptor_Archive (Signed, Force64);
               Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Original);
               Width : constant Positive := (if Force64 then 8 else 4);
               Descriptor_Length : constant Positive := 4 + 2 * Width + (if Signed then 4 else 0);
               Descriptor_Start : constant Positive := Header_Position (Original, True) - Descriptor_Length;
               CRC_Position : constant Positive := Descriptor_Start + (if Signed then 4 else 0);
            begin
               Assert (Actual.Last_Index = 2 and then
                 Ada.Strings.Unbounded.Length (Actual (2).Payload) = 4096,
                 "Signed/unsigned and ZIP32/ZIP64 data descriptors");
               for Field in 0 .. 2 loop
                  declare
                     Bytes : String := Original;
                     Position : constant Positive := CRC_Position +
                       (case Field is when 0 => 0, when 1 => 4, when 2 => 4 + Width);
                  begin
                     Bytes (Position) := Character'Val ((Character'Pos (Bytes (Position)) + 1) mod 256);
                     Reject (Bytes, "Data descriptor field corruption" & Field'Image);
                  end;
               end loop;
               declare
                  Bytes : String := Original;
                  Local_Position : constant Positive := Header_Position (Bytes, False, 2);
               begin
                  Set_Number (Bytes, Local_Position + 14, 4, 1);
                  Reject (Bytes, "Invalid local data-descriptor placeholder");
               end;
            end;
         end loop;
      end loop;
      declare
         Bytes : String := Epub.Archives.Rebuild (Synthetic);
         Local_Position : constant Positive := Header_Position (Bytes, False, 2);
         Central : constant Positive := Header_Position (Bytes, True, 2);
      begin
         Set_Number (Bytes, Local_Position + 6, 2, 8);
         Set_Number (Bytes, Central + 8, 2, 8);
         Reject (Bytes, "Missing required data descriptor");
      end;
   end Descriptor_Tests;

   procedure Duplicate_Extra_Test is
      Original : constant String := Epub.Archives.Rebuild (Synthetic);
      Central : constant Positive := Header_Position (Original, True);
      Insert_At : constant Positive := Central + 46 + String'("mimetype")'Length;
      Extra : constant String := Character'Val (1) & Character'Val (0) &
        Character'Val (0) & Character'Val (0);
      Bytes : String := Original (1 .. Insert_At - 1) & Extra & Extra & Original (Insert_At .. Original'Last);
      Ending : constant Natural := Ada.Strings.Fixed.Index
        (Bytes, "PK" & Character'Val (5) & Character'Val (6));
   begin
      Assert (Ending > 0, "ZIP ending exists after extra-field insertion");
      Set_Number (Bytes, Central + 30, 2, 8);
      Set_Number (Bytes, Ending + 12, 4, Interfaces.Unsigned_64 (Ending - Central));
      Reject (Bytes, "Duplicate ZIP64 extra fields", "Duplicate ZIP64");
   end Duplicate_Extra_Test;

   procedure Overlap_Test is
      Bytes : String := Epub.Archives.Rebuild (Synthetic);
      Central : constant Positive := Header_Position (Bytes, True);
      Payload_First : constant Positive := 31 + String'("mimetype")'Length;
      Size : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Central - Payload_First);
      Buffer : Zip.Byte_Buffer (Payload_First .. Central - 1);
      CRC : Interfaces.Unsigned_32;
   begin
      for Position in Buffer'Range loop
         Buffer (Position) := Character'Pos (Bytes (Position));
      end loop;
      Zip.CRC_Crypto.Init (CRC);
      Zip.CRC_Crypto.Update (CRC, Buffer);
      Set_Number (Bytes, 15, 4, Interfaces.Unsigned_64 (Zip.CRC_Crypto.Final (CRC)));
      Set_Number (Bytes, Central + 16, 4, Interfaces.Unsigned_64 (Zip.CRC_Crypto.Final (CRC)));
      Set_Number (Bytes, 19, 4, Size);
      Set_Number (Bytes, 23, 4, Size);
      Set_Number (Bytes, Central + 20, 4, Size);
      Set_Number (Bytes, Central + 24, 4, Size);
      Reject (Bytes, "Stored entry encompasses the next local entry", "Overlapping ZIP entries");
   end Overlap_Test;

   procedure Fixtures (Convert_Books : Boolean := False) is
      Root : constant String := "../../convert-vertical-to-horizontal-perl/t/fixtures/input";
      Destination : constant String :=
        (if Convert_Books then "../test-results/book-parity" else "../test-results/archive-roundtrip");
      Search : Ada.Directories.Search_Type;
      Directory_Item : Ada.Directories.Directory_Entry_Type;
      Count : Natural := 0;
   begin
      Ada.Directories.Create_Path (Destination);
      Ada.Directories.Start_Search (Search, Root, "*.epub");
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Directory_Item);
         declare
            Filename : constant String := Ada.Directories.Simple_Name (Directory_Item);
            Source : constant String := Test_Files.Read
              (Ada.Directories.Full_Name (Directory_Item));
            Original : constant Epub.Archives.Catalogue := Epub.Archives.Read (Source);
         begin
            if Convert_Books then
               declare
                  Expected : constant Epub.Archives.Catalogue := Epub.Archives.Read
                    (Test_Files.Read ("../../convert-vertical-to-horizontal-perl/t/fixtures/expected/" & Filename));
                  Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Original);
                  Patched : constant Epub.Archives.Catalogue := Epub.Books.Apply (Original, Plan);
                  Output : constant String :=
                    (if Plan.Reason = Epub.Classification.Vertical_Text
                     then Epub.Archives.Rebuild (Patched) else Source);
                  Second_Plan : constant Epub.Books.Book_Plan :=
                    Epub.Books.Analyze_Book (Epub.Archives.Read (Output));
               begin
                  Epub.Archives.Verify (Output, Expected);
                  Assert (Second_Plan.Reason /= Epub.Classification.Vertical_Text,
                          "Second pass must preserve: " & Filename);
                  Assert (Second_Plan.Patches.Is_Empty, "No second-pass edits: " & Filename);
                  Test_Files.Write (Ada.Directories.Compose (Destination, Filename), Output);
               end;
            else
               declare
                  Output : constant String := Epub.Archives.Rebuild (Original);
               begin
                  Epub.Archives.Verify (Output, Original);
                  Test_Files.Write (Ada.Directories.Compose (Destination, Filename), Output);
               end;
            end if;
            Count := Count + 1;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      Assert (Count = 21, "All 21 reference archives must be exercised");
   exception
      when others =>
         Ada.Directories.End_Search (Search);
         raise;
   end Fixtures;

   overriding procedure Run_Test (Item : in out Unit_Case) is
   begin
      case Item.Kind is
         when Codec_Buffer_Boundaries =>
            declare
               use type Interfaces.Unsigned_32;
               Payload : String (1 .. 1_000_000);
               Random : Interfaces.Unsigned_32 := 16#D1CE_8703#;
               Original : Epub.Archives.Catalogue;
            begin
               for Index in Payload'Range loop
                  Random := Random * 1_664_525 + 1_013_904_223;
                  Payload (Index) := Character'Val
                    ((if (Index / 70_000) mod 2 = 0 then Natural (Interfaces.Shift_Right (Random, 24))
                      else Index mod 31));
               end loop;
               Original.Append (Epub.Archives.Create_Member ("mimetype", "application/epub+zip"));
               Original.Append (Epub.Archives.Create_Member ("OPS/payload.bin", Payload));
               declare
                  Bytes : constant String := Epub.Archives.Rebuild (Original);
                  Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Bytes);
               begin
                  Assert (Actual (2).Header.short_info.zip_type = 8, "Mixed payload retains DEFLATE output");
                  Assert (Bytes'Length < Payload'Length - 100_000, "Compressible regions prevent whole-stream stored fallback");
                  Assert (Epub.Archives.Contents (Actual, "OPS/payload.bin") = Payload,
                          "Circular token wraps and stored-block short expansions reproduce every byte");
                  Epub.Archives.Verify (Bytes, Original);
               end;
            end;
         when File_Backed_Catalogue =>
            declare
               use Ada.Strings.Unbounded;
               Path : constant String := "../test-results/source-catalogue.epub";
               Bytes : String := Epub.Archives.Rebuild (Synthetic (True));
               function Surviving_Copy return Epub.Archives.Catalogue is
                  Original : constant Epub.Archives.Catalogue := Epub.Archives.Read_File (Path);
                  Copy : constant Epub.Archives.Catalogue := Original;
               begin
                  return Copy;
               end Surviving_Copy;
            begin
               Epub.Files.Remove (Path);
               Epub.Files.Write_Exclusive (Path, Bytes);
               declare
                  Original : constant Epub.Archives.Catalogue := Surviving_Copy;
                  Plan : Epub.Books.Book_Plan;
                  Stream : Zip_Streams.Memory_Zipstream;
                  Copied : Unbounded_String;
               begin
                  Assert (not Original (2).Payload_Loaded and then Length (Original (2).Payload) = 0,
                          "Catalogue owns a source reference instead of decoded payload bytes");
                  Assert (Epub.Archives.Contents (Original, "OPS/page.xhtml") = [1 .. 4096 => 'a'],
                          "Payload remains available after intermediate owners finalize");
                  Assert (Epub.Archives.Source_Size (Original) = Bytes'Length, "Exact file size");
                  Assert (Epub.Archives.Source_Digest (Original) =
                    Ada.Characters.Handling.To_Upper (GNAT.SHA256.Digest (Bytes)), "Streaming source digest");
                  Stream.Set (Null_Unbounded_String);
                  Epub.Archives.Copy_Source (Original, Stream);
                  Stream.Get (Copied);
                  Assert (To_String (Copied) = Bytes, "Exact-copy source streaming");
                  Epub.Archives.Verify (Epub.Archives.Rebuild (Original), Original);
                  Plan.Patches.Append ((To_Unbounded_String ("OPS/page.xhtml"), To_Unbounded_String ("changed")));
                  declare
                     Patched : constant Epub.Archives.Catalogue := Epub.Books.Apply (Original, Plan);
                  begin
                     Assert (Patched (2).Payload_Loaded, "Edits materialize their replacement");
                     Epub.Archives.Verify (Epub.Archives.Rebuild (Patched), Patched);
                     Assert (Epub.Archives.Contents (Original, "OPS/page.xhtml") = [1 .. 4096 => 'a'],
                             "Applying edits does not mutate the shared source");
                  end;
               end;
               Epub.Files.Remove (Path);
               Bytes (39) := 'X';
               Epub.Files.Write_Exclusive (Path, Bytes);
               begin
                  declare
                     Invalid : constant Epub.Archives.Catalogue := Epub.Archives.Read_File (Path);
                  begin
                     Assert (Invalid.Is_Empty, "Corrupt source must be rejected before returning a catalogue");
                  end;
                  Assert (False, "File-backed loading retains CRC validation for every entry");
               exception
                  when AUnit.Assertions.Assertion_Error => raise;
                  when others => null;
               end;
               Epub.Files.Remove (Path);
            end;
         when Streaming_Publication =>
            declare
               use Ada.Strings.Unbounded;
               Expected : constant Epub.Archives.Catalogue := Synthetic;
               Destination : constant String := "../test-results/stream-published.epub";
               type Failure_Kind is (None, Build_Failure, Bad_Digest, Verify_Failure, Publication_Race);
               Failure : Failure_Kind := None;
               Checked : Natural := 0;
               procedure Build
                 (Output : in out Zip_Streams.Root_Zipstream_Type'Class; Digest : out Unbounded_String) is
                  Hashed : Epub.Hash_Streams.Stream (Output'Access);
               begin
                  Epub.Archives.Rebuild (Expected, Hashed);
                  if Failure = Build_Failure then
                     raise Epub.Files.File_Error with "injected build failure";
                  end if;
                  Digest := To_Unbounded_String ((if Failure = Bad_Digest then [1 .. 64 => '0'] else Hashed.Digest));
               end Build;
               procedure Check (Input : in out Zip_Streams.Root_Zipstream_Type'Class) is
               begin
                  Checked := Checked + 1;
                  Epub.Archives.Verify (Input, Expected);
                  if Failure = Verify_Failure then
                     raise Epub.Files.File_Error with "injected verification failure";
                  elsif Failure = Publication_Race then
                     Epub.Files.Write_Exclusive (Destination, "racer");
                  end if;
               end Check;
               procedure Save is new Epub.Files.Write_Stream_Checked (Build, Check);
               Bytes : Interfaces.Unsigned_64 := 0;
               Digest : Unbounded_String;
               Rejected : Boolean;
            begin
               for Mode in Failure_Kind loop
                  Failure := Mode;
                  Checked := 0;
                  Rejected := False;
                  Epub.Files.Remove (Destination);
                  begin
                     Save (Destination, Bytes, Digest);
                  exception
                     when others => Rejected := True;
                  end;
                  Assert (Rejected = (Mode /= None), "Streaming failure blocks publication");
                  Assert (Checked = (if Mode in Build_Failure | Bad_Digest then 0 else 1),
                          "Persisted verification occurs exactly once, after digest verification");
                  if Mode = None then
                     Assert (Bytes = Epub.Files.Read (Destination)'Length, "Published length");
                     Assert (To_String (Digest) = Ada.Characters.Handling.To_Upper
                       (GNAT.SHA256.Digest (Epub.Files.Read (Destination))), "Published digest");
                     begin
                        Save (Destination, Bytes, Digest);
                        Assert (False, "Streaming publication refuses an existing destination");
                     exception
                        when Epub.Files.File_Error => null;
                     end;
                  elsif Mode = Publication_Race then
                     Assert (Epub.Files.Read (Destination) = "racer", "Publication race cannot replace the winner");
                  else
                     Assert (not Epub.Files.Exists (Destination), "Failed output remains unpublished");
                  end if;
                  Epub.Files.Remove (Destination);
               end loop;
            end;
         when Persisted_Verification | Persisted_Corruption | Reused_Digest =>
            declare
               Expected : constant Epub.Archives.Catalogue := Synthetic;
               Bytes : String := Epub.Archives.Rebuild (Expected);
               Root : Ada.Strings.Unbounded.Unbounded_String;
               Sequence : Natural := 0;
               Calls : Natural := 0;
               Rejected : Boolean := False;
               procedure Check_Saved (Saved : String) is
               begin
                  Calls := Calls + 1;
                  Epub.Archives.Verify (Saved, Expected);
               end Check_Saved;
               procedure Save is new Epub.Files.Write_Checked (Check_Saved);
            begin
               loop
                  Sequence := Sequence + 1;
                  Root := Ada.Strings.Unbounded.To_Unbounded_String
                    ("../test-results/persisted-" & Sequence'Image);
                  exit when not Epub.Files.Exists (Ada.Strings.Unbounded.To_String (Root));
               end loop;
               Epub.Files.Ensure_Directory (Ada.Strings.Unbounded.To_String (Root));
               declare
                  Destination : constant String := Epub.Files.Join
                    (Ada.Strings.Unbounded.To_String (Root), "result.epub");
               begin
                  if Item.Kind = Persisted_Corruption then
                     Bytes (39) := 'X';
                  end if;
                  begin
                     if Item.Kind = Reused_Digest then
                        Save (Destination, Bytes, GNAT.SHA256.Digest (Bytes));
                     else
                        Save (Destination, Bytes);
                     end if;
                  exception
                     when others => Rejected := True;
                  end;
                  Assert (Calls = 1, "Exactly one persisted archive verification");
                  Assert (Rejected = (Item.Kind = Persisted_Corruption), "Corruption blocks publication");
                  Assert (Epub.Files.Exists (Destination) = not Rejected, "Publication eligibility");
                  if not Rejected then
                     Assert (Epub.Files.Read (Destination) = Bytes, "Verified bytes published");
                  end if;
                  if Item.Kind = Reused_Digest then
                     Rejected := False;
                     begin
                        Save (Destination & ".bad", Bytes, [1 .. 64 => '0']);
                     exception
                        when Epub.Files.File_Error => Rejected := True;
                     end;
                     Assert (Rejected and then Calls = 1, "Incorrect reused digest rejected before callback");
                     Assert (not Epub.Files.Exists (Destination & ".bad"), "Incorrect digest never published");
                  end if;
                  declare
                     Search : Ada.Directories.Search_Type;
                  begin
                     Ada.Directories.Start_Search
                       (Search, Ada.Strings.Unbounded.To_String (Root), ".epub-horizontal-*.tmp");
                     Assert (not Ada.Directories.More_Entries (Search), "Temporary output cleaned");
                     Ada.Directories.End_Search (Search);
                  end;
               end;
            end;
         when Mimetype_Flags =>
            declare
               Flag_Values : constant array (1 .. 2) of Interfaces.Unsigned_64 :=
                 [16#0800#, 16#0816#];
            begin
               for Flags of Flag_Values loop
                  declare
                     Bytes : String := Epub.Archives.Rebuild (Synthetic);
                  begin
                     Set_Number (Bytes, Header_Position (Bytes, False) + 6, 2, Flags);
                     Set_Number (Bytes, Header_Position (Bytes, True) + 8, 2, Flags);
                     declare
                        Original : constant Epub.Archives.Catalogue := Epub.Archives.Read (Bytes);
                        Rebuilt : constant String := Epub.Archives.Rebuild (Original);
                        Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Rebuilt);
                     begin
                        Epub.Archives.Verify (Rebuilt, Original);
                        Assert (Actual (1).Header.short_info.bit_flag = 0,
                          "Rebuilt mimetype has no inherited flags");
                     end;
                  end;
               end loop;
            end;
         when Header_Consistency => Header_Mutations;
         when ZIP64_Field_Bounds => Zip64_Mutations;
         when Archive_Region_Bounds => Region_Mutations;
         when Data_Descriptors => Descriptor_Tests;
         when Duplicate_ZIP64_Fields => Duplicate_Extra_Test;
         when Entry_Overlap => Overlap_Test;
         when Case_Sensitive_Names =>
            declare
               Original : Epub.Archives.Catalogue := Synthetic;
            begin
               Original.Append (Epub.Archives.Create_Member ("OPS/A.css", "upper"));
               Original.Append (Epub.Archives.Create_Member ("OPS/a.css", "lower"));
               declare
                  Actual : constant Epub.Archives.Catalogue :=
                    Epub.Archives.Read (Epub.Archives.Rebuild (Original));
               begin
                  Assert (Epub.Archives.Find (Actual, "OPS/A.css") = 3, "Uppercase name lookup");
                  Assert (Epub.Archives.Find (Actual, "OPS/a.css") = 4, "Lowercase name lookup");
                  Assert (Epub.Archives.Contents (Actual, "OPS/A.css") = "upper", "Distinct payloads");
               end;
            end;
         when Metadata_Roundtrip | Zip64_Roundtrip =>
            declare
               Original : constant Epub.Archives.Catalogue := Synthetic (Item.Kind = Zip64_Roundtrip);
               Bytes : constant String := Epub.Archives.Rebuild (Original);
               Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Bytes);
            begin
               Epub.Archives.Verify (Bytes, Original);
               Assert (Actual (2).Header.short_info.zip_type = 8, "Compress repeated payload with DEFLATE");
               Assert (Actual (2).Was_Zip64 = (Item.Kind = Zip64_Roundtrip), "Preserve forced ZIP64 structure");
               Assert (Bytes (1 .. 4) = "PK" & Character'Val (3) & Character'Val (4), "Local header signature");
               Assert (Bytes (29 .. 30) = Character'Val (0) & Character'Val (0), "Mimetype local extra is empty");
            end;
         when Unicode_And_Empty =>
            declare
               Original : Epub.Archives.Catalogue := Synthetic;
               Unicode_Name : constant String := "OPS/" & Character'Val (16#E6#) &
                 Character'Val (16#97#) & Character'Val (16#A5#) & ".css";
            begin
               Original.Append (Epub.Archives.Create_Member (Unicode_Name, "x"));
               Original.Append (Epub.Archives.Create_Member ("OPS/empty/", "", 16#10#));
               declare
                  Bytes : constant String := Epub.Archives.Rebuild (Original);
                  Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Bytes);
               begin
                  Assert (Epub.Archives.Find (Actual, Unicode_Name) = 3, "Unicode entry name and order");
                  Assert (Epub.Archives.Contents (Actual, "OPS/empty/") = "", "Empty directory payload");
               end;
            end;
         when Corrupt_Payload =>
            declare
               Bytes : String := Epub.Archives.Rebuild (Synthetic);
               Rejected : Boolean := False;
               Accepted_Count : Natural := 0;
            begin
               Bytes (39) := 'X';
               begin
                  declare
                     Actual : constant Epub.Archives.Catalogue := Epub.Archives.Read (Bytes);
                  begin
                     Accepted_Count := Actual.Last_Index;
                  end;
               exception
                  when others =>
                     Rejected := True;
               end;
               Assert (Rejected and then Accepted_Count = 0, "CRC-corrupt payload must fail");
            end;
         when Fixture_Roundtrips =>
            Fixtures;
         when Book_Payload_Parity =>
            Fixtures (Convert_Books => True);
      end case;
   end Run_Test;
end Archive_Cases;

with Ada.Streams;
with AUnit.Assertions;
with Epub.File_Streams;
with Epub.Files;
with Zip_Streams;
with Ada.IO_Exceptions;
with Epub.Hash_Streams;
with Epub.Stream_IO;
with Ada.Characters.Handling;
with GNAT.SHA256;
with Epub.String_Streams;
with Epub.Archive_Sources;
with Ada.Strings.Unbounded;

package body Stream_Cases is
   use AUnit.Assertions;
   use Ada.Streams;
   use type Zip_Streams.ZS_Size_Type;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("File stream: " & Item.Kind'Image));

   overriding procedure Run_Test (Item : in out Unit_Case) is
      Path : constant String := "stream-test-" & Item.Kind'Image & ".bin";
      Output : Epub.File_Streams.Stream;
      Input : Epub.File_Streams.Stream;
      procedure Expect_Write_Rejected is
      begin
         Input.Write ([1 => 42]);
         Assert (False, "Read-only stream must reject writes");
      exception
         when Epub.File_Streams.File_Error => null;
      end Expect_Write_Rejected;
   begin
      Epub.Files.Remove (Path);
      case Item.Kind is
         when Source_Ranges =>
            declare
               Data : String (1 .. 131_090);
            begin
               for Index in Data'Range loop
                  Data (Index) := Character'Val (Index mod 251);
               end loop;
               Epub.Files.Write_Exclusive (Path, Data);
               declare
                  Source : constant Epub.Archive_Sources.Reference := Epub.Archive_Sources.Open (Path);
                  Target : Zip_Streams.Memory_Zipstream;
                  Copied : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  Target.Set (Ada.Strings.Unbounded.Null_Unbounded_String);
                  Epub.Archive_Sources.Copy_Range (Source, 17, 131_073, Target);
                  Target.Get (Copied);
                  Assert (Ada.Strings.Unbounded.To_String (Copied) = Data (17 .. 131_089),
                          "Bounded source copy crosses two full chunks and a one-byte tail");
                  Epub.Archive_Sources.Copy_Range (Source, Data'Length + 1, 0, Target);
                  Assert (Target.Size = 131_073, "Empty range at EOF writes no bytes");
                  begin
                     Epub.Archive_Sources.Copy_Range (Source, Data'Length, 2, Target);
                     Assert (False, "Source copy cannot read beyond EOF");
                  exception
                     when Epub.File_Streams.File_Error => null;
                  end;
                  Assert (Target.Size = 131_073, "Rejected range leaves output untouched");
               end;
            end;
         when String_View =>
            declare
               function Generate return String is
               begin
                  return Bytes : String (5 .. 70_020) do
                     for Index in Bytes'Range loop
                        Bytes (Index) := Character'Val (Index mod 251);
                     end loop;
                  end return;
               end Generate;
               Data : aliased constant String := Generate;
               Empty : aliased constant String := "";
               Reader : Epub.String_Streams.Reader (Data'Access);
               Empty_Reader : Epub.String_Streams.Reader (Empty'Access);
               Buffer : Stream_Element_Array (-7 .. 65_550);
               Last : Stream_Element_Offset;
            begin
               Reader.Read (Buffer, Last);
               Assert (Last = Buffer'Last and then Reader.Index = Buffer'Length + 1,
                       "Bulk string view respects non-unit lower bounds");
               for Index in Buffer'Range loop
                  Assert (Buffer (Index) = Character'Pos (Data (Data'First + Natural (Index - Buffer'First))),
                          "Bulk view reproduces every byte");
               end loop;
               Reader.Read (Buffer, Last);
               Assert (Last = Buffer'First + Data'Length - Buffer'Length - 1 and then Reader.End_Of_Stream,
                       "Partial final read returns exactly the remaining bytes");
               Reader.Read (Buffer, Last);
               Assert (Last = Buffer'First - 1, "Reader EOF is empty");
               Reader.Set_Index (1);
               Assert (Epub.Stream_IO.Digest (Reader) = Ada.Characters.Handling.To_Upper
                 (GNAT.SHA256.Digest (Data)), "Read-only bulk stream works through the shared hashing interface");
               begin
                  Reader.Write ([1 => 0]);
                  Assert (False, "Byte view cannot be written");
               exception
                  when Ada.IO_Exceptions.Mode_Error => null;
               end;
               begin
                  Reader.Set_Index (Reader.Size + 2);
                  Assert (False, "View cannot extend its source");
               exception
                  when Ada.IO_Exceptions.Use_Error => null;
               end;
               Empty_Reader.Set_Index (1);
               Empty_Reader.Read (Buffer, Last);
               Assert (Last = Buffer'First - 1 and then Empty_Reader.Size = 0 and then Empty_Reader.Index = 1,
                       "Empty views neither read nor extend their source");
            end;
         when Hashed_Output =>
            declare
               Target : aliased Zip_Streams.Memory_Zipstream;
               Empty : Zip_Streams.Memory_Zipstream;
               Hashed : Epub.Hash_Streams.Stream (Target'Access);
               Bytes : Stream_Element_Array (1 .. 3);
               Last : Stream_Element_Offset;
               Empty_SHA : constant String := Ada.Characters.Handling.To_Upper (GNAT.SHA256.Digest (""));
            begin
               Assert (Epub.Stream_IO.Digest (Empty) = Empty_SHA, "Hashing an empty stream must not extend it");
               Assert (Hashed.Digest = Empty_SHA, "Empty output digest");
               Hashed.Set_Index (1);
               Hashed.Write ([97, 98]);
               Hashed.Write ([1 => 99]);
               Assert (Hashed.Digest = Ada.Characters.Handling.To_Upper (GNAT.SHA256.Digest ("abc")),
                       "Forwarding hashes all writes incrementally");
               begin
                  Hashed.Set_Index (1);
                  Assert (False, "Rewriting hashed bytes must be rejected");
               exception
                  when Ada.IO_Exceptions.Mode_Error => null;
               end;
               begin
                  Hashed.Read (Bytes, Last);
                  Assert (False, "Output hash stream cannot be read");
               exception
                  when Ada.IO_Exceptions.Mode_Error => null;
               end;
               Assert (Hashed.Index = 4 and then Hashed.Size = 3, "Rejected operations leave the output intact");
               Epub.Stream_IO.Copy (Empty, Hashed);
               Assert (Hashed.Size = 3, "Copying an empty stream writes no padding");
            end;
         when Bulk_Roundtrip =>
            declare
               --  Cross both the adapter's one-MiB boundary and arbitrary
               --  caller array lower bounds without staging a whole file.
               Bytes : Stream_Element_Array (-7 .. 1_048_601);
               Restored : Stream_Element_Array (13 .. Bytes'Length + 12);
               Last : Stream_Element_Offset;
            begin
               for Index in Bytes'Range loop
                  Bytes (Index) := Stream_Element (Index mod 251);
               end loop;
               Output.Open (Path, Exclusive => True);
               Output.Write (Bytes);
               Assert (Output.Size = Bytes'Length, "Exact length across bulk boundary");
               Output.Flush;
               Output.Close;
               Input.Open (Path);
               Input.Read (Restored, Last);
               Assert (Last = Restored'Last and then Restored = Bytes, "Exact bulk byte roundtrip");
               Assert (Input.End_Of_Stream, "EOF after exact read");
               Input.Read (Restored, Last);
               Assert (Last = Restored'First - 1, "EOF read returns empty span");
               Input.Set_Index (1);
               Input.Read (Restored (13 .. 16), Last);
               Assert (Last = 16 and then Restored (13 .. 16) = Bytes (-7 .. -4), "Seek and bounded read");
               Input.Close;
            end;
         when Seek_Overwrite =>
            declare
               Bytes : Stream_Element_Array (1 .. 9);
               Last : Stream_Element_Offset;
            begin
               Output.Open (Path, Exclusive => True);
               Output.Write ([1, 2, 3, 4]);
               Output.Set_Index (2);
               Output.Write ([8, 9]);
               Assert (Output.Size = 4, "Overwrite retains file size");
               Output.Set_Index (9);
               Assert (Output.Size = 4, "Seek alone does not extend the file");
               Output.Write ([1 => 7]);
               Output.Close;
               Input.Open (Path);
               Input.Read (Bytes, Last);
               Assert (Last = 9 and then Bytes = [1, 8, 9, 4, 0, 0, 0, 0, 7], "Seek hole is zero-filled");
               Input.Close;
            end;
         when Access_And_Lifetime =>
            declare
               Owner : Epub.File_Streams.Stream;
               Collision : Epub.File_Streams.Stream;
            begin
               Owner.Open (Path, Exclusive => True);
               Owner.Write ([1 => 42]);
               begin
                  Collision.Open (Path, Exclusive => True);
                  Assert (False, "Exclusive create must refuse replacement");
               exception
                  when Epub.File_Streams.File_Error => null;
               end;
               Assert (not Collision.Is_Open, "Failed open owns no handle");
            end;
            --  Owner finalization closes the writer, permitting this reopen.
            Input.Open (Path);
            Assert (Input.Size = 1, "Collision leaves original file intact");
            Expect_Write_Rejected;
            Input.Close;
            Input.Close;
            Assert (not Input.Is_Open, "Close is idempotent");
            declare
               Bytes : Stream_Element_Array (1 .. 1);
               Last : Stream_Element_Offset;
            begin
               Input.Read (Bytes, Last);
               Assert (False, "Closed stream rejects read");
            exception
               when Epub.File_Streams.File_Error => null;
            end;
      end case;
      Epub.Files.Remove (Path);
   exception
      when others =>
         Output.Close;
         Input.Close;
         Epub.Files.Remove (Path);
         raise;
   end Run_Test;
end Stream_Cases;

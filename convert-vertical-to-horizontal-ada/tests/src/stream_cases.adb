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
with Epub.Buffered_Streams;
with Epub.Input_Streams;
with Epub.Memory_Outputs;

package body Stream_Cases is
   use AUnit.Assertions;
   use Ada.Streams;
   use type Zip_Streams.ZS_Size_Type;
   type Capacity_Array is array (Positive range <>) of Epub.Buffered_Streams.Capacity_Type;
   package Recording is
   type Recording_Writer is new Zip_Streams.Root_Zipstream_Type with record
      Data : Zip_Streams.Memory_Zipstream;
      Writes : Natural := 0;
      Fail_Writes : Boolean := False;
   end record;
   overriding procedure Read
     (Item : in out Recording_Writer; Buffer : out Stream_Element_Array; Last : out Stream_Element_Offset);
   overriding procedure Write (Item : in out Recording_Writer; Buffer : Stream_Element_Array);
   overriding procedure Set_Index (Item : in out Recording_Writer; To : Zip_Streams.ZS_Index_Type);
   overriding function Index (Item : Recording_Writer) return Zip_Streams.ZS_Index_Type;
   overriding function Size (Item : Recording_Writer) return Zip_Streams.ZS_Size_Type;
   overriding function End_Of_Stream (Item : Recording_Writer) return Boolean;
   end Recording;
   package body Recording is
   overriding procedure Read
     (Item : in out Recording_Writer; Buffer : out Stream_Element_Array; Last : out Stream_Element_Offset) is
   begin
      Item.Data.Read (Buffer, Last);
   end Read;
   overriding procedure Write (Item : in out Recording_Writer; Buffer : Stream_Element_Array) is
   begin
      Item.Writes := Item.Writes + 1;
      if Item.Fail_Writes then
         if Buffer'Length > 0 then
            Item.Data.Write (Buffer (Buffer'First .. Buffer'First));
         end if;
         raise Ada.IO_Exceptions.Device_Error with "Injected partial target write";
      end if;
      Item.Data.Write (Buffer);
   end Write;
   overriding procedure Set_Index (Item : in out Recording_Writer; To : Zip_Streams.ZS_Index_Type) is
   begin
      Item.Data.Set_Index (To);
   end Set_Index;
   overriding function Index (Item : Recording_Writer) return Zip_Streams.ZS_Index_Type is (Item.Data.Index);
   overriding function Size (Item : Recording_Writer) return Zip_Streams.ZS_Size_Type is (Item.Data.Size);
   overriding function End_Of_Stream (Item : Recording_Writer) return Boolean is (Item.Data.End_Of_Stream);
   end Recording;
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
         when Memory_Output =>
            declare
               Data : Stream_Element_Array (-9 .. 131_091);
               Expected : String (1 .. Data'Length);
               Buffer : Epub.Memory_Outputs.Stream (Data'Length);
               Empty : Epub.Memory_Outputs.Stream (0);
               Target : Zip_Streams.Memory_Zipstream;
               Actual : Ada.Strings.Unbounded.Unbounded_String;
               Restored : Stream_Element_Array (13 .. Data'Length + 12);
               Last : Stream_Element_Offset;
               Position : Stream_Element_Offset := Data'First;
            begin
               for Offset in Data'Range loop
                  Data (Offset) := Stream_Element (Offset mod 251);
                  Expected (Natural (Offset - Data'First) + 1) := Character'Val (Data (Offset));
               end loop;
               Empty.Write (Data (1 .. 0));
               Empty.Copy_To (Target, 0);
               Empty.Set_Index (1);
               Empty.Read (Restored, Last);
               Assert (Last = Restored'First - 1 and then Empty.Size = 0 and then Empty.Index = 1,
                       "Zero-capacity output neither allocates visible bytes nor extends on empty operations");
               while Position <= Data'Last loop
                  declare
                     Chunk : constant Stream_Element_Offset := Stream_Element_Offset'Min
                       (32_767, Data'Last - Position + 1);
                  begin
                     Buffer.Write (Data (Position .. Position + Chunk - 1));
                     Position := Position + Chunk;
                  end;
               end loop;
               Assert (Buffer.Size = Data'Length and then Buffer.Index = Data'Length + 1,
                       "Bulk appends retain exact length across multiple growth boundaries");
               Buffer.Set_Index (1);
               Buffer.Read (Restored, Last);
               Assert (Last = Restored'Last and then Restored = Data and then Buffer.End_Of_Stream,
                       "Growing output reproduces bytes with arbitrary caller bounds");
               Buffer.Read (Restored, Last);
               Assert (Last = Restored'First - 1, "Output EOF returns an empty read");
               Buffer.Set_Index (1);
               Buffer.Write ([7, 8, 9]);
               Expected (1 .. 3) := [Character'Val (7), Character'Val (8), Character'Val (9)];
               Buffer.Copy_To (Target, Data'Length);
               Target.Get (Actual);
               Assert (Ada.Strings.Unbounded.To_String (Actual) = Expected and then Buffer.Index = 4,
                       "Borrowed bulk forwarding preserves a partial overwrite and leaves the source position alone");
               Buffer.Set_Index (1);
               Buffer.Write (Data);
               Buffer.Set_Index (1);
               Buffer.Read (Restored, Last);
               Assert (Last = Restored'Last and then Restored = Data and then Buffer.Size = Data'Length,
                       "Stored fallback can replace the whole attempted compressed stream in bulk");
               begin
                  Buffer.Write ([1 => 42]);
                  Assert (False, "Output cannot exceed its declared memory budget");
               exception
                  when Ada.IO_Exceptions.Use_Error => null;
               end;
               begin
                  Buffer.Set_Index (Data'Length + 2);
                  Assert (False, "Seeking cannot expose uninitialized output capacity");
               exception
                  when Ada.IO_Exceptions.Use_Error => null;
               end;
               begin
                  Buffer.Copy_To (Target, Data'Length + 1);
                  Assert (False, "Bulk forwarding cannot expose uninitialized bytes");
               exception
                  when Ada.IO_Exceptions.Use_Error => null;
               end;
               Assert (Buffer.Size = Data'Length, "Rejected operations leave output length intact");
            end;
         when Input_Cache =>
            declare
               Data : String (1 .. 131_073);
               type Limits_Array is array (Positive range <>) of Zip_Streams.ZS_Size_Type;
            begin
               for Index in Data'Range loop
                  Data (Index) := Character'Val (Index mod 251);
               end loop;
               Epub.Files.Write_Exclusive (Path, Data);
               for Limit of Limits_Array'[0, Data'Length - 1, Data'Length] loop
                  declare
                     Cached : Epub.Input_Streams.Stream;
                     Bytes : Stream_Element_Array (-7 .. 65_550);
                     Last : Stream_Element_Offset;
                  begin
                     Cached.Open (Path, Memory_Limit => Limit);
                     Assert (Cached.Is_Memory_Backed = (Limit >= Data'Length),
                             "RAM budget includes the exact-fit boundary and otherwise retains file backing");
                     Cached.Read (Bytes, Last);
                     Assert (Last = Bytes'Last, "Input backing supports bulk reads with non-unit bounds");
                     for Index in Bytes'Range loop
                        Assert (Bytes (Index) = Character'Pos (Data (Natural (Index - Bytes'First) + 1)),
                                "Input snapshot preserves every byte");
                     end loop;
                     Cached.Set_Index (Data'Length);
                     Cached.Read (Bytes, Last);
                     Assert (Last = Bytes'First and then Cached.End_Of_Stream and then
                       Bytes (Bytes'First) = Character'Pos (Data (Data'Last)), "One-byte tail and exact EOF");
                     Cached.Read (Bytes, Last);
                     Assert (Last = Bytes'First - 1, "Repeated EOF remains empty");
                     Assert (Epub.Stream_IO.Digest (Cached) = Ada.Characters.Handling.To_Upper
                       (GNAT.SHA256.Digest (Data)), "RAM and file backing produce the same whole-input hash");
                     begin
                        Cached.Write ([1 => 42]);
                        Assert (False, "Input snapshots are read-only");
                     exception
                        when Ada.IO_Exceptions.Mode_Error => null;
                     end;
                     begin
                        Cached.Set_Index (Data'Length + 2);
                        Assert (False, "Input snapshots cannot seek past EOF");
                     exception
                        when Ada.IO_Exceptions.Use_Error => null;
                     end;
                     Cached.Close;
                     Cached.Close;
                     Assert (not Cached.Is_Open and then not Cached.Is_Memory_Backed, "Closing releases RAM and handles");
                     begin
                        Cached.Read (Bytes, Last);
                        Assert (False, "A closed input snapshot cannot be read");
                     exception
                        when Epub.File_Streams.File_Error => null;
                     end;
                     Cached.Open (Path, Memory_Limit => Limit);
                     Assert (Cached.Index = 1, "Reopening resets input position");
                     --  Leave the reopened source to controlled finalization.
                  end;
               end loop;
            end;
            Epub.Files.Remove (Path);
            Epub.Files.Write_Exclusive (Path, "");
            declare
               Cached : Epub.Input_Streams.Stream;
               Bytes : Stream_Element_Array (3 .. 7);
               Last : Stream_Element_Offset;
            begin
               Cached.Open (Path);
               Cached.Read (Bytes, Last);
               Assert (Cached.Size = 0 and then Cached.Index = 1 and then Last = 2 and then Cached.End_Of_Stream,
                       "Empty source snapshots retain zero length");
            end;
         when Buffered_Output =>
            for Capacity of Capacity_Array'[1, 7, 65_536] loop
               declare
                  Target : aliased Recording.Recording_Writer;
                  Hashed : aliased Epub.Hash_Streams.Stream (Target'Access);
                  Buffered : Epub.Buffered_Streams.Writer (Hashed'Access, Capacity);
                  Data : Stream_Element_Array (-9 .. 131_091);
                  Actual : Ada.Strings.Unbounded.Unbounded_String;
                  Expected : String (1 .. Data'Length);
                  Position : Stream_Element_Offset := Data'First;
                  Last : Stream_Element_Offset;
               begin
                  for Index in Data'Range loop
                     Data (Index) := Stream_Element (Index mod 251);
                     Expected (Natural (Index - Data'First) + 1) := Character'Val (Data (Index));
                  end loop;
                  Buffered.Flush;
                  Buffered.Write (Data (1 .. 0));
                  Assert (Buffered.Size = 0 and then Target.Size = 0, "Empty buffered writes do not extend output");
                  while Position <= Data'Last loop
                     declare
                        Chunk : constant Stream_Element_Offset := Stream_Element_Offset'Min
                          (Data'Last - Position + 1, (Position - Data'First) mod 97 + 1);
                     begin
                        Buffered.Write (Data (Position .. Position + Chunk - 1));
                        Position := Position + Chunk;
                     end;
                  end loop;
                  Assert (Buffered.Size = Data'Length and then Buffered.Index = Data'Length + 1,
                          "Buffered index includes pending bytes");
                  Buffered.Set_Index (Buffered.Index);
                  Buffered.Flush;
                  Buffered.Flush;
                  Target.Data.Get (Actual);
                  Assert (Ada.Strings.Unbounded.To_String (Actual) = Expected,
                          "Small writes cross exact and partial buffer boundaries without changing bytes");
                  Assert (Hashed.Digest = Ada.Characters.Handling.To_Upper (GNAT.SHA256.Digest (Expected)),
                          "Flushed target hashes every buffered byte exactly once");
                  Assert (Target.Writes <= Natural (Data'Length / Capacity) + 1,
                          "Small writes are combined into bounded bulk writes");
                  Buffered.Write (Data);
                  Buffered.Flush;
                  Target.Data.Get (Actual);
                  Assert (Ada.Strings.Unbounded.To_String (Actual) = Expected & Expected,
                          "Large direct writes preserve bytes after a flushed prefix");
                  Buffered.Write ([1 => 255]);
                  Buffered.Write (Data);
                  Buffered.Flush;
                  Target.Data.Get (Actual);
                  Assert (Ada.Strings.Unbounded.To_String (Actual) =
                    Expected & Expected & Character'Val (255) & Expected,
                    "A pending small prefix joins a large write without gaps or repetition");
                  begin
                     Buffered.Set_Index (1);
                     Assert (False, "Buffered output must reject rewrites");
                  exception
                     when Ada.IO_Exceptions.Mode_Error => null;
                  end;
                  begin
                     Buffered.Read (Data, Last);
                     Assert (False, "Buffered output must reject reads");
                  exception
                     when Ada.IO_Exceptions.Mode_Error => null;
                  end;
               end;
            end loop;
            declare
               Target : aliased Recording.Recording_Writer;
               Buffered : Epub.Buffered_Streams.Writer (Target'Access, 7);
            begin
               Buffered.Write ([1, 2, 3]);
               Assert (Target.Writes = 0, "Small output stays in RAM until flushed");
               Target.Fail_Writes := True;
               begin
                  Buffered.Flush;
                  Assert (False, "Partial target failures must escape flush");
               exception
                  when Ada.IO_Exceptions.Device_Error => null;
               end;
               Assert (Target.Size = 1 and then Target.Writes = 1, "Injected failure wrote only a prefix");
               begin
                  Buffered.Flush;
                  Assert (False, "A partially failed flush must not be retried");
               exception
                  when Ada.IO_Exceptions.Use_Error => null;
               end;
               begin
                  Buffered.Write ([1 => 4]);
                  Assert (False, "Failed target prevents subsequent buffered writes");
               exception
                  when Ada.IO_Exceptions.Use_Error => null;
               end;
               Assert (Target.Size = 1 and then Target.Writes = 1, "Rejected retries cannot duplicate output");
            end;
            declare
               Target : aliased Recording.Recording_Writer;
               Buffered : Epub.Buffered_Streams.Writer (Target'Access, 7);
            begin
               Buffered.Write ([1, 2, 3]);
               Target.Write ([1 => 9]);
               begin
                  Buffered.Flush;
                  Assert (False, "A changed target cannot accept pending buffered bytes");
               exception
                  when Ada.IO_Exceptions.Mode_Error => null;
               end;
               Assert (Target.Size = 1 and then Target.Writes = 1, "Target mutation is detected before writing");
            end;
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

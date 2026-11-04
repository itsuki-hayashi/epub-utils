with AUnit.Assertions;
with Interfaces;
with Test_Huffman;
with Epub.Huffman.Length_Limited_Coding;
with Epub.Word_Operations;
with Epub.Checksums;
with Zip.CRC_Crypto;
with Epub.LZ77;
with Epub.Digests;
with GNAT.SHA256;
with Ada.Characters.Handling;
with Ada.Streams;

package body Codec_Cases is
   use AUnit.Assertions;
   use type Interfaces.Unsigned_32;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Codec: " & Item.Kind'Image &
       (if Item.Kind = SHA_Differential then " hardware=" & Epub.Digests.Hardware_Available'Image else "")));

   overriding procedure Run_Test (Item : in out Unit_Case) is
      subtype Symbol is Test_Huffman.Symbol;
      subtype Counts is Test_Huffman.Counts;
      subtype Lengths is Test_Huffman.Lengths;
      use type Lengths;
      use type Symbol;
      procedure Reference (Frequencies : Counts; Result : out Lengths) renames Test_Huffman.Reference;
      procedure Owned is new Epub.Huffman.Length_Limited_Coding
        (Symbol, Natural, Counts, Lengths, 15);
      Frequencies : Counts := [others => 0];
      Expected, Actual : Lengths;
      Random : Interfaces.Unsigned_32 := 16#37AB_8021#;
      procedure Compare is
         Slots : Natural := 0;
         Used : Natural := 0;
      begin
         Reference (Frequencies, Expected);
         Owned (Frequencies, Actual);
         Assert (Actual = Expected, "Identical optimal lengths and deterministic tie decisions");
         for Index in Symbol loop
            if Frequencies (Index) > 0 then
               Used := Used + 1;
               Assert (Actual (Index) in 1 .. 15, "Bounded nonzero code length");
               Slots := Slots + 2 ** (15 - Actual (Index));
            else
               Assert (Actual (Index) = 0, "Unused symbols have no code");
            end if;
         end loop;
         Assert (Slots <= 2 ** 15, "Kraft bound");
         if Used > 1 then
            Assert (Slots = 2 ** 15, "Complete prefix code");
         end if;
      end Compare;
   begin
      if Item.Kind = Bulk_Read_Bounds then
         declare
            Oversized, Rejected : Boolean := True;
            function Read_Byte return Epub.LZ77.Byte is (0);
            function More return Boolean is (False);
            procedure Literal (Value : Epub.LZ77.Byte) is
               pragma Unreferenced (Value);
            begin
               Assert (False, "An invalid or empty read must not emit a literal");
            end Literal;
            procedure Match
              (Distance : Epub.LZ77.Distance_Type; Length : Integer; Prefix : Epub.LZ77.Match_Prefix) is
               pragma Unreferenced (Distance, Length, Prefix);
            begin
               Assert (False, "An invalid or empty read must not emit a match");
            end Match;
            procedure Read_Span (Buffer : out Epub.LZ77.Byte_Array; Count : out Natural) is
            begin
               Buffer := [others => 0];
               Count := (if Oversized then Buffer'Length + 1 else 0);
            end Read_Span;
            procedure Encode is new Epub.LZ77.Encode
              (Read_Byte, More, Literal, Match, Epub.LZ77.Info_Zip_9_Knuth, True, Read_Span);
         begin
            Rejected := False;
            begin
               Encode;
            exception
               when Constraint_Error => Rejected := True;
            end;
            Assert (Rejected, "Bulk readers cannot report bytes beyond their checked destination");
            Oversized := False;
            Encode;
         end;
         return;
      end if;
      if Item.Kind = SHA_Differential then
         declare
            Data : String (1 .. 65_600);
            type Size_List is array (Positive range <>) of Natural;
         begin
            Assert (Epub.Digests.Digest ("") =
              "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855", "Empty SHA-256 known answer");
            Assert (Epub.Digests.Digest ("abc") =
              "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", "SHA-256 abc known answer");
            for Index in Data'Range loop
               Random := Random * 1_664_525 + 1_013_904_223;
               Data (Index) := Character'Val (Interfaces.Shift_Right (Random, 24));
            end loop;
            for Alignment in 0 .. 15 loop
               for Size of Size_List'[0, 1, 2, 3, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 4096, 65_536] loop
                  declare
                     Bytes : constant String := Data (Alignment + 1 .. Alignment + Size);
                     Expected_SHA : constant String := Ada.Characters.Handling.To_Upper (GNAT.SHA256.Digest (Bytes));
                     Accelerated : Epub.Digests.Context := Epub.Digests.Initial_Context;
                     Fallback : Epub.Digests.Context := Epub.Digests.Initial_Context (Software_Only => True);
                     Position : Natural := Bytes'First;
                     use type Ada.Streams.Stream_Element_Offset;
                     Buffer : Ada.Streams.Stream_Element_Array (-13 .. Ada.Streams.Stream_Element_Offset (Size) - 14);
                  begin
                     Assert (Epub.Digests.Digest (Data (Alignment + 1 .. Alignment + Size)) = Expected_SHA,
                             "One-shot SHA padding, size and physical alignment");
                     while Position <= Bytes'Last loop
                        declare
                           Count : constant Positive := Positive'Min (73, Bytes'Last - Position + 1);
                        begin
                           Epub.Digests.Update (Accelerated, Bytes (Position .. Position + Count - 1));
                           Epub.Digests.Update (Fallback, Bytes (Position .. Position + Count - 1));
                           Assert (Epub.Digests.Digest (Accelerated) = Ada.Characters.Handling.To_Upper
                             (GNAT.SHA256.Digest (Bytes (Bytes'First .. Position + Count - 1))), "Digest does not consume context");
                           Position := Position + Count;
                        end;
                     end loop;
                     Assert (Epub.Digests.Digest (Accelerated) = Expected_SHA, "Fragmented hardware SHA");
                     Assert (Epub.Digests.Digest (Fallback) = Expected_SHA, "Forced portable fallback");
                     for Index in Buffer'Range loop
                        Buffer (Index) := Character'Pos (Bytes (Bytes'First + Natural (Index - Buffer'First)));
                     end loop;
                     Accelerated := Epub.Digests.Initial_Context;
                     Epub.Digests.Update (Accelerated, Buffer);
                     Assert (Epub.Digests.Digest (Accelerated) = Expected_SHA, "Stream-element byte view");
                  end;
               end loop;
            end loop;
         end;
         return;
      end if;
      if Item.Kind = Huffman_Exhaustive then
         declare
            use type Test_Huffman.Small_Lengths;
            use type Interfaces.Integer_64;
            Small_Frequencies : Test_Huffman.Small_Counts;
            Wide : Test_Huffman.Wide_Counts;
            Small_Expected, Small_Actual : Test_Huffman.Small_Lengths;
            procedure Owned_3 is new Epub.Huffman.Length_Limited_Coding
              (Test_Huffman.Small_Symbol, Natural, Test_Huffman.Small_Counts, Test_Huffman.Small_Lengths, 3);
            procedure Owned_4 is new Epub.Huffman.Length_Limited_Coding
              (Test_Huffman.Small_Symbol, Natural, Test_Huffman.Small_Counts, Test_Huffman.Small_Lengths, 4);
            procedure Owned_Wide is new Epub.Huffman.Length_Limited_Coding
              (Test_Huffman.Small_Symbol, Interfaces.Integer_64, Test_Huffman.Wide_Counts, Test_Huffman.Small_Lengths, 15);
         begin
            for Combination in 0 .. 65_535 loop
               declare
                  Remaining : Natural := Combination;
               begin
                  for Index in Small_Frequencies'Range loop
                     Small_Frequencies (Index) := Remaining mod 4;
                     Remaining := Remaining / 4;
                  end loop;
               end;
               Test_Huffman.Reference_3 (Small_Frequencies, Small_Expected);
               Owned_3 (Small_Frequencies, Small_Actual);
               Assert (Small_Actual = Small_Expected, "Exhaustive three-bit limit, including package-merge fallback");
               Test_Huffman.Reference_4 (Small_Frequencies, Small_Expected);
               Owned_4 (Small_Frequencies, Small_Actual);
               Assert (Small_Actual = Small_Expected, "Exhaustive four-bit limit and deterministic equal-weight ties");
            end loop;
            for Trial in 1 .. 512 loop
               for Index in Wide'Range loop
                  Random := Random * 1_664_525 + 1_013_904_223;
                  Wide (Index) := Interfaces.Integer_64 (Random and 255) * 2 ** 40;
               end loop;
               Test_Huffman.Reference_Wide (Wide, Small_Expected);
               Owned_Wide (Wide, Small_Actual);
               Assert (Small_Actual = Small_Expected, "Frequency arithmetic retains full 64-bit precision");
            end loop;
         end;
         return;
      end if;
      if Item.Kind = Match_Tokens then
         declare
            Data : String (1 .. 200_000);
            Length : Natural := 0;
            Read_Position, Written : Positive := 1;
            Token_Hash : Epub.Digests.Context := Epub.Digests.Initial_Context;
            function More return Boolean is (Read_Position <= Length);
            function Read_Byte return Interfaces.Unsigned_8 is
               Value : constant Interfaces.Unsigned_8 := Character'Pos (Data (Read_Position));
            begin
               Read_Position := Read_Position + 1;
               return Value;
            end Read_Byte;
            procedure Literal (Value : Interfaces.Unsigned_8) is
            begin
               Epub.Digests.Update (Token_Hash, "L" & Character'Val (Value));
               Assert (Written <= Length and then Character'Pos (Data (Written)) = Natural (Value),
                       "Literal reproduces the source byte");
               Written := Written + 1;
            end Literal;
            procedure Match
              (Distance : Epub.LZ77.Distance_Type; Count : Integer; Prefix : Epub.LZ77.Match_Prefix) is
            begin
               Epub.Digests.Update (Token_Hash, "M" & Distance'Image & Count'Image);
               Assert (Distance <= 32_768 and then Distance < Written and then Count in 3 .. 258,
                       "Bounded dictionary token");
               Assert (Count <= Length - Written + 1, "Match does not extend past input");
               for Index in 1 .. Integer'Min (Prefix'Length, Count) loop
                  Assert (Natural (Prefix (Index)) = Character'Pos (Data (Written + Index - 1)), "Match prefix is original source data");
               end loop;
               for Index in 1 .. Count loop
                  Assert (Data (Written) = Data (Written - Distance), "Overlapping match reproduces the source");
                  Written := Written + 1;
               end loop;
            end Match;
            procedure Rich is new Epub.LZ77.Encode (Read_Byte, More, Literal, Match, Epub.LZ77.Rich);
            procedure IZ9 is new Epub.LZ77.Encode (Read_Byte, More, Literal, Match, Epub.LZ77.Info_Zip_9);
            procedure Knuth9 is new Epub.LZ77.Encode (Read_Byte, More, Literal, Match, Epub.LZ77.Info_Zip_9_Knuth);
            Chunk_Size : Positive := 1;
            procedure Read_Span (Buffer : out Epub.LZ77.Byte_Array; Count : out Natural) is
            begin
               Count := Natural'Min (Buffer'Length, Natural'Min (Chunk_Size, Length - Read_Position + 1));
               for Index in 0 .. Integer (Count) - 1 loop
                  Buffer (Buffer'First + Index) := Character'Pos (Data (Read_Position + Index));
               end loop;
               Read_Position := Read_Position + Count;
            end Read_Span;
            procedure Bulk_Knuth9 is new Epub.LZ77.Encode
              (Read_Byte, More, Literal, Match, Epub.LZ77.Info_Zip_9_Knuth, True, Read_Span);
            type Size_List is array (Positive range <>) of Natural;
            type Chain_List is array (Positive range <>) of Epub.LZ77.Chain_Limit;
         begin
            for Pattern in 1 .. 4 loop
               for Index in Data'Range loop
                  Random := Random * 1_664_525 + 1_013_904_223;
                  Data (Index) := Character'Val
                    ((case Pattern is
                       when 1 => Natural (Interfaces.Shift_Right (Random, 24)),
                       when 2 => Character'Pos ('a'),
                       when 3 => (Index + Index / 32_747) mod 251,
                       when others => (Index mod 32_701) mod 256));
               end loop;
               for Size of Size_List'[0, 1, 2, 3, 257, 258, 259, 261, 262,
                 32_767, 32_768, 32_769, 65_273, 65_274, 65_535, 65_536, 65_537, 131_073, 200_000]
               loop
                  Length := Size;
                  Read_Position := 1;
                  Written := 1;
                  Rich;
                  Assert (Read_Position = Length + 1 and then Written = Length + 1, "Complete Rich token stream");
                  Read_Position := 1;
                  Written := 1;
                  IZ9;
                  Assert (Read_Position = Length + 1 and then Written = Length + 1, "Complete level-9 token stream");
                  for Budget of Chain_List'[1, 64, 4096] loop
                     Read_Position := 1;
                     Written := 1;
                     Token_Hash := Epub.Digests.Initial_Context;
                     Knuth9 (Budget);
                     Assert (Read_Position = Length + 1 and then Written = Length + 1,
                             "Complete multiplicative-hash token stream at every search budget");
                     declare
                        Expected_Tokens : constant String := Epub.Digests.Digest (Token_Hash);
                     begin
                        for Chunk of Size_List'[1, 7, 32_768, 65_536] loop
                           Chunk_Size := Chunk;
                           Read_Position := 1;
                           Written := 1;
                           Token_Hash := Epub.Digests.Initial_Context;
                           Bulk_Knuth9 (Budget);
                           Assert (Read_Position = Length + 1 and then Written = Length + 1,
                                   "Complete bulk token stream across short reads and window slides");
                           Assert (Epub.Digests.Digest (Token_Hash) = Expected_Tokens,
                                   "Bulk and byte input produce identical tokens");
                        end loop;
                     end;
                  end loop;
               end loop;
            end loop;
         end;
         return;
      end if;
      if Item.Kind = CRC_Compatibility then
         declare
            Buffer : Zip.Byte_Buffer (0 .. 32_775);
            Expected_CRC, Whole_CRC, Split_CRC : Interfaces.Unsigned_32;
            type Size_List is array (Positive range <>) of Natural;
         begin
            for Index in Buffer'Range loop
               Random := Random * 1_664_525 + 1_013_904_223;
               Buffer (Index) := Interfaces.Unsigned_8 (Interfaces.Shift_Right (Random, 24));
            end loop;
            Assert (Epub.Checksums.CRC32 ("") = 0, "Empty IEEE CRC-32");
            Assert (Epub.Checksums.CRC32 ("123456789") = 16#CBF4_3926#, "ZIP IEEE polynomial known answer");
            for Alignment in 0 .. 7 loop
               for Size of Size_List'[0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 255, 256, 257, 32_767, 32_768] loop
                  Zip.CRC_Crypto.Init (Expected_CRC);
                  Zip.CRC_Crypto.Update (Expected_CRC, Buffer (Alignment .. Alignment + Size - 1));
                  Epub.Checksums.Init (Whole_CRC);
                  Epub.Checksums.Update (Whole_CRC, Buffer (Alignment .. Alignment + Size - 1));
                  Assert (Epub.Checksums.Final (Whole_CRC) = Zip.CRC_Crypto.Final (Expected_CRC), "Slicing-by-eight CRC");
                  declare
                     Bytes : String (7 .. Size + 6);
                  begin
                     for Index in Bytes'Range loop
                        Bytes (Index) := Character'Val (Buffer (Alignment + Index - Bytes'First));
                     end loop;
                     Assert (Epub.Checksums.CRC32 (Bytes) = Zip.CRC_Crypto.Final (Expected_CRC),
                             "String byte view retains CRC across sizes and non-unit lower bounds");
                  end;
                  Epub.Checksums.Init (Split_CRC);
                  declare
                     Position : Natural := Alignment;
                  begin
                     while Position < Alignment + Size loop
                        declare
                           Count : constant Positive := Positive'Min (13, Alignment + Size - Position);
                        begin
                           Epub.Checksums.Update (Split_CRC, Buffer (Position .. Position + Count - 1));
                           Position := Position + Count;
                        end;
                     end loop;
                  end;
                  Assert (Split_CRC = Whole_CRC, "Streaming CRC agrees across unaligned chunks");
               end loop;
            end loop;
         end;
         return;
      end if;
      if Item.Kind = Word_Matches then
         declare
            use type Interfaces.Unsigned_8;
            type Data_Array is array (Integer range <>) of Interfaces.Unsigned_8;
            function Match is new Epub.Word_Operations.Matching_Prefix (Integer, Data_Array);
            Data : Data_Array (0 .. 4095);
         begin
            for Index in Data'Range loop
               Data (Index) := Interfaces.Unsigned_8 (Index mod 251);
            end loop;
            Assert (Match (Data, -100, 5000, 0) = 0, "Zero-length spans do not load memory");
            for Alignment in 0 .. 7 loop
               for Mismatch in 0 .. 258 loop
                  declare
                     Left : constant Integer := 16 + Alignment;
                     Right : constant Integer := 2048 + Alignment;
                  begin
                     Data (Right .. Right + 257) := Data (Left .. Left + 257);
                     if Mismatch < 258 then
                        Data (Right + Mismatch) := Data (Left + Mismatch) xor 1;
                     end if;
                     Assert (Match (Data, Left, Right, 258) = Mismatch, "Full word and byte mismatch positions");
                     for Limit in Integer'Max (0, Mismatch - 1) .. Integer'Min (258, Mismatch + 1) loop
                        Assert (Match (Data, Left, Right, Limit) = Natural'Min (Mismatch, Limit), "Exact span limit");
                     end loop;
                  end;
               end loop;
            end loop;
         end;
         return;
      end if;
      Compare;
      for Index in Symbol loop
         Frequencies := [others => 0];
         Frequencies (Index) := 1;
         Compare;
      end loop;
      for Trial in 1 .. 2000 loop
         for Index in Symbol loop
            Random := Random * 1_664_525 + 1_013_904_223;
            Frequencies (Index) :=
              (if (Random and 7) = 0 then 0 else Natural (Interfaces.Shift_Right (Random, 12)));
            if Trial mod 7 = 0 then
               Frequencies (Index) := (if Index < 20 then 2 ** Natural (Index) else 1);
            elsif Trial mod 11 = 0 then
               Frequencies (Index) := 1;
            end if;
         end loop;
         Compare;
      end loop;
   end Run_Test;
end Codec_Cases;

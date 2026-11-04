with Epub.Checksums;
with Interfaces;
with Zip;

with Epub.Performance;
package body Epub.Inflate is
   use Interfaces;
   type Length_Array is array (Natural range <>) of Natural;
   type Tree_Kind is (Code_Lengths, Literal_Lengths, Distances);
   type Counts_Array is array (Natural range 0 .. 15) of Natural;
   type Codes_Array is array (Natural range 0 .. 15) of Unsigned_32;
   type Fast_Table is array (Natural range 0 .. 511) of Unsigned_16;
   type Huffman_Tree is record
      Counts, Starts : Counts_Array := [others => 0];
      First : Codes_Array := [others => 0];
      Symbols : Length_Array (0 .. 287) := [others => 0];
      Fast : Fast_Table;
      Maximum : Natural := 0;
   end record;

   function Build_Tree (Lengths : Length_Array; Kind : Tree_Kind) return Huffman_Tree is
      Result : Huffman_Tree;
      Left : Integer := 1;
      Code : Unsigned_32 := 0;
      Offset : Natural := 0;
      Next : Counts_Array;
   begin
      Result.Fast := [others => 0];
      for Length of Lengths loop
         if Length > 15 then
            raise Invalid_Stream with "Invalid Huffman code length";
         elsif Length > 0 then
            Result.Counts (Length) := Result.Counts (Length) + 1;
            Result.Maximum := Natural'Max (Result.Maximum, Length);
         end if;
      end loop;
      if Result.Maximum = 0 then
         if Kind /= Distances then
            raise Invalid_Stream with "Empty Huffman tree";
         end if;
         return Result;
      end if;
      for Length in 1 .. 15 loop
         Left := Left * 2 - Result.Counts (Length);
         if Left < 0 then
            raise Invalid_Stream with "Oversubscribed Huffman tree";
         end if;
         Code := Shift_Left (Code + Unsigned_32 (Result.Counts (Length - 1)), 1);
         Result.First (Length) := Code;
         Result.Starts (Length) := Offset;
         Offset := Offset + Result.Counts (Length);
      end loop;
      if Left > 0 and then (Kind = Code_Lengths or else Result.Maximum /= 1) then
         raise Invalid_Stream with "Incomplete Huffman tree";
      end if;
      Next := Result.Starts;
      for Index in Lengths'Range loop
         declare
            Length : constant Natural := Lengths (Index);
            Symbol : constant Natural := Index - Lengths'First;
         begin
            if Length > 0 then
               Result.Symbols (Next (Length)) := Symbol;
               if Length <= 9 then
                  declare
                     Bits : Unsigned_32 := Result.First (Length) +
                       Unsigned_32 (Next (Length) - Result.Starts (Length));
                     Reversed : Natural := 0;
                  begin
                     for Bit in 1 .. Length loop
                        Reversed := Reversed * 2 + Natural (Bits and 1);
                        Bits := Shift_Right (Bits, 1);
                     end loop;
                     for Repeat in 0 .. 2 ** (9 - Length) - 1 loop
                        Result.Fast (Reversed + Repeat * 2 ** Length) := Unsigned_16 (Length * 512 + Symbol);
                     end loop;
                  end;
               end if;
               Next (Length) := Next (Length) + 1;
            end if;
         end;
      end loop;
      return Result;
   end Build_Tree;

   function Fixed_Literals return Huffman_Tree is
      Lengths : constant Length_Array := [0 .. 143 => 8, 144 .. 255 => 9, 256 .. 279 => 7, 280 .. 287 => 8];
   begin
      return Build_Tree (Lengths, Literal_Lengths);
   end Fixed_Literals;
   Fixed_Literal_Tree : constant Huffman_Tree := Fixed_Literals;
   Fixed_Distance_Tree : constant Huffman_Tree := Build_Tree ([0 .. 31 => 5], Distances);

   Length_Base : constant Length_Array (257 .. 285) :=
     [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
   Length_Extra : constant Length_Array (257 .. 285) :=
     [257 .. 264 => 0, 265 .. 268 => 1, 269 .. 272 => 2, 273 .. 276 => 3,
      277 .. 280 => 4, 281 .. 284 => 5, 285 => 0];
   Distance_Base : constant Length_Array (0 .. 29) :=
     [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
      257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
   Distance_Extra : constant Length_Array (0 .. 29) :=
     [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

   function Decode
     (Input : in out Zip_Streams.Root_Zipstream_Type'Class;
      Metadata : Zip.Headers.Local_File_Header) return String is
      Buffer : Zip.Byte_Buffer (1 .. 32_768);
      View : String (Buffer'Range) with Import, Address => Buffer'Address;
      Cursor : Positive := 1;
      Buffered : Natural := 0;
      Remaining : Unsigned_64 := Metadata.dd.compressed_size;
      Bits : Unsigned_64 := 0;
      Available : Natural := 0;
      Written : Natural := 0;
      Output_Length : Natural;

      procedure Refill is
         Count : constant Natural := Natural (Unsigned_64'Min (Buffer'Length, Remaining));
      begin
         if Count = 0 then
            raise Invalid_Stream with "Truncated compressed payload";
         end if;
         Zip.Block_Read (Input, Buffer (1 .. Count), Buffered);
         if Buffered = 0 or else Buffered > Count then
            raise Invalid_Stream with "Truncated compressed payload";
         end if;
         Remaining := Remaining - Unsigned_64 (Buffered);
         Cursor := 1;
      end Refill;

      procedure Fill_Bits (Count : Natural) is
         type Unaligned_Word is mod 2 ** 64 with Size => 64, Alignment => 1;
      begin
         while Available < Count loop
            if Cursor > Buffered then
               exit when Remaining = 0;
               Refill;
            end if;
            if Buffered - Cursor + 1 >= 8 then
               declare
                  Word : Unaligned_Word with Import, Address => Buffer (Cursor)'Address;
                  Bytes : constant Positive := (64 - Available) / 8;
                  Mask : constant Unsigned_64 := Shift_Right (Unsigned_64'Last, 64 - Bytes * 8);
               begin
                  --  Inspect only a complete word inside the bounded refill.
                  --  Consume only the bytes that fit in the bit accumulator.
                  Bits := Bits or Shift_Left (Unsigned_64 (Word) and Mask, Available);
                  Available := Available + Bytes * 8;
                  Cursor := Cursor + Bytes;
               end;
            else
               Bits := Bits or Shift_Left (Unsigned_64 (Buffer (Cursor)), Available);
               Available := Available + 8;
               Cursor := Cursor + 1;
            end if;
         end loop;
      end Fill_Bits;

      function Get_Bits (Count : Natural) return Natural is
         Result : Natural;
      begin
         pragma Assert (Count <= 16);
         Fill_Bits (Count);
         if Available < Count then
            raise Invalid_Stream with "Truncated DEFLATE bit sequence";
         end if;
         Result := Natural (Bits and (Shift_Left (Unsigned_64'(1), Count) - 1));
         Bits := Shift_Right (Bits, Count);
         Available := Available - Count;
         return Result;
      end Get_Bits;

      function Canonical_Symbol (Tree : Huffman_Tree) return Natural is
         Code : Unsigned_32 := 0;
      begin
         for Size in 1 .. Tree.Maximum loop
            Code := Shift_Left (Code, 1) or Unsigned_32 (Get_Bits (1));
            if Code >= Tree.First (Size) and then Code - Tree.First (Size) < Unsigned_32 (Tree.Counts (Size)) then
               return Tree.Symbols (Tree.Starts (Size) + Natural (Code - Tree.First (Size)));
            end if;
         end loop;
         raise Invalid_Stream with "Invalid Huffman symbol";
      end Canonical_Symbol;

      function Symbol (Tree : Huffman_Tree) return Natural with Inline_Always is
         Entry_Code : Unsigned_16;
         Length : Natural;
      begin
         Fill_Bits (9);
         Entry_Code := Tree.Fast (Natural (Bits and 511));
         Length := Natural (Shift_Right (Entry_Code, 9));
         if Length > 0 and then Length <= Available then
            Bits := Shift_Right (Bits, Length);
            Available := Available - Length;
            return Natural (Entry_Code and 511);
         end if;
         --  Keep canonical long-code decoding and truncation checks out of
         --  the common table-lookup path without changing their behavior.
         return Canonical_Symbol (Tree);
      end Symbol;

      procedure Dynamic_Trees (Literals, Distance : out Huffman_Tree) is
         Literal_Count : constant Natural := Get_Bits (5) + 257;
         Distance_Count : constant Natural := Get_Bits (5) + 1;
         Code_Count : constant Natural := Get_Bits (4) + 4;
         Order : constant Length_Array := [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
         Code_Length : Length_Array (0 .. 18) := [others => 0];
         Lengths : Length_Array (0 .. Literal_Count + Distance_Count - 1) := [others => 0];
         Position : Natural := 0;
      begin
         if Literal_Count > 286 then
            raise Invalid_Stream with "Reserved DEFLATE literal count";
         end if;
         for Index in 0 .. Code_Count - 1 loop
            Code_Length (Order (Index)) := Get_Bits (3);
         end loop;
         declare
            Codes : constant Huffman_Tree := Build_Tree (Code_Length, Code_Lengths);
         begin
            while Position < Lengths'Length loop
               declare
                  Value : constant Natural := Symbol (Codes);
                  Repeat : Positive := 1;
                  Length : Natural;
               begin
                  case Value is
                     when 0 .. 15 => Length := Value;
                     when 16 =>
                        if Position = 0 then
                           raise Invalid_Stream with "Huffman repeat has no previous length";
                        end if;
                        Length := Lengths (Position - 1);
                        Repeat := Get_Bits (2) + 3;
                     when 17 => Length := 0; Repeat := Get_Bits (3) + 3;
                     when 18 => Length := 0; Repeat := Get_Bits (7) + 11;
                     when others => raise Invalid_Stream with "Invalid Huffman length repeat";
                  end case;
                  if Repeat > Lengths'Length - Position then
                     raise Invalid_Stream with "Huffman repeat exceeds its declared alphabet";
                  end if;
                  Lengths (Position .. Position + Repeat - 1) := [others => Length];
                  Position := Position + Repeat;
               end;
            end loop;
         end;
         if Lengths (256) = 0 then
            raise Invalid_Stream with "Missing DEFLATE end-of-block code";
         end if;
         Literals := Build_Tree (Lengths (0 .. Literal_Count - 1), Literal_Lengths);
         Distance := Build_Tree (Lengths (Literal_Count .. Lengths'Last), Distances);
      end Dynamic_Trees;

      procedure Check_Room (Count : Natural) is
      begin
         if Count > Output_Length - Written then
            raise Invalid_Stream with "Decompressed payload exceeds its declared size";
         end if;
      end Check_Room;
   begin
      pragma Compile_Time_Error (Zip.Byte'Size /= Character'Size, "Byte views require octets");
      if Metadata.zip_type not in 0 | 8 then
         raise Invalid_Stream with "Unsupported method for the common decoder";
      elsif Metadata.dd.uncompressed_size > Unsigned_64 (Natural'Last) then
         raise Invalid_Stream with "Decompressed payload exceeds the string size limit";
      elsif Metadata.zip_type = 0 and then Metadata.dd.compressed_size /= Metadata.dd.uncompressed_size then
         raise Invalid_Stream with "Stored ZIP payload has inconsistent sizes";
      elsif Metadata.zip_type = 8 and then Metadata.dd.compressed_size <= Unsigned_64'Last / 1032
        and then Metadata.dd.uncompressed_size > Metadata.dd.compressed_size * 1032
      then
         --  A match emits at most 258 bytes and consumes at least two
         --  Huffman bits. Reject impossible sizes before allocating output.
         raise Invalid_Stream with "DEFLATE payload cannot produce its declared size";
      end if;
      Epub.Performance.Start (Epub.Performance.Decompression);
      Output_Length := Natural (Metadata.dd.uncompressed_size);
      return Result : String (1 .. Output_Length) do
         declare
            procedure Copy_Aligned (Count : Natural) is
               Left : Natural := Count;
            begin
               Check_Room (Count);
               while Left > 0 and then Available >= 8 loop
                  Result (Written + 1) := Character'Val (Get_Bits (8));
                  Written := Written + 1;
                  Left := Left - 1;
               end loop;
               while Left > 0 loop
                  if Cursor > Buffered then
                     Refill;
                  end if;
                  declare
                     Chunk : constant Positive := Positive'Min (Left, Buffered - Cursor + 1);
                  begin
                     Result (Written + 1 .. Written + Chunk) := View (Cursor .. Cursor + Chunk - 1);
                     Cursor := Cursor + Chunk;
                     Written := Written + Chunk;
                     Left := Left - Chunk;
                  end;
               end loop;
            end Copy_Aligned;

            procedure Copy_Match (Distance, Count : Positive) is
               Left : Natural := Count;
               First : Natural;
            begin
               Check_Room (Count);
               if Distance > Written then
                  raise Invalid_Stream with "DEFLATE match precedes its dictionary";
               end if;
               First := Written + 1 - Distance;
               while Left > 0 loop
                  declare
                     Chunk : constant Positive := Positive'Min (Left, Written - First + 1);
                  begin
                     --  Copy only from the initialized prefix. Repeated
                     --  patterns grow geometrically without overlapping a
                     --  source/destination slice or reading future bytes.
                     Result (Written + 1 .. Written + Chunk) := Result (First .. First + Chunk - 1);
                     Written := Written + Chunk;
                     Left := Left - Chunk;
                  end;
               end loop;
            end Copy_Match;

            procedure Decode_Codes (Literals, Distance : Huffman_Tree) is
               Value : Natural;
            begin
               loop
                  Value := Symbol (Literals);
                  if Value < 256 then
                     Check_Room (1);
                     Result (Written + 1) := Character'Val (Value);
                     Written := Written + 1;
                     --  Bulk bit refills often leave another complete short
                     --  literal available. Consume it without a second loop,
                     --  retaining the normal symbol path for matches/EOB.
                     if Available >= 9 and then Written < Output_Length then
                        declare
                           Next_Code : constant Unsigned_16 := Literals.Fast (Natural (Bits and 511));
                           Next_Length : constant Natural := Natural (Shift_Right (Next_Code, 9));
                           Next_Value : constant Natural := Natural (Next_Code and 511);
                        begin
                           if Next_Length > 0 and then Next_Length <= Available and then Next_Value < 256 then
                              Bits := Shift_Right (Bits, Next_Length);
                              Available := Available - Next_Length;
                              Result (Written + 1) := Character'Val (Next_Value);
                              Written := Written + 1;
                           end if;
                        end;
                     end if;
                  elsif Value = 256 then
                     exit;
                  elsif Value > 285 then
                     raise Invalid_Stream with "Reserved DEFLATE length code";
                  else
                     declare
                        Length : constant Positive := Length_Base (Value) + Get_Bits (Length_Extra (Value));
                        Code : constant Natural := Symbol (Distance);
                     begin
                        if Code > 29 then
                           raise Invalid_Stream with "Reserved DEFLATE distance code";
                        end if;
                        Copy_Match (Distance_Base (Code) + Get_Bits (Distance_Extra (Code)), Length);
                     end;
                  end if;
               end loop;
            end Decode_Codes;
         begin
            if Metadata.zip_type = 0 then
               Copy_Aligned (Output_Length);
            else
               loop
                  declare
                     Final : constant Boolean := Get_Bits (1) = 1;
                     Format : constant Natural := Get_Bits (2);
                  begin
                     case Format is
                        when 0 =>
                           Bits := Shift_Right (Bits, Available mod 8);
                           Available := Available - Available mod 8;
                           declare
                              Count : constant Natural := Get_Bits (16);
                              Complement : constant Natural := Get_Bits (16);
                           begin
                              if (Unsigned_16 (Count) xor Unsigned_16 (Complement)) /= 16#FFFF# then
                                 raise Invalid_Stream with "Invalid stored DEFLATE block length";
                              end if;
                              Copy_Aligned (Count);
                           end;
                        when 1 => Decode_Codes (Fixed_Literal_Tree, Fixed_Distance_Tree);
                        when 2 =>
                           declare
                              Literals, Distance : Huffman_Tree;
                           begin
                              Dynamic_Trees (Literals, Distance);
                              Decode_Codes (Literals, Distance);
                           end;
                        when others => raise Invalid_Stream with "Reserved DEFLATE block type";
                     end case;
                     exit when Final;
                  end;
               end loop;
            end if;
            if Written /= Output_Length then
               raise Invalid_Stream with "Decompressed payload is shorter than its declared size";
            elsif Epub.Checksums.CRC32 (Result) /= Metadata.dd.crc_32 then
               raise Invalid_Stream with "ZIP payload CRC mismatch";
            end if;
         end;
         Epub.Performance.Stop (Epub.Performance.Decompression);
      end return;
   end Decode;
end Epub.Inflate;

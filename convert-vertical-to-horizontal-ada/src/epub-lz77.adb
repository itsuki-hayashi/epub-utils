--  Owned match-finder subset with a rewritten Info-ZIP level-9 path.
--  Rich is retained for baseline comparison; unrelated matchers are omitted.
--  Legal licensing note:

--  Copyright (c) 2016 .. 2020 Gautier de Montmollin (maintainer of the Ada version)
--  SWITZERLAND

--  Permission is hereby granted, free of charge, to any person obtaining a copy
--  of this software and associated documentation files (the "Software"), to deal
--  in the Software without restriction, including without limitation the rights
--  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--  copies of the Software, and to permit persons to whom the Software is
--  furnished to do so, subject to the following conditions:

--  The above copyright notice and this permission notice shall be included in
--  all copies or substantial portions of the Software.

--  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
--  THE SOFTWARE.

--  NB: this is the MIT License, as found 21-Aug-2016 on the site
--  http://www.opensource.org/licenses/mit-license.php

with Epub.Word_Operations;
with Epub.Performance;
package body Epub.LZ77 is
   use Interfaces;
   type Integer_M32 is range -2**31 .. 2**31 - 1;
   procedure Encode (Maximum_Chain : Chain_Limit := 4096) is
    procedure LZ77_by_Rich is
      --  * PROG2.C [lz77a.c]                                             *
      --  * Simple Hashing LZ77 Sliding Dictionary Compression Program    *
      --  * By Rich Geldreich, Jr. October, 1993                          *
      --  * Originally compiled with QuickC v2.5 in the small model.      *
      --  * This program uses more efficient code to delete strings from  *
      --  * the sliding dictionary compared to PROG1.C, at the expense of *
      --  * greater memory requirements. See the HashData and DeleteData  *
      --  * subroutines.                                                  *
      --
      --  Comments by GdM, 2019+ appear in square brackets: [...]

      --  Set this to True for a greedy encoder.
      GREEDY : constant Boolean := False;  --  [original: False]

      --  Ratio vs. speed constant [ Is it really a ratio? ].
      --  The larger this constant, the better the compression.
      MAXCOMPARES : constant := 4096;  --  [original: 75; good: 2400; from Info-Zip: 4096]

      --  Unused entry code.
      NIL : constant := 16#FFFF#;

      --  /* bits per symbol- normally 8 for general purpose compression */
      --  #define CHARBITS : constant := 8;  [ NB: dictionary uses char (byte) ]

      --  Minimum match length & maximum match length.
      THRESHOLD_Rich : constant := 2;
      MATCHBITS      : constant := 8;  --  [original: 4]
      --  [original: 2 ** MATCHBITS + THRESHOLD - 1]
      MAXMATCH  : constant := 2 ** MATCHBITS + THRESHOLD_Rich;  -- 258 is Deflate-friendly.

      --  Sliding dictionary size and hash table's size.
      --  Some combinations of HASHBITS and THRESHOLD values will not work
      --  correctly because of the way this program hashes strings.

      DICTBITS : constant := 15;  --  [original: 13]
      HASHBITS : constant := 15;  --  Fewer false chains; keep the 4096-search quality budget.
      --
      DICTSIZE : constant := 2 ** DICTBITS;
      HASHSIZE : constant := 2 ** HASHBITS;

      --  # bits to shift after each XOR hash
      --  This constant must be high enough so that only THRESHOLD + 1
      --  characters are in the hash accumulator at one time.

      SHIFTBITS : constant := ((HASHBITS + THRESHOLD_Rich) / (THRESHOLD_Rich + 1));

      --  Sector size constants [the dictionary is partitoned in sectors].

      SECTORBIT : constant := 13;  --  [original: 10; OK: 13]
      SECTORLEN : constant := 2 ** SECTORBIT;

      HASH_MASK_1 : constant := 16#8000#;  --  [ was called HASHFLAG1 ]
      HASH_MASK_2 : constant := 16#7FFF#;  --  [ was called HASHFLAG2 ]

      --  Dictionary plus MAXMATCH extra chars for string comparisions.
      type Dictionary is array (Integer_M32 range <>) of Byte;
      dict : Dictionary (0 .. DICTSIZE + MAXMATCH - 1);
      function Matching_Prefix is new Epub.Word_Operations.Matching_Prefix (Integer_M32, Dictionary);
      function Prefix_At (Start, Count : Integer_M32) return Match_Prefix is
         Result : Match_Prefix := [others => 0];
      begin
         for Index in 1 .. Integer'Min (Result'Length, Integer (Count)) loop
            Result (Index) := dict (Start + Integer_M32 (Index - 1));
         end loop;
         return Result;
      end Prefix_At;

      subtype Unsigned_int is Unsigned_16;

      --  Hash table & link list tables.

      --  [ So far we index the hash table with Integer (minimum 16 bit signed) ]
      hash       : array (0 .. HASHSIZE - 1) of Unsigned_int := [others => NIL];
      --  [ nextlink: in lz77a.c: only through DICTSIZE - 1,
      --    although Init has: nextlink[DICTSIZE] = NIL. In doubt we set the
      --    'Last to DICTSIZE and fill everything with NIL... ]
      nextlink   : array (Integer_M32'(0) .. DICTSIZE)     of Unsigned_int := [others => NIL];
      lastlink   : array (Integer_M32'(0) .. DICTSIZE - 1) of Unsigned_int := [others => NIL];

      --  Loads dictionary with characters from the input stream.
      --
      procedure Load_Dict (dictpos : Integer_M32; actually_read : out Integer_M32) is
        i : Integer_M32 := 0;
      begin
        while More_Bytes loop
          dict (dictpos + i) := Read_Byte;
          i := i + 1;
          exit when i = SECTORLEN;
        end loop;

        --  Since the dictionary is a ring buffer, copy the characters at
        --  the very start of the dictionary to the end
        --  [this avoids having to use an "and" or a "mod" operator when searching].
        --
        if dictpos = 0 then
          for j in Integer_M32'(0) .. MAXMATCH - 1 loop
            dict (j + DICTSIZE) := dict (j);
          end loop;
        end if;

        actually_read := i;
      end Load_Dict;

      --  Deletes data from the dictionary search structures
      --  This is only done when the number of bytes to be
      --  compressed exceeds the dictionary's size.
      --
      procedure Delete_Data (dictpos : Integer_M32) is
        j, k : Integer_M32;
      begin
        --  Delete all references to the sector being deleted.
        k := dictpos + SECTORLEN;
        for i in dictpos .. k - 1 loop
          j := Integer_M32 (lastlink (i));
          if (Unsigned_int (j) and HASH_MASK_1) /= 0 then
            if j /= NIL then
              hash (Integer (Unsigned_int (j) and HASH_MASK_2)) := NIL;
            end if;
          else
            nextlink (j) := NIL;
          end if;
        end loop;
      end Delete_Data;

      --  Hash data just entered into dictionary.
      --  XOR hashing is used here, but practically any hash function will work.
      --
      procedure Hash_Data (dictpos, bytestodo : Integer_M32) is
        j : Integer;
        k : Integer_M32;
      begin
        if bytestodo <= THRESHOLD_Rich then  -- Not enough bytes in sector for match?
          nextlink (dictpos .. dictpos + bytestodo - 1) := [others => NIL];
          lastlink (dictpos .. dictpos + bytestodo - 1) := [others => NIL];
        else
          --  Matches can't cross sector boundaries.
          nextlink (dictpos + bytestodo - THRESHOLD_Rich .. dictpos + bytestodo - 1) := [others => NIL];
          lastlink (dictpos + bytestodo - THRESHOLD_Rich .. dictpos + bytestodo - 1) := [others => NIL];

          j :=  Integer (
                  Shift_Left (Unsigned_int (dict (dictpos)), SHIFTBITS)
                  xor
                  Unsigned_int (dict (dictpos + 1))
                );

          k := dictpos + bytestodo - THRESHOLD_Rich;  --  Calculate end of sector.

          for i in dictpos ..  k - 1 loop
            j := Integer (
                  (Shift_Left (Unsigned_int (j), SHIFTBITS) and (HASHSIZE - 1))
                   xor
                   Unsigned_int (dict (i + THRESHOLD_Rich))
                 );
            declare
              --  16#FFFF# is the linked-list sentinel. Reserve hash slot
              --  16#7FFF# so tagging a head can never collide with NIL.
              --  Keep j unchanged for the next rolling-hash update.
              bucket : constant Integer := (if j = HASH_MASK_2 then j - 1 else j);
            begin
              lastlink (i) := Unsigned_int (bucket) or HASH_MASK_1;
              nextlink (i) := hash (bucket);
              if nextlink (i) /= NIL then
                lastlink (Integer_M32 (nextlink (i))) := Unsigned_int (i);
              end if;
              hash (bucket) := Unsigned_int (i);
            end;
          end loop;
        end if;
      end Hash_Data;

      matchlength, matchpos : Integer_M32;

      --  Finds match for string at position dictpos.
      --  This search code finds the longest AND closest
      --  match for the string at dictpos.
      --
      procedure Find_Match (dictpos, startlen : Integer_M32) is
        i, j : Integer_M32;
        match_byte : Byte;
      begin
        i := dictpos;
        matchlength := startlen;
        match_byte := dict (dictpos + matchlength);
        --
        Chances :
        for compare_count in 1 .. MAXCOMPARES loop
          i := Integer_M32 (nextlink (i));  --  Get next string in list.
          if i = NIL then
            return;
          end if;
          --
          if dict (i + matchlength) = match_byte then  --  Possible larger match?
            j := Integer_M32 (Matching_Prefix (dict, dictpos, i, MAXMATCH));
            --
            if j > matchlength then  --  Found larger match?
              matchlength := j;
              matchpos    := i;
              if matchlength = MAXMATCH then
                return;  --  Exit if largest possible match.
              end if;
              match_byte := dict (dictpos + matchlength);
            end if;
          end if;
        end loop Chances;  --  Keep on trying until we run out of chances.
      end Find_Match;

      --  Finds dictionary matches for characters in current sector.
      --
      procedure Dict_Search (dictpos, bytestodo : Integer_M32) is
        i, j : Integer_M32;
        matchlen1, matchpos1 : Integer_M32;
        --
        procedure Write_literal_pos_i is
        pragma Inline (Write_literal_pos_i);
        begin
          Write_Literal (dict (i));
          i := i + 1;
          j := j - 1;
        end Write_literal_pos_i;
      begin
        i := dictpos;
        j := bytestodo;

        if not GREEDY then  --  Non-greedy search loop (slow).

          while j /= 0 loop  --  Loop while there are still characters left to be compressed.
            Find_Match (i, THRESHOLD_Rich);

            if matchlength > THRESHOLD_Rich then
              matchlen1 := matchlength;
              matchpos1 := matchpos;

              loop
                Find_Match (i + 1, matchlen1);

                if matchlength > matchlen1 then
                  matchlen1 := matchlength;
                  matchpos1 := matchpos;
                  Write_literal_pos_i;
                else
                  if matchlen1 > j then
                    matchlen1 := j;
                    if matchlen1 <= THRESHOLD_Rich then
                      Write_literal_pos_i;
                      exit;
                    end if;
                  end if;

                  Write_DL_Code (
                    length   => Integer (matchlen1),
                    --  [The subtraction happens modulo 2**n, needs to be cleaned modulo 2**DICTSIZE]
                    distance => Integer ((Unsigned_32 (i) - Unsigned_32 (matchpos1)) and (DICTSIZE - 1)),
                    Prefix => Prefix_At (i, matchlen1)
                  );
                  i := i + matchlen1;
                  j := j - matchlen1;
                  exit;
                end if;
              end loop;

            else
              Write_literal_pos_i;
            end if;

          end loop;  --  while j /= 0

        else  --  Greedy search loop (fast).

          while j /= 0 loop  --  Loop while there are still characters left to be compressed.

            Find_Match (i, THRESHOLD_Rich);

            if matchlength > j then
              matchlength := j;     --  Clamp matchlength.
            end if;

            if matchlength > THRESHOLD_Rich then  --  Valid match?
              Write_DL_Code (
                length   => Integer (matchlength),
                --  [The subtraction happens modulo 2**n, needs to be cleaned modulo 2**DICTSIZE]
                distance => Integer ((Unsigned_32 (i) - Unsigned_32 (matchpos)) and (DICTSIZE - 1)),
                Prefix => Prefix_At (i, matchlength)
              );
              i := i + matchlength;
              j := j - matchlength;
            else
              Write_literal_pos_i;
            end if;
          end loop;

        end if;  --  Greedy or not.

      end Dict_Search;

      procedure Encode_Rich is
        dictpos, actual_read : Integer_M32 :=  0;
        deleteflag : Boolean := False;
      begin
        loop
          --  Delete old data from dictionary.
          if deleteflag then
            Delete_Data (dictpos);
          end if;

          --  Grab more data to compress.
          Load_Dict (dictpos, actual_read);
          exit when actual_read = 0;

          --  Hash the data.
          Hash_Data (dictpos, actual_read);

          --  Find dictionary matches.
          Dict_Search (dictpos, actual_read);

          dictpos := dictpos + SECTORLEN;

          --  Wrap back to beginning of dictionary when it's full.
          if dictpos = DICTSIZE then
            dictpos := 0;
            deleteflag := True;   --  Ok to delete now.
          end if;
        end loop;
      end Encode_Rich;

    begin
      Encode_Rich;
    end LZ77_by_Rich;
      procedure Encode_Info_Zip_9 is
         --  Owned, bounded rewrite of the Info-ZIP lazy-match algorithm in
         --  Zip-Ada's LZ77_using_IZ. The level-9 search limits also appear in
         --  zlib-ng: good=32, lazy=258, nice=258, chain=4096. Jean-Loup
         --  Gailly's original algorithm is credited in that reference.
         Window_Size : constant := 32_768;
         Window_Capacity : constant := 2 * Window_Size;
         Minimum_Lookahead : constant := 262;
         Maximum_Distance : constant := Window_Size - Minimum_Lookahead;
         Maximum_Match : constant := 258;
         Hash_Mask : constant := 32_767;
         Hash_Bits : constant := 17;
         type Unaligned_Word is mod 2 ** 32 with Size => 32, Alignment => 1;
         Window : Byte_Array (0 .. Window_Capacity - 1);
         type Link_Array is array (Natural range 0 .. Window_Size - 1) of Unsigned_16;
         Head : array (Natural range 0 .. 2 ** Hash_Bits - 1) of Unsigned_16 := [others => 0];
         Previous : Link_Array := [others => 0];
         Position, Finish, Match_Start : Natural := 0;
         Hash : Unsigned_32 := 0;
         EOF : Boolean := False;
         function Matching_Prefix is new Epub.Word_Operations.Matching_Prefix (Natural, Byte_Array);

         procedure Update_Hash (Value : Byte) is
         begin
            Hash := (Shift_Left (Hash, 5) xor Unsigned_32 (Value)) and Hash_Mask;
         end Update_Hash;

         procedure Insert (Prior : out Natural) is
            Slot : constant Natural := Position mod Window_Size;
         begin
            pragma Assert (Finish - Position >= 3);
            if Strategy = Info_Zip_9_Knuth then
               if Finish - Position < 4 then
                  Prior := 0;
                  return;
               end if;
               --  Both supported targets are little-endian x86-64. The
               --  lookahead check bounds the entire unaligned four-byte load.
               --  Multiplicative hashing avoids rolling dependencies and
               --  filters candidates by four bytes. Shorter matches may be
               --  omitted; emitted tokens still undergo the usual checks.
               declare
                  Key : Unaligned_Word with Import, Address => Window (Position)'Address;
               begin
                  Hash := Shift_Right (Unsigned_32 (Key) * 16#9E37_79B1#, 32 - Hash_Bits);
               end;
            else
               Update_Hash (Window (Position + 2));
            end if;
            Prior := Natural (Head (Natural (Hash)));
            Previous (Slot) := Unsigned_16 (Prior);
            Head (Natural (Hash)) := Unsigned_16 (Position);
         end Insert;
         pragma Inline_Always (Insert);

         procedure Fill is
         begin
            if Position >= Window_Size + Maximum_Distance then
               Window (0 .. Window_Size - 1) := Window (Window_Size .. Window_Capacity - 1);
               Position := Position - Window_Size;
               Finish := Finish - Window_Size;
               Match_Start := (if Match_Start >= Window_Size then Match_Start - Window_Size else 0);
               for Index in Head'Range loop
                  Head (Index) := (if Head (Index) >= Window_Size then Head (Index) - Window_Size else 0);
               end loop;
               for Index in Previous'Range loop
                  Previous (Index) := (if Previous (Index) >= Window_Size then Previous (Index) - Window_Size else 0);
               end loop;
            end if;
            while Finish < Window_Capacity and then not EOF loop
               if Bulk_Input then
                  declare
                     Count : Natural := 0;
                  begin
                     Read_Span (Window (Finish .. Window'Last), Count);
                     if Count > Window_Capacity - Finish then
                        raise Constraint_Error with "Matcher bulk read exceeds window";
                     end if;
                     Finish := Finish + Count;
                     EOF := Count = 0;
                     Epub.Performance.Add (Epub.Performance.Matcher_Input_Bytes, Count);
                  end;
               elsif More_Bytes then
                  Window (Finish) := Read_Byte;
                  Finish := Finish + 1;
                  Epub.Performance.Add (Epub.Performance.Matcher_Input_Bytes);
               else
                  EOF := True;
               end if;
            end loop;
         end Fill;

         function Find_Match (Prior, Prior_Length : Natural) return Natural is
            type Unaligned_Halfword is mod 2 ** 16 with Size => 16, Alignment => 1;
            function Halfword (Offset : Natural) return Unsigned_16 with Inline_Always is
               Value : Unaligned_Halfword with Import, Address => Window (Offset)'Address;
            begin
               return Unsigned_16 (Value);
            end Halfword;
            Candidate : Natural := Prior;
            Best : Natural := Prior_Length;
            Limit : constant Natural := (if Position > Maximum_Distance then Position - Maximum_Distance else 0);
            Count : Positive :=
              (if Prior_Length >= 32 then Positive'Max (1, Maximum_Chain / 4) else Maximum_Chain);
            Maximum : constant Natural := Natural'Min (Maximum_Match, Finish - Position);
            Probe_Head, Probe_Tail : Unsigned_16;
         begin
            Epub.Performance.Add (Epub.Performance.Match_Searches);
            if Best >= Maximum then
               return Best;
            end if;
            Probe_Head := Halfword (Position);
            Probe_Tail := Halfword (Position + Best - 1);
            while Candidate > Limit and then Candidate < Position loop
               Epub.Performance.Add (Epub.Performance.Match_Candidates);
               if Halfword (Candidate + Best - 1) = Probe_Tail
                 and then Halfword (Candidate) = Probe_Head
               then
                  declare
                     Length : constant Natural := Matching_Prefix (Window, Position, Candidate, Maximum);
                  begin
                     if Length > Best then
                        Best := Length;
                        Match_Start := Candidate;
                        exit when Best = Maximum;
                        Probe_Tail := Halfword (Position + Best - 1);
                     end if;
                  end;
               end if;
               Candidate := Natural (Previous (Candidate mod Window_Size));
               exit when Count = 1;
               Count := Count - 1;
            end loop;
            return Best;
         end Find_Match;

         Prior, Match_Length : Natural := 2;
         Pending : Boolean := False;
      begin
         Fill;
         if Finish < 3 then
            for Index in 0 .. Integer (Finish) - 1 loop
               Write_Literal (Window (Index));
            end loop;
            return;
         end if;
         if Strategy = Info_Zip_9 then
            Update_Hash (Window (0));
            Update_Hash (Window (1));
         end if;
         while Position < Finish loop
            if Finish - Position >= 3 then
               Insert (Prior);
            end if;
            declare
               Previous_Length : constant Natural := Match_Length;
               Previous_Start : constant Natural := Match_Start;
            begin
               Match_Length := 2;
               if Prior /= 0 and then Previous_Length < Maximum_Match
                 and then Position - Prior <= Maximum_Distance
                 and then Finish - Position >= 3
               then
                  Match_Length := Natural'Min (Find_Match (Prior, Previous_Length), Finish - Position);
                  if Match_Length = 3 and then Position - Match_Start > 4096 then
                     Match_Length := 2;
                  end if;
               end if;
               if Previous_Length >= 3 and then Match_Length <= Previous_Length then
                  pragma Assert (Pending and then Position > Previous_Start);
                  declare
                     Prefix : Match_Prefix := [others => 0];
                  begin
                     for Index in 1 .. Natural'Min (Prefix'Length, Previous_Length) loop
                        Prefix (Index) := Window (Position + Index - 2);
                     end loop;
                     Write_DL_Code (Position - 1 - Previous_Start, Previous_Length, Prefix);
                  end;
                  for Step in 1 .. Previous_Length - 1 loop
                     Position := Position + 1;
                     if Step < Previous_Length - 1 and then Finish - Position >= 3 then
                        Insert (Prior);
                     end if;
                  end loop;
                  Pending := False;
                  Match_Length := 2;
               elsif Pending then
                  Write_Literal (Window (Position - 1));
                  Position := Position + 1;
               else
                  Pending := True;
                  Position := Position + 1;
               end if;
            end;
            if Finish - Position < Minimum_Lookahead and then not EOF then
               Fill;
            end if;
         end loop;
         if Pending then
            Write_Literal (Window (Position - 1));
         end if;
      end Encode_Info_Zip_9;
   begin
      case Strategy is
         when Rich => LZ77_by_Rich;
         when Info_Zip_9 | Info_Zip_9_Knuth => Encode_Info_Zip_9;
      end case;
   end Encode;
end Epub.LZ77;

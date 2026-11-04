--  Owned adaptation of Zip-Ada 62.0.0. Uses owned Huffman and level-9 matching.
--  Legal licensing note:

--  Copyright (c) 2009 .. 2026 Gautier de Montmollin
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

--  NB: this is the MIT License, as found on the site
--  http://www.opensource.org/licenses/mit-license.php

--  Level-9 lazy matching feeds bounded token blocks. For each block, the
--  entropy encoder compares stored, fixed, dynamic and recycled-code costs.
--  Source attribution and licensing details are recorded in CODEC_ORIGINS.md.
with Epub.Huffman.Encoding;
with Epub.Huffman.Length_Limited_Coding;
with Epub.Performance;
with Epub.LZ77;

with Ada.Unchecked_Deallocation;

procedure Epub.Compression.Deflate
  (input,
   output           : in out Zip_Streams.Root_Zipstream_Type'Class;
   input_size       :        Zip_64_Data_Size_Type;
   CRC              : in out Interfaces.Unsigned_32;  --  only updated here
   output_size      :    out Zip_64_Data_Size_Type;
   compression_ok   :    out Boolean;  --  indicates compressed < uncompressed
   Fast_Trial       :        Boolean)
is
  use Interfaces;

  -------------------------------------
  -- Buffered I/O - byte granularity --
  -------------------------------------

  IO_buffers : IO_Buffers_Type;

  procedure Put_byte (B : Byte) is  --  Put a byte, at the byte granularity level
  pragma Inline (Put_byte);
  begin
    IO_buffers.OutBuf.all (IO_buffers.OutBufIdx) := B;
    IO_buffers.OutBufIdx := IO_buffers.OutBufIdx + 1;
    if IO_buffers.OutBufIdx > IO_buffers.OutBuf'Last then
      Write_Block (IO_buffers, input_size, output, output_size);
    end if;
  end Put_byte;

  procedure Flush_byte_buffer is
  begin
    if IO_buffers.OutBufIdx > 1 then
      Write_Block (IO_buffers, input_size, output, output_size);
    end if;
  end Flush_byte_buffer;

  ------------------------------------------------------
  --  Bit code buffer, for sending data at bit level  --
  ------------------------------------------------------

  --  Output buffer. Bits are inserted starting at the right (least
  --  significant bits). The width of bit_buffer must be at least 16 bits.
  subtype U32 is Unsigned_32;
  bit_buffer : Unsigned_64 := 0;
  --  Number of valid bits in bit_buffer.  All bits above the last valid bit are always zero.
  valid_bits : Integer := 0;

  procedure Put_Word (Value : Unsigned_32) with Inline is
    type Unaligned_Word is mod 2 ** 32 with Size => 32, Alignment => 1;
  begin
    if IO_buffers.OutBuf'Length - IO_buffers.OutBufIdx + 1 < 4 then
      Flush_byte_buffer;
    end if;
    declare
      Target : Unaligned_Word with Import,
        Address => IO_buffers.OutBuf.all (IO_buffers.OutBufIdx)'Address;
    begin
      --  Supported Windows/Linux x86-64 targets are little endian.
      Target := Unaligned_Word (Value);
    end;
    IO_buffers.OutBufIdx := IO_buffers.OutBufIdx + 4;
    if IO_buffers.OutBufIdx > IO_buffers.OutBuf'Last then
      Flush_byte_buffer;
    end if;
  end Put_Word;

  procedure Flush_bit_buffer is
  begin
    while valid_bits > 0 loop
      Put_byte (Byte (bit_buffer and 16#FF#));
      bit_buffer := Shift_Right (bit_buffer, 8);
      valid_bits := Integer'Max (0, valid_bits - 8);
    end loop;
    bit_buffer := 0;
  end Flush_bit_buffer;

  --  Bit codes are at most 15 bits for Huffman codes,
  --  or 13 for explicit codes (distance extra bits).
  subtype Code_Size_Type is Integer range 1 .. 15;

  --  Send a value on a given number of bits.
  procedure Put_Bits (code : U32; code_size : Code_Size_Type) with Inline is
  begin
    --  At most 31 buffered bits plus a 15-bit code fit without splitting.
    bit_buffer := bit_buffer or Shift_Left (Unsigned_64 (code), valid_bits);
    valid_bits := valid_bits + code_size;
    if valid_bits >= 32 then
      Put_Word (Unsigned_32 (bit_buffer and 16#FFFF_FFFF#));
      valid_bits := valid_bits - 32;
      bit_buffer := Shift_Right (bit_buffer, 32);
    end if;
  end Put_Bits;

  ------------------------------------------------------
  -- Deflate, post LZ encoding, with Huffman encoding --
  ------------------------------------------------------

  --  The Huffman code set (and therefore the Huffman tree) is completely determined by
  --  the bit length to be used for reaching leaf nodes, thanks to two special
  --  rules (explanation in RFC 1951, section 3.2.2).
  --
  --  So basically the process is the following:
  --
  --     (A) Gather statistics (just counts) for the alphabet.
  --     (B) Turn these counts into code lengths, by calling Length_limited_Huffman_code_lengths.
  --     (C) Build Huffman codes (the bits to be sent) with a call to Prepare_Huffman_codes.
  --
  --  In short:
  --
  --     data -> (A) -> stats -> (B) -> Huffman codes' bit lengths -> (C) -> Huffman codes

  type Bit_Length_Array is array (Natural range <>) of Natural;

  subtype Alphabet_lit_len is Natural range 0 .. 287;
  subtype Bit_length_array_lit_len is Bit_Length_Array (Alphabet_lit_len);
  subtype Alphabet_dis is Natural range 0 .. 31;
  subtype Bit_length_array_dis is Bit_Length_Array (Alphabet_dis);

  type Deflate_Huff_Descriptors is record
    --  Tree descriptor for Literal, EOB or Length encoding
    lit_len : Huffman.Encoding.Descriptor (0 .. 287);
    --  Tree descriptor for Distance encoding
    dis : Huffman.Encoding.Descriptor (0 .. 31);
  end record;
  --  NB: Appnote: "Literal codes 286-287 and distance codes 30-31 are never used
  --                  but participate in the Huffman construction."
  --  Setting upper bound to 285 for literals leads to invalid codes, sometimes.

  --  Copy bit length vectors into Deflate Huffman descriptors

  function Build_descriptors (
    bl_for_lit_len : Bit_length_array_lit_len;
    bl_for_dis     : Bit_length_array_dis
  )
  return Deflate_Huff_Descriptors
  is
    new_d : Deflate_Huff_Descriptors;
  begin
    for i in new_d.lit_len'Range loop
      new_d.lit_len (i) := (bit_length => bl_for_lit_len (i), code => Huffman.Encoding.invalid);
      
    end loop;
    for i in new_d.dis'Range loop
      new_d.dis (i) := (bit_length => bl_for_dis (i), code => Huffman.Encoding.invalid);
      
    end loop;
    
    return new_d;
  end Build_descriptors;

  type Count_type is range 0 .. Zip_64_Data_Size_Type'Last / 2 - 1;
  type Stats_type is array (Natural range <>) of Count_type;

  --  The following is a translation of Zopfli's OptimizeHuffmanForRle (v. 11-May-2016).
  --  Possible gain: shorten the compression header containing the Huffman trees' bit lengths.
  --  Possible loss: since the stats do not correspond anymore exactly to the data
  --  to be compressed, the Huffman trees might be suboptimal.
  --
  --  Zopfli comment:
  --    Changes the population counts in a way that the consequent Huffman tree
  --    compression, especially its rle-part, will be more likely to compress this data
  --    more efficiently.
  --
  procedure Tweak_for_better_RLE (counts : in out Stats_type) is
    length : Integer := counts'Length;
    stride : Integer;
    symbol, sum, limit, new_count : Count_type;
    good_for_rle : array (counts'Range) of Boolean := (others => False);
  begin
    --  1) We don't want to touch the trailing zeros. We may break the
    --     rules of the format by adding more data in the distance codes.
    loop
      if length = 0 then
        return;
      end if;
      exit when counts (length - 1) /= 0;
      length := length - 1;
    end loop;
    --  Now counts(0..length - 1) does not have trailing zeros.
    --
    --  2) Let's mark all population counts that already can be encoded with an rle code.
    --
    --  Let's not spoil any of the existing good rle codes.
    --  Mark any seq of 0's that is longer than 5 as a good_for_rle.
    --  Mark any seq of non-0's that is longer than 7 as a good_for_rle.
    symbol := counts (0);
    stride := 0;
    for i in 0 .. length loop
      if i = length or else counts (i) /= symbol then
        if (symbol = 0 and then stride >= 5) or else (symbol /= 0 and then stride >= 7) then
          for k in 0 .. stride - 1 loop
            good_for_rle (i - k - 1) := True;
          end loop;
        end if;
        stride := 1;
        if i /= length then
          symbol := counts (i);
        end if;
      else
        stride := stride + 1;
      end if;
    end loop;
    --  3) Let's replace those population counts that lead to more rle codes.
    stride := 0;
    limit := counts (0);
    sum := 0;
    for i in 0 .. length loop
      if i = length or else good_for_rle (i)
          or else (i > 0 and then good_for_rle (i - 1))  --  Added from Brotli, item #1
          --  Heuristic for selecting the stride ranges to collapse.
          or else abs (counts (i) - limit) >= 4
      then
        if stride >= 4 or else (stride >= 3 and then sum = 0) then
          --  The stride must end, collapse what we have, if we have enough (4).
          --  GdM: new_count is the average of counts on the stride's interval, upper-rounded.
          new_count := Count_type'Max (1, (sum + Count_type (stride) / 2) / Count_type (stride));
          if sum = 0 then
            --  Don't make an all zeros stride to be upgraded to ones.
            new_count := 0;
          end if;
          for k in 0 .. stride - 1 loop
            --  We don't want to change value at counts(i),
            --  that is already belonging to the next stride. Thus - 1.
            counts (i - k - 1) := new_count;  --  GdM: Replace histogram value by averaged value.
          end loop;
        end if;
        stride := 0;
        sum := 0;
        if i < length - 3 then
          --  All interesting strides have a count of at least 4, at least when non-zeros.
          --  GdM: limit is the average of next 4 counts, upper-rounded.
          limit := (counts (i) + counts (i + 1) + counts (i + 2) + counts (i + 3) + 2) / 4;
        elsif i < length then
          limit := counts (i);
        else
          limit := 0;
        end if;
      end if;
      stride := stride + 1;
      if i /= length then
        sum := sum + counts (i);
      end if;
    end loop;
  end Tweak_for_better_RLE;

  subtype Stats_lit_len_type is Stats_type (Alphabet_lit_len);
  subtype Stats_dis_type is Stats_type (Alphabet_dis);

  --  Phase (B) : we turn statistics into Huffman bit lengths.
  function Build_descriptors (
    stats_lit_len  : Stats_lit_len_type;
    stats_dis      : Stats_dis_type
  )
  return Deflate_Huff_Descriptors
  is
    bl_for_lit_len : Bit_length_array_lit_len;
    bl_for_dis     : Bit_length_array_dis;
    procedure LLHCL_lit_len is new
      Epub.Huffman.Length_Limited_Coding
        (Alphabet_lit_len, Count_type, Stats_lit_len_type, Bit_length_array_lit_len, 15);
    procedure LLHCL_dis is new
      Epub.Huffman.Length_Limited_Coding
        (Alphabet_dis, Count_type, Stats_dis_type, Bit_length_array_dis, 15);
    stats_dis_copy : Stats_dis_type := stats_dis;
    --
    procedure Patch_statistics_for_buggy_decoders is
      --  Workaround for buggy Info-Zip decoder versions.
      --  See "PatchDistanceCodesForBuggyDecoders" in Zopfli's deflate.c
      --  NB: here, we patch the statistics and not the resulting bit lengths,
      --      to be sure we avoid invalid Huffman code sets in the end.
      --  The decoding bug concerns Zlib v.<= 1.2.1, UnZip v.<= 6.0, WinZip v.<=10.0.
      used : Natural := 0;
    begin
      for i in stats_dis_copy'Range loop
        if stats_dis_copy (i) /= 0 then
          used := used + 1;
        end if;
      end loop;
      case used is
        when 0 =>  --  No distance code used at all (data must be almost random).
          stats_dis_copy (0 .. 1) := [1, 1];
        when 1 =>
          if stats_dis_copy (0) = 0 then
            stats_dis_copy (0) := 1;  --  Now, code 0 and some other code have non-zero counts.
          else
            stats_dis_copy (1) := 1;  --  Now, codes 0 and 1 have non-zero counts.
          end if;
        when others =>
          null;  --  No workaround needed when 2 or more distance codes are defined.
      end case;
    end Patch_statistics_for_buggy_decoders;
  begin
    Patch_statistics_for_buggy_decoders;
    LLHCL_lit_len (stats_lit_len, bl_for_lit_len);  --  Call the magic algorithm for setting
    LLHCL_dis (stats_dis_copy, bl_for_dis);         --    up Huffman lengths of both trees
    return Build_descriptors (bl_for_lit_len, bl_for_dis);
  end Build_descriptors;

  --  Another original part in the Taillaule algorithm: the possibility of recycling
  --  Huffman codes. It is possible only if previous block was not stored and if
  --  the new block's used alphabets are included in the old block's used alphabets.
  function Recyclable (h_old, h_new : Deflate_Huff_Descriptors) return Boolean is
  begin
    for i in h_old.lit_len'Range loop
      if h_old.lit_len (i).bit_length = 0 and h_new.lit_len (i).bit_length > 0 then
        return False;  --  Code used in new, but not in old
      end if;
    end loop;
    for i in h_old.dis'Range loop
      if h_old.dis (i).bit_length = 0 and h_new.dis (i).bit_length > 0 then
        return False;  --  Code used in new, but not in old
      end if;
    end loop;
    return True;
  end Recyclable;

  --  Phase (C): the Prepare_Huffman_Codes procedure finds the Huffman code
  --  for each value, given the bit length imposed as input.

  function Prepare_Huffman_Codes (dhd : Deflate_Huff_Descriptors) return Deflate_Huff_Descriptors
  is
    dhd_var : Deflate_Huff_Descriptors := dhd;
  begin
    Huffman.Encoding.Prepare_Codes (dhd_var.lit_len, Code_Size_Type'Last, True);
    Huffman.Encoding.Prepare_Codes (dhd_var.dis, Code_Size_Type'Last, True);
    return dhd_var;
  end Prepare_Huffman_Codes;

  --  Emit a variable length Huffman code
  procedure Put_Huffman_Code (lc : Huffman.Encoding.Length_Code_Pair) is
  pragma Inline (Put_Huffman_Code);
  begin
    --  Huffman code of length 0 should never occur: when constructing
    --  the code lengths (LLHCL) any single occurrence in the statistics
    --  will trigger the build of a code length of 1 or more.
    Put_Bits
      (code      => U32 (lc.code),
       code_size => Code_Size_Type (lc.bit_length));  --  Range check for length 0 (if enabled).
  end Put_Huffman_Code;

  --  This is where the "dynamic" Huffman trees are sent before the block's data are sent.
  --
  --  The decoder needs to know in advance the pair of trees (1st tree for literals-eob-LZ
  --  lengths, 2nd tree for LZ distances) for decoding the compressed data.
  --  But this information takes some room. Fortunately Deflate allows for compressing it
  --  with a combination of Huffman and Run-Length Encoding (RLE) to make this header smaller.
  --  Concretely, the trees are described by the bit length of each symbol, so the header's
  --  content is a vector of length max 320, whose contents are in the 0 .. 18 range and typically
  --  look like:  ... 8, 8, 9, 7, 8, 10, 6, 8, 8, 8, 8, 8, 11, 8, 9, 8, ...
  --  Clearly this vector has redundancies and can be sent in a compressed form.
  --  In this example, the RLE will compress the string of 8's with a single code 8, then a code 17
  --  (repeat x times). Anyway, the very frequent 8's will be encoded with a small number of
  --  bits (less than the 5 plain bits, or maximum 7 Huffman-encoded bits
  --  needed for encoding integers in the 0 .. 18 range).
  --
  procedure Put_Compression_Structure
    (dhd           :        Deflate_Huff_Descriptors;
     cost_analysis :        Boolean;     --  If True: just simulate the whole, and count needed bits
     bits          : in out Count_type)  --  This is incremented when cost_analysis = True
  is
    subtype Alphabet is Integer range 0 .. 18;
    type Alpha_Array is new Bit_Length_Array (Alphabet);
    truc_freq, truc_bl : Alpha_Array;
    truc : Huffman.Encoding.Descriptor (Alphabet);
    --  Compression structure: cs_bl is the "big" array with all bit lengths
    --  for compressing data. cs_bl will be sent compressed, too.
    cs_bl : array (1 .. dhd.lit_len'Length + dhd.dis'Length) of Natural;
    last_cs_bl : Natural;
    max_used_lln_code : Alphabet_lit_len := 0;
    max_used_dis_code : Alphabet_dis     := 0;
    --
    procedure Concatenate_all_bit_lengths is
      idx : Natural := 0;
    begin
      for a in reverse Alphabet_lit_len loop
        if dhd.lit_len (a).bit_length > 0 then
          max_used_lln_code := a;
          exit;
        end if;
      end loop;
      for a in reverse Alphabet_dis loop
        if dhd.dis (a).bit_length > 0 then
          max_used_dis_code := a;
          exit;
        end if;
      end loop;
      --  Copy bit lengths for both trees into one array, cs_bl.
      for a in 0 .. max_used_lln_code loop
        idx := idx + 1;
        cs_bl (idx) := dhd.lit_len (a).bit_length;
      end loop;
      for a in 0 .. max_used_dis_code loop
        idx := idx + 1;
        cs_bl (idx) := dhd.dis (a).bit_length;
      end loop;
      last_cs_bl := idx;
    end Concatenate_all_bit_lengths;
    --
    extra_bits_needed : constant array (Alphabet) of Natural :=
       [16 => 2, 17 => 3, 18 => 7, others => 0];
    --
    type Emission_mode is (simulate, effective);
    --
    procedure Emit_data_compression_structures (emit_mode : Emission_mode) is
      procedure Emit_data_compression_atom (x : Alphabet; extra_code : U32 := 0) is
        --  x is a bit length (value in 0..15), or a RLE instruction
      begin
        case emit_mode is
          when simulate =>
            truc_freq (x) := truc_freq (x) + 1;  --  +1 for x's histogram bar
          when effective =>
            Put_Huffman_Code (truc (x));
            declare
              extra_bits : constant Natural := extra_bits_needed (x);
            begin
              if extra_bits > 0 then
                Put_Bits (extra_code, extra_bits);
              end if;
            end;
        end case;
      end Emit_data_compression_atom;
      idx : Natural := 0;
      rep : Positive;  --  Number of times current atom is repeated, >= 1
    begin
      --  Emit the bit lengths, with some RLE encoding (Appnote: 5.5.3; RFC 1951: 3.2.7)
      idx := 1;
      loop
        rep := 1;  --  Current atom, cs_bl(idx), is repeated 1x so far - obvious, isn't it ?
        for j in idx + 1 .. last_cs_bl loop
          exit when cs_bl (j) /= cs_bl (idx);
          rep := rep + 1;
        end loop;
        --  Now rep is the number of repetitions of current atom, including itself.
        if idx > 1 and then cs_bl (idx) = cs_bl (idx - 1) and then rep >= 3
            --  Better repeat a long sequence of zeros by using codes 17 or 18
            --  just after a 138-long previous sequence:
          and then not (cs_bl (idx) = 0 and then rep > 6)
        then
          rep := Integer'Min (rep, 6);
          Emit_data_compression_atom (16, U32 (rep - 3));    -- 16: "Repeat previous 3 to 6 times"
          idx := idx + rep;
        elsif cs_bl (idx) = 0 and then rep >= 3 then
          --  The 0 bit length may occur on long ranges of an alphabet (unused symbols)
          if rep <= 10 then
            Emit_data_compression_atom (17, U32 (rep - 3));  -- 17: "Repeat zero 3 to 10 times"
          else
            rep := Integer'Min (rep, 138);
            Emit_data_compression_atom (18, U32 (rep - 11)); -- 18: "Repeat zero 11 to 138 times"
          end if;
          idx := idx + rep;
        else
          Emit_data_compression_atom (cs_bl (idx));
          idx := idx + 1;
        end if;
        exit when idx > last_cs_bl;
      end loop;
    end Emit_data_compression_structures;
    --  Alphabet permutation for shortening in-use alphabet.
    --  After the RLE codes 16, 17, 18 and the bit length 0, which are assumed to be always used,
    --  the most usual bit lengths (around 8, which is the "neutral" bit length) appear first.
    --  For example, if the rare bit lengths 1 and 15 don't occur in any of the two Huffman trees
    --  for LZ data, then codes 1 and 15 have a length 0 in the local Alphabet and we can omit
    --  sending the last two bit lengths.
    alphabet_permutation : constant array (Alphabet) of Natural :=
       [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    procedure LLHCL is new
      Epub.Huffman.Length_Limited_Coding (Alphabet, Natural, Alpha_Array, Alpha_Array, 7);
    a_non_zero : Alphabet;
  begin
    Concatenate_all_bit_lengths;
    truc_freq := [others => 0];
    Emit_data_compression_structures (simulate);
    --  We have now statistics of all bit lengths occurrences of both Huffman
    --  trees used for compressing the data.
    --  We turn these counts into bit lengths for the local tree
    --  that helps us to store the compression structure in a more compact form.
    LLHCL (truc_freq, truc_bl);  --  Call the magic algorithm for setting up Huffman lengths
    --  At least lengths for codes 16, 17, 18, 0 will always be sent,
    --  even if all other bit lengths are 0 because codes 1 to 15 are unused.
    a_non_zero := 3;
    for a in Alphabet loop
      if a > a_non_zero and then truc_bl (alphabet_permutation (a)) > 0 then
        a_non_zero := a;
      end if;
    end loop;
    if cost_analysis then
      --  In this mode, no data output: we sum up the exact
      --  number of bits needed by the compression header.
      bits := bits + 14 + Count_type (1 + a_non_zero) * 3;
      for a in Alphabet loop
        bits := bits + Count_type (truc_freq (a) * (truc_bl (a) + extra_bits_needed (a)));
      end loop;
    else
      --  We output the compression header to the output stream.
      for a in Alphabet loop
        truc (a).bit_length := truc_bl (a);
      end loop;
      Huffman.Encoding.Prepare_Codes (truc, Code_Size_Type'Last, True);
      --  Output of the compression structure
      Put_Bits (U32 (max_used_lln_code - 256), 5);  --  max_used_lln_code is always >= 256 = EOB code
      Put_Bits (U32 (max_used_dis_code), 5);
      Put_Bits (U32 (a_non_zero - 3), 4);
      --  Save the local alphabet's Huffman lengths. It's the compression structure
      --  for compressing the data compression structure. Easy, isn't it ?
      for a in 0 .. a_non_zero loop
        Put_Bits (U32 (truc (alphabet_permutation (a)).bit_length), 3);
      end loop;
      --  Emit the Huffman lengths for encoding the data, in the local Huffman-encoded fashion.
      Emit_data_compression_structures (effective);
    end if;
  end Put_Compression_Structure;

  End_Of_Block : constant := 256;

  --  Default Huffman trees, for "fixed" blocks, as defined in appnote.txt or RFC 1951
  default_lit_len_bl : constant Bit_length_array_lit_len :=
      [0 .. 143   => 8,  --  For literals ("plain text" bytes)
     144 .. 255   => 9,  --  For more literals ("plain text" bytes)
     End_Of_Block => 7,  --  For EOB (256)
     257 .. 279   => 7,  --  For length codes
     280 .. 287   => 8   --  For more length codes
    ];
  default_dis_bl : constant Bit_length_array_dis := [others => 5];

  Deflate_fixed_descriptors : constant Deflate_Huff_Descriptors :=
    Prepare_Huffman_Codes (Build_descriptors (default_lit_len_bl, default_dis_bl));

  --  Current tree descriptors
  curr_descr : Deflate_Huff_Descriptors := Deflate_fixed_descriptors;

  --  Write a normal, "clear-text" (post LZ, pre Huffman), 8-bit character (literal)
  procedure Put_literal_byte (b : Byte) is
  begin
    Put_Huffman_Code (curr_descr.lit_len (Integer (b)));
  end Put_literal_byte;

  --  Possible ranges for distance and length encoding in the Zip-Deflate format:
  subtype Length_range is Integer range 3 .. 258;
  subtype Distance_range is Integer range 1 .. 32768;

  --  This is where LZ distance-length tokens are written to the output stream.
  --  The Deflate format defines a sort of logarithmic compression, with codes
  --  for various distance and length ranges, plus extra bits for specifying the
  --  exact values. The codes are sent as Huffman codes with variable bit lengths
  --  (nothing to do with the lengths of LZ distance-length tokens).

  --                              Length Codes
  --                              ------------
  --       Extra             Extra              Extra              Extra
  --  Code Bits Length  Code Bits Lengths  Code Bits Lengths  Code Bits Length(s)
  --  ---- ---- ------  ---- ---- -------  ---- ---- -------  ---- ---- ---------
  --   257   0     3     265   1   11,12    273   3   35-42    281   5  131-162
  --   258   0     4     266   1   13,14    274   3   43-50    282   5  163-194
  --   259   0     5     267   1   15,16    275   3   51-58    283   5  195-226
  --   260   0     6     268   1   17,18    276   3   59-66    284   5  227-257
  --   261   0     7     269   2   19-22    277   4   67-82    285   0    258
  --   262   0     8     270   2   23-26    278   4   83-98
  --   263   0     9     271   2   27-30    279   4   99-114
  --   264   0    10     272   2   31-34    280   4  115-130
  --
  --  Example: the code # 266 means the LZ length (# of message bytes to be copied)
  --           shall be 13 or 14, depending on the extra bit value.

  deflate_code_for_lz_length : constant array (Length_range) of Natural :=
      [3          => 257,  -- Codes 257..264, with no extra bit
       4          => 258,
       5          => 259,
       6          => 260,
       7          => 261,
       8          => 262,
       9          => 263,
       10         => 264,
       11  .. 12  => 265,  -- Codes 265..268, with 1 extra bit
       13  .. 14  => 266,
       15  .. 16  => 267,
       17  .. 18  => 268,
       19  .. 22  => 269,  -- Codes 269..272, with 2 extra bits
       23  .. 26  => 270,
       27  .. 30  => 271,
       31  .. 34  => 272,
       35  .. 42  => 273,  -- Codes 273..276, with 3 extra bits
       43  .. 50  => 274,
       51  .. 58  => 275,
       59  .. 66  => 276,
       67  .. 82  => 277,  -- Codes 277..280, with 4 extra bits
       83  .. 98  => 278,
       99  .. 114 => 279,
       115 .. 130 => 280,
       131 .. 162 => 281,  -- Codes 281..284, with 5 extra bits
       163 .. 194 => 282,
       195 .. 226 => 283,
       227 .. 257 => 284,
       258        => 285   -- Code 285, with no extra bit
     ];

  extra_bits_for_lz_length_offset : constant array (Length_range) of Integer :=
      [3 ..  10 | 258 =>  Huffman.Encoding.invalid,  --  just a placeholder, there is no extra bit there!
      11 ..  18       =>  11,
      19 ..  34       =>  19,
      35 ..  66       =>  35,
      67 .. 130       =>  67,
     131 .. 257       => 131];

  extra_bits_for_lz_length : constant array (Length_range) of Natural :=
      [3 ..  10 | 258 => 0,
      11 ..  18       => 1,
      19 ..  34       => 2,
      35 ..  66       => 3,
      67 .. 130       => 4,
     131 .. 257       => 5];

  procedure Put_DL_code (distance : Distance_range; length : Length_range) is
    extra_bits : Natural;
  begin
    Put_Huffman_Code (curr_descr.lit_len (deflate_code_for_lz_length (length)));
    --  Extra bits are needed to differentiate lengths sharing the same code.
    extra_bits := extra_bits_for_lz_length (length);
    if extra_bits > 0 then
      --  We keep only the last extra_bits bits of the length (minus given offset).
      --  Example: if extra_bits = 1, only the parity is sent (0 or 1);
      --  the rest has been already sent with Put_Huffman_code above.
      --  Equivalent: x:= x mod (2 ** extra_bits);
      Put_Bits (
        U32 (length - extra_bits_for_lz_length_offset (length))
          and
        (Shift_Left (U32'(1), extra_bits) - 1),
        extra_bits);
    end if;
    --                             Distance Codes
    --                             --------------
    --       Extra           Extra             Extra               Extra
    --  Code Bits Dist  Code Bits  Dist   Code Bits Distance  Code Bits Distance
    --  ---- ---- ----  ---- ---- ------  ---- ---- --------  ---- ---- --------
    --    0   0    1      8   3   17-24    16    7  257-384    24   11  4097-6144
    --    1   0    2      9   3   25-32    17    7  385-512    25   11  6145-8192
    --    2   0    3     10   4   33-48    18    8  513-768    26   12  8193-12288
    --    3   0    4     11   4   49-64    19    8  769-1024   27   12 12289-16384
    --    4   1   5,6    12   5   65-96    20    9 1025-1536   28   13 16385-24576
    --    5   1   7,8    13   5   97-128   21    9 1537-2048   29   13 24577-32768
    --    6   2   9-12   14   6  129-192   22   10 2049-3072
    --    7   2  13-16   15   6  193-256   23   10 3073-4096
    --
    --
    --  Example: the code # 10 means the LZ distance (# positions back in the circular
    --           message buffer for starting the copy) shall be 33, plus the value given
    --           by the 4 extra bits (between 0 and 15).
    --
    case distance is
      when 1 .. 4 =>          --  Codes 0..3, with no extra bit
        Put_Huffman_Code (curr_descr.dis (distance - 1));
      when 5 .. 8 =>          --  Codes 4..5, with 1 extra bit
        Put_Huffman_Code (curr_descr.dis (4 + (distance - 5) / 2));
        Put_Bits (U32 ((distance - 5) mod 2), 1);
      when 9 .. 16 =>         --  Codes 6..7, with 2 extra bits
        Put_Huffman_Code (curr_descr.dis (6 + (distance - 9) / 4));
        Put_Bits (U32 ((distance - 9) mod 4), 2);
      when 17 .. 32 =>        --  Codes 8..9, with 3 extra bits
        Put_Huffman_Code (curr_descr.dis (8 + (distance - 17) / 8));
        Put_Bits (U32 ((distance - 17) mod 8), 3);
      when 33 .. 64 =>        --  Codes 10..11, with 4 extra bits
        Put_Huffman_Code (curr_descr.dis (10 + (distance - 33) / 16));
        Put_Bits (U32 ((distance - 33) mod 16), 4);
      when 65 .. 128 =>       --  Codes 12..13, with 5 extra bits
        Put_Huffman_Code (curr_descr.dis (12 + (distance - 65) / 32));
        Put_Bits (U32 ((distance - 65) mod 32), 5);
      when 129 .. 256 =>      --  Codes 14..15, with 6 extra bits
        Put_Huffman_Code (curr_descr.dis (14 + (distance - 129) / 64));
        Put_Bits (U32 ((distance - 129) mod 64), 6);
      when 257 .. 512 =>      --  Codes 16..17, with 7 extra bits
        Put_Huffman_Code (curr_descr.dis (16 + (distance - 257) / 128));
        Put_Bits (U32 ((distance - 257) mod 128), 7);
      when 513 .. 1024 =>     --  Codes 18..19, with 8 extra bits
        Put_Huffman_Code (curr_descr.dis (18 + (distance - 513) / 256));
        Put_Bits (U32 ((distance - 513) mod 256), 8);
      when 1025 .. 2048 =>    --  Codes 20..21, with 9 extra bits
        Put_Huffman_Code (curr_descr.dis (20 + (distance - 1025) / 512));
        Put_Bits (U32 ((distance - 1025) mod 512), 9);
      when 2049 .. 4096 =>    --  Codes 22..23, with 10 extra bits
        Put_Huffman_Code (curr_descr.dis (22 + (distance - 2049) / 1024));
        Put_Bits (U32 ((distance - 2049) mod 1024), 10);
      when 4097 .. 8192 =>    --  Codes 24..25, with 11 extra bits
        Put_Huffman_Code (curr_descr.dis (24 + (distance - 4097) / 2048));
        Put_Bits (U32 ((distance - 4097) mod 2048), 11);
      when 8193 .. 16384 =>   --  Codes 26..27, with 12 extra bits
        Put_Huffman_Code (curr_descr.dis (26 + (distance - 8193) / 4096));
        Put_Bits (U32 ((distance - 8193) mod 4096), 12);
      when 16385 .. 32768 =>  --  Codes 28..29, with 13 extra bits
        Put_Huffman_Code (curr_descr.dis (28 + (distance - 16385) / 8192));
        Put_Bits (U32 ((distance - 16385) mod 8192), 13);
    end case;
  end Put_DL_code;

  function Deflate_code_for_LZ_distance (distance : Distance_range) return Natural is
  begin
    case distance is
      when 1 .. 4 => -- Codes 0..3, with no extra bit
        return distance - 1;
      when 5 .. 8 => -- Codes 4..5, with 1 extra bit
        return  4 + (distance - 5) / 2;
      when 9 .. 16 => -- Codes 6..7, with 2 extra bits
        return  6 + (distance - 9) / 4;
      when 17 .. 32 => -- Codes 8..9, with 3 extra bits
        return  8 + (distance - 17) / 8;
      when 33 .. 64 => -- Codes 10..11, with 4 extra bits
        return  10 + (distance - 33) / 16;
      when 65 .. 128 => -- Codes 12..13, with 5 extra bits
        return  12 + (distance - 65) / 32;
      when 129 .. 256 => -- Codes 14..15, with 6 extra bits
        return  14 + (distance - 129) / 64;
      when 257 .. 512 => -- Codes 16..17, with 7 extra bits
        return  16 + (distance - 257) / 128;
      when 513 .. 1024 => -- Codes 18..19, with 8 extra bits
        return  18 + (distance - 513) / 256;
      when 1025 .. 2048 => -- Codes 20..21, with 9 extra bits
        return  20 + (distance - 1025) / 512;
      when 2049 .. 4096 => -- Codes 22..23, with 10 extra bits
        return  22 + (distance - 2049) / 1024;
      when 4097 .. 8192 => -- Codes 24..25, with 11 extra bits
        return  24 + (distance - 4097) / 2048;
      when 8193 .. 16384 => -- Codes 26..27, with 12 extra bits
        return  26 + (distance - 8193) / 4096;
      when 16385 .. 32768 => -- Codes 28..29, with 13 extra bits
        return  28 + (distance - 16385) / 8192;
    end case;
  end Deflate_code_for_LZ_distance;

  -----------------
  --  LZ Buffer  --
  -----------------

  --  We buffer the LZ codes (plain, or distance/length) in order to
  --  analyse them and try to do smart things.

  max_expand : constant := 14;  --  *Tuned* Sometimes it is better to store data and expand short strings
  code_for_max_expand : constant := 266;
  subtype Expanded_data is Byte_Buffer (1 .. max_expand);

  type LZ_atom_kind is (plain_byte, distance_length);
  subtype Buffered_Distance is Natural range 0 .. 32_768;
  subtype Buffered_Length is Natural range 0 .. 258;
  type LZ_atom is record
    kind          : LZ_atom_kind;
    plain         : Byte;
    lz_distance   : Buffered_Distance;
    lz_length     : Buffered_Length;
    lz_expanded   : Expanded_data;
  end record;
  --  Keep the same tokens and expansion bytes, using their actual DEFLATE
  --  bounds. A 20-byte token replaces the previous padded 32-byte record.
  for LZ_atom use record
    kind        at 0 range 0 .. 7;
    plain       at 1 range 0 .. 7;
    lz_distance at 2 range 0 .. 15;
    lz_length   at 4 range 0 .. 15;
    lz_expanded at 6 range 0 .. 111;
  end record;
  for LZ_atom'Size use 160;
  for LZ_atom'Alignment use 2;

  --  *Tuned*. Min: 2**14, = 16384 (min half buffer 8192)
  --  Optimal so far: 2**17
  LZ_buffer_size : constant := 2**17;
  type LZ_buffer_index_type is mod LZ_buffer_size;
  type LZ_buffer_type is array (LZ_buffer_index_type range <>) of LZ_atom;

  empty_lit_len_stat : constant Stats_lit_len_type := [End_Of_Block => 1, others => 0];
  --  End_Of_Block will have to happen once, but never appears in the LZ statistics...
  empty_dis_stat : constant Stats_dis_type := [others => 0];

  --
  --  Compute statistics for both Literal-length, and Distance alphabets, from a LZ buffer
  --
  procedure Get_statistics (
    lzb           :  in LZ_buffer_type;
    stats_lit_len : out Stats_lit_len_type;
    stats_dis     : out Stats_dis_type;
    match_bytes   : out Count_type
  )
  is
    lit_len : Alphabet_lit_len;
    dis     : Alphabet_dis;
  begin
    stats_lit_len := empty_lit_len_stat;
    stats_dis     := empty_dis_stat;
    match_bytes := 0;
    for i in lzb'Range loop
      case lzb (i).kind is
        when plain_byte =>
          lit_len := Alphabet_lit_len (lzb (i).plain);
          stats_lit_len (lit_len) := stats_lit_len (lit_len) + 1;     --  +1 for this literal
        when distance_length =>
          match_bytes := match_bytes + Count_type (lzb (i).lz_length);
          lit_len := deflate_code_for_lz_length (lzb (i).lz_length);
          stats_lit_len (lit_len) := stats_lit_len (lit_len) + 1;     --  +1 for this length code
          dis := Deflate_code_for_LZ_distance (lzb (i).lz_distance);
          stats_dis (dis) := stats_dis (dis) + 1;                     --  +1 for this distance code
      end case;
    end loop;
  end Get_statistics;

  --
  --  Send a LZ buffer using currently defined Huffman codes
  --
  procedure Put_LZ_buffer (lzb : LZ_buffer_type) is
  begin
    for i in lzb'Range loop
      case lzb (i).kind is
        when plain_byte =>
          Put_literal_byte (lzb (i).plain);
        when distance_length =>
          Put_DL_code (lzb (i).lz_distance, lzb (i).lz_length);
      end case;
    end loop;
  end Put_LZ_buffer;

  block_to_finish : Boolean := False;
  last_block_marked : Boolean := False;
  type Block_type is (stored, fixed, dynamic, reserved);  --  Appnote, 5.5.2
  --  If last_block_type = dynamic, we may recycle previous block's Huffman codes
  last_block_type : Block_type := reserved;

  procedure Mark_new_block (last_block_for_stream : Boolean) is
  begin
    if block_to_finish and last_block_type in fixed .. dynamic then
      Put_Huffman_Code (curr_descr.lit_len (End_Of_Block));  --  Finish previous block
    end if;
    block_to_finish := True;
    Put_Bits (code => Boolean'Pos (last_block_for_stream), code_size => 1);
    last_block_marked := last_block_for_stream;
  end Mark_new_block;

  --  Send a LZ buffer completely decoded as literals (LZ compression is discarded)
  procedure Expand_LZ_buffer (lzb : LZ_buffer_type; last_block : Boolean) is
    b1, b2 : Byte;
    to_be_sent : Natural_M32 := 0;
    --  to_be_sent is not always equal to lzb'Length: sometimes you have a DL code
    mid : LZ_buffer_index_type;
  begin
    for i in lzb'Range loop
      case lzb (i).kind is
        when plain_byte =>
          to_be_sent := to_be_sent + 1;
        when distance_length =>
          to_be_sent := to_be_sent + Natural_M32 (lzb (i).lz_length);
      end case;
    end loop;
    if to_be_sent > 16#FFFF# then  --  Ow, cannot send all that in one chunk.
      --  Instead of a tedious block splitting, just divide and conquer:
      mid := LZ_buffer_index_type ((Natural_M32 (lzb'First) + Natural_M32 (lzb'Last)) / 2);
      
      Expand_LZ_buffer (lzb (lzb'First .. mid), last_block => False);
      Expand_LZ_buffer (lzb (mid + 1   .. lzb'Last), last_block => last_block);
      return;
    end if;
    
    b1 := Byte (to_be_sent mod 256);
    b2 := Byte (to_be_sent  /  256);
    Mark_new_block (last_block_for_stream => last_block);
    last_block_type := stored;
    Put_Bits (code => 0, code_size => 2);  --  Signals a "stored" block
    Flush_bit_buffer;  --  Go to byte boundary
    Put_byte (b1);
    Put_byte (b2);
    Put_byte (not b1);
    Put_byte (not b2);
    for i in lzb'Range loop
      case lzb (i).kind is
        when plain_byte =>
          Put_byte (lzb (i).plain);
        when distance_length =>
          pragma Assert (lzb (i).lz_length <= max_expand);
          for j in 1 .. lzb (i).lz_length loop
            Put_byte (lzb (i).lz_expanded (j));
          end loop;
      end case;
    end loop;
  end Expand_LZ_buffer;

  --  Extra bits that need to be sent after various Deflate codes

  extra_bits_for_lz_length_code : constant array (257 .. 285) of Natural :=
     [257 .. 264 => 0,
      265 .. 268 => 1,
      269 .. 272 => 2,
      273 .. 276 => 3,
      277 .. 280 => 4,
      281 .. 284 => 5,
      285        => 0
    ];

  extra_bits_for_lz_distance_code : constant array (0 .. 29) of Natural :=
     [0 ..  3 =>  0,
      4 ..  5 =>  1,
      6 ..  7 =>  2,
      8 ..  9 =>  3,
     10 .. 11 =>  4,
     12 .. 13 =>  5,
     14 .. 15 =>  6,
     16 .. 17 =>  7,
     18 .. 19 =>  8,
     20 .. 21 =>  9,
     22 .. 23 => 10,
     24 .. 25 => 11,
     26 .. 27 => 12,
     28 .. 29 => 13
    ];

  subtype Long_length_codes is
    Alphabet_lit_len range code_for_max_expand + 1 .. Alphabet_lit_len'Last;
  zero_bl_long_lengths : constant Stats_type (Long_length_codes) := [others => 0];

  --  Send_as_block.
  --
  --  lzb (can be a slice of the principal buffer) will be sent as:
  --        * a new "dynamic" block, preceded by a compression structure header
  --    or  * the continuation of previous "dynamic" block
  --    or  * a new "fixed" block, if lz data's Huffman descriptor is close enough to "fixed"
  --    or  * a new "stored" block, if lz data are too random

  procedure Send_as_block (lzb : LZ_buffer_type; last_block : Boolean) is
    new_descr, new_descr_2 : Deflate_Huff_Descriptors;
    --
    procedure Send_fixed_block is
    begin
      if last_block_type = fixed then
        --  Cool, we don't need to mark a block boundary: the Huffman codes are already
        --  the expected ones. We can just continue sending the LZ atoms.
        null;
      else
        Mark_new_block (last_block_for_stream => last_block);
        curr_descr := Deflate_fixed_descriptors;
        Put_Bits (code => 1, code_size => 2);  --  Signals a "fixed" block
        last_block_type := fixed;
      end if;
      Put_LZ_buffer (lzb);
    end Send_fixed_block;
    --
    stats_lit_len, stats_lit_len_2 : Stats_lit_len_type;
    stats_dis, stats_dis_2 : Stats_dis_type;
    match_bytes : Count_type;
    --
    procedure Send_dynamic_block (dyn : Deflate_Huff_Descriptors) is
      dummy : Count_type := 0;
    begin
      Mark_new_block (last_block_for_stream => last_block);
      curr_descr := Prepare_Huffman_Codes (dyn);
      Put_Bits (code => 2, code_size => 2);  --  Signals a "dynamic" block
      Put_Compression_Structure (curr_descr, cost_analysis => False, bits => dummy);
      Put_LZ_buffer (lzb);
      last_block_type := dynamic;
    end Send_dynamic_block;
    --  The following variables will contain the *exact* number of bits taken
    --  by the block to be sent, using different Huffman encodings, or stored.
    stored_format_bits,                      --  Block is stored (no compression)
    fixed_format_bits,                       --  Fixed (preset) Huffman codes
    dynamic_format_bits,                     --  Dynamic Huffman codes using block's statistics
    dynamic_format_bits_2,                   --  Dynamic Huffman codes after Tweak_for_better_RLE
    recycled_format_bits : Count_type := 0;  --  Continue previous block, use current Huffman codes
    --
    stored_format_possible : Boolean;  --  Can we store (needs expansion of DL codes) ?
    recycling_possible     : Boolean;  --  Can we recycle current Huffman codes ?
    --
    procedure Compute_sizes_of_variants is
      c     : Count_type;
      extra : Natural;
    begin
      --  We count bits taken by literals, for each block format variant.
      for i in 0 .. 255 loop
        c := stats_lit_len (i);  --  This literal appears c times in the LZ buffer
        stored_format_bits    := stored_format_bits    + 8                                               * c;
        fixed_format_bits     := fixed_format_bits     + Count_type (default_lit_len_bl (i))             * c;
        dynamic_format_bits   := dynamic_format_bits   + Count_type (new_descr.lit_len (i).bit_length)   * c;
        dynamic_format_bits_2 := dynamic_format_bits_2 + Count_type (new_descr_2.lit_len (i).bit_length) * c;
        recycled_format_bits  := recycled_format_bits  + Count_type (curr_descr.lit_len (i).bit_length)  * c;
      end loop;
      --  We count bits taken by DL codes.
      if stored_format_possible then
        stored_format_bits := stored_format_bits + 8 * match_bytes;
      end if;
      --  For compressed formats, count Huffman bits and extra bits.
      --  Lengths codes:
      for i in 257 .. 285 loop
        c := stats_lit_len (i);  --  This length code appears c times in the LZ buffer
        extra := extra_bits_for_lz_length_code (i);
        fixed_format_bits     := fixed_format_bits     + Count_type (default_lit_len_bl (i) + extra)             * c;
        dynamic_format_bits   := dynamic_format_bits   + Count_type (new_descr.lit_len (i).bit_length + extra)   * c;
        dynamic_format_bits_2 := dynamic_format_bits_2 + Count_type (new_descr_2.lit_len (i).bit_length + extra) * c;
        recycled_format_bits  := recycled_format_bits  + Count_type (curr_descr.lit_len (i).bit_length + extra)  * c;
      end loop;
      --  Distance codes:
      for i in 0 .. 29 loop
        c := stats_dis (i);  --  This distance code appears c times in the LZ buffer
        extra := extra_bits_for_lz_distance_code (i);
        fixed_format_bits     := fixed_format_bits     + Count_type (default_dis_bl (i) + extra)             * c;
        dynamic_format_bits   := dynamic_format_bits   + Count_type (new_descr.dis (i).bit_length + extra)   * c;
        dynamic_format_bits_2 := dynamic_format_bits_2 + Count_type (new_descr_2.dis (i).bit_length + extra) * c;
        recycled_format_bits  := recycled_format_bits  + Count_type (curr_descr.dis (i).bit_length + extra)  * c;
      end loop;
      --  Supplemental bits to be counted
      --
      stored_format_bits := stored_format_bits +
        (1 + (stored_format_bits / 8) / 65_535)  --  Number of stored blocks needed
        * 5  -- 5 bytes per header
        * 8; -- ... converted into bits
      --
      c := 1;  --  Is-last-block flag
      if block_to_finish and last_block_type in fixed .. dynamic then
        c := c + Count_type (curr_descr.lit_len (End_Of_Block).bit_length);
      end if;
      stored_format_bits    := stored_format_bits + c;
      fixed_format_bits     := fixed_format_bits + c + 2;
      dynamic_format_bits   := dynamic_format_bits + c + 2;
      dynamic_format_bits_2 := dynamic_format_bits_2 + c + 2;
      --  For both dynamic formats, we also counts the bits taken by the compression header!
      Put_Compression_Structure (new_descr,   cost_analysis => True, bits => dynamic_format_bits);
      Put_Compression_Structure (new_descr_2, cost_analysis => True, bits => dynamic_format_bits_2);
    end Compute_sizes_of_variants;
    --
    optimal_format_bits : Count_type;
  begin
    Epub.Performance.Start (Epub.Performance.Huffman_Building);
    Get_statistics (lzb, stats_lit_len, stats_dis, match_bytes);
    new_descr := Build_descriptors (stats_lit_len, stats_dis);
    stats_lit_len_2 := stats_lit_len;
    stats_dis_2 := stats_dis;
    Tweak_for_better_RLE (stats_lit_len_2);
    Tweak_for_better_RLE (stats_dis_2);
    new_descr_2 := Build_descriptors (stats_lit_len_2, stats_dis_2);
    --  For "stored" block format, prevent expansion of DL codes with length > max_expand.
    --  We check stats are all 0 for long length codes:
    stored_format_possible := stats_lit_len (Long_length_codes) = zero_bl_long_lengths;
    recycling_possible :=
      last_block_type = fixed  --  The "fixed" alphabets use all symbols, then always recyclable.
        or else
      (last_block_type = dynamic and then Recyclable (curr_descr, new_descr));
    Compute_sizes_of_variants;
    if not stored_format_possible then
      stored_format_bits := Count_type'Last;
    end if;
    if not recycling_possible then
      recycled_format_bits := Count_type'Last;
    end if;
    optimal_format_bits := Count_type'Min (
      Count_type'Min (stored_format_bits, fixed_format_bits),
      Count_type'Min (
        Count_type'Min (dynamic_format_bits, dynamic_format_bits_2),
        recycled_format_bits)
    );
    --
    --  Selection of the block format with smallest size.
    --
    Epub.Performance.Stop (Epub.Performance.Huffman_Building);
    Epub.Performance.Start (Epub.Performance.Entropy_Encoding);
    begin
      if fixed_format_bits = optimal_format_bits then
        Send_fixed_block;
      elsif dynamic_format_bits = optimal_format_bits then
        Send_dynamic_block (new_descr);
      elsif dynamic_format_bits_2 = optimal_format_bits then
        Send_dynamic_block (new_descr_2);
      elsif recycled_format_bits = optimal_format_bits then
        Put_LZ_buffer (lzb);
      else  --  We have stored_format_bits = optimal_format_bits
        Expand_LZ_buffer (lzb, last_block);
      end if;
    exception
      when others =>
        Epub.Performance.Stop (Epub.Performance.Entropy_Encoding);
        raise;
    end;
    Epub.Performance.Stop (Epub.Performance.Entropy_Encoding);
  end Send_as_block;

  subtype Full_range_LZ_buffer_type is LZ_buffer_type (LZ_buffer_index_type);
  type p_Full_range_LZ_buffer_type is access Full_range_LZ_buffer_type;
  procedure Dispose is
    new Ada.Unchecked_Deallocation (Full_range_LZ_buffer_type, p_Full_range_LZ_buffer_type);

  --  This is the main, big, fat, circular buffer containing LZ codes,
  --  each LZ code being a literal or a DL code.
  --  Heap allocation is needed only because default stack is too small on some targets.
  lz_buffer : p_Full_range_LZ_buffer_type := null;
  lz_buffer_index : LZ_buffer_index_type := 0;
  procedure Flush_half_buffer (last_flush : Boolean) is
    last_idx : constant LZ_buffer_index_type := lz_buffer_index - 1;
    n_div_2 : constant := LZ_buffer_size / 2;
  begin
    if last_idx < n_div_2 then
      Send_as_block (lz_buffer.all (0 .. last_idx), last_flush);        -- 1st half
    else
      Send_as_block (lz_buffer.all (n_div_2 .. last_idx), last_flush);  -- 2nd half
    end if;
  end Flush_half_buffer;

  procedure Push (a : LZ_atom) with Inline_Always is
  begin
    lz_buffer.all (lz_buffer_index) := a;
    lz_buffer_index := lz_buffer_index + 1;  --  becomes 0 when reaching LZ_buffer_size (modular)
    if lz_buffer_index * 2 = 0 then
      Flush_half_buffer (last_flush => False);
    end if;
  end Push;

  procedure Put_or_delay_literal_byte (b : Byte) is
  pragma Inline (Put_or_delay_literal_byte);
  begin
    Push ((plain_byte, b, 0, 0, [b, others => 0]));
  end Put_or_delay_literal_byte;

  procedure Put_or_delay_DL_code (distance, length : Integer; expand : Expanded_data) is
  pragma Inline (Put_or_delay_DL_code);
  begin
    Push ((distance_length, 0, distance, length, expand));
  end Put_or_delay_DL_code;

  --------------------------------
  -- LZ77 front-end compression --
  --------------------------------

  procedure Encode is

    function Read_byte return Byte is
      b : Byte;
    begin
      b := IO_buffers.InBuf.all (IO_buffers.InBufIdx);
      IO_buffers.InBufIdx := IO_buffers.InBufIdx + 1;
      --  CRC is updated once per input block by Read_Block.
      return b;
    end Read_byte;

    function More_bytes return Boolean is
    begin
      if IO_buffers.InBufIdx > IO_buffers.MaxInBufIdx then
        Read_Block (IO_buffers, input, CRC);
      end if;
      return not IO_buffers.InputEoF;
    end More_bytes;

    procedure Read_Span (Buffer : out Epub.LZ77.Byte_Array; Count : out Natural) is
      Cursor : Natural := Buffer'First;
    begin
      Count := 0;
      while Count < Buffer'Length loop
        if not More_bytes then
          exit;
        end if;
        declare
          Amount : constant Positive := Positive'Min
            (Buffer'Length - Count, IO_buffers.MaxInBufIdx - IO_buffers.InBufIdx + 1);
          View : Epub.LZ77.Byte_Array (1 .. Amount)
            with Import, Address => IO_buffers.InBuf.all (IO_buffers.InBufIdx)'Address;
        begin
          Buffer (Cursor .. Cursor + Amount - 1) := View;
          Cursor := Cursor + Amount;
          Count := Count + Amount;
          IO_buffers.InBufIdx := IO_buffers.InBufIdx + Amount;
        end;
      end loop;
    end Read_Span;

    --  Match prefixes come directly from the match finder's bounded source
    --  window; the entropy encoder does not reconstruct a second dictionary.
    procedure LZ77_emits_DL_code
      (distance, length : Integer; Prefix : Epub.LZ77.Match_Prefix) is
    begin
      pragma Assert (distance in Distance_range and then length in Length_range);
      Put_or_delay_DL_code (distance, length, Expanded_data (Prefix));
    end LZ77_emits_DL_code;
    procedure LZ77_emits_literal_byte (b : Byte) is
    begin
      Put_or_delay_literal_byte (b);
    end LZ77_emits_literal_byte;

    procedure My_LZ77 is new Epub.LZ77.Encode
      (Read_Byte => Read_byte, More_Bytes => More_bytes,
       Write_Literal => LZ77_emits_literal_byte, Write_DL_Code => LZ77_emits_DL_code,
       Strategy => Epub.LZ77.Info_Zip_9_Knuth,
       Bulk_Input => True, Read_Span => Read_Span);
  begin  --  Encode
    Read_Block (IO_buffers, input, CRC);

    ----------------------------------------------------------------
    --  The whole compression is happening in the following line: --
    ----------------------------------------------------------------
    Epub.Performance.Start (Epub.Performance.Match_Finding);
    begin
      My_LZ77 (Maximum_Chain => (if Fast_Trial then 64 else 4096));
    exception
      when others =>
        Epub.Performance.Stop (Epub.Performance.Match_Finding);
        raise;
    end;
    Epub.Performance.Stop (Epub.Performance.Match_Finding);

    --  Done. Send the code signaling the end of compressed data block:
    if lz_buffer_index * 2 = 0 then  --  Already flushed at latest Push, or empty data
      if block_to_finish and then last_block_type in fixed .. dynamic then
        Put_Huffman_Code (curr_descr.lit_len (End_Of_Block));
      end if;
    else
      Flush_half_buffer (last_flush => True);
      if last_block_type in fixed .. dynamic then
        Put_Huffman_Code (curr_descr.lit_len (End_Of_Block));
      end if;
    end if;
    if not last_block_marked then
      --  Add an empty fixed block to mark the end of the stream.
      Put_Bits (code => 1, code_size => 1);  --  Signals last block
      Put_Bits (code => 1, code_size => 2);  --  Signals a "fixed" block
      curr_descr := Deflate_fixed_descriptors;
      Put_Huffman_Code (curr_descr.lit_len (End_Of_Block));
    end if;
  end Encode;

  procedure Deallocation is
  begin
    Dispose (lz_buffer);
    Deallocate_Buffers (IO_buffers);
  end Deallocation;

begin
  
  Allocate_Buffers (IO_buffers, input_size);
  output_size := 0;
  lz_buffer := new Full_range_LZ_buffer_type;
  Epub.Performance.Add (Epub.Performance.Compression_Allocations, 3);
  begin
    Encode;
    compression_ok := True;
    Flush_bit_buffer;
    Flush_byte_buffer;
  exception
    when Compression_inefficient =>  --  Escaped from Encode
      compression_ok := False;
  end;
  
  Deallocation;
exception
  when others =>
    Deallocation;
    raise;
end Epub.Compression.Deflate;

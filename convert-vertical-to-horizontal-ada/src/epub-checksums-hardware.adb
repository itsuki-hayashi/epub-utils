with Ada.Unchecked_Conversion;
with Interfaces.C;
with System.Machine_Code;

--  Bounded Ada adaptation of the 128-bit folding/reduction algorithm in
--  Chromium third_party/zlib/crc32_simd.c, copyright 2017 The Chromium Authors,
--  under the BSD-3-Clause license reproduced in CODEC_ORIGINS.md. No C codec
--  code is compiled. Fold constants represent ZIP's reflected IEEE polynomial.
package body Epub.Checksums.Hardware is
   use Interfaces;
   type Vector is array (0 .. 1) of Integer_64 with Alignment => 16;
   pragma Machine_Attribute (Vector, "vector_type");
   function Signed is new Ada.Unchecked_Conversion (Unsigned_64, Integer_64);
   function Unsigned is new Ada.Unchecked_Conversion (Integer_64, Unsigned_64);
   function Multiply (A, B : Vector; Selection : Interfaces.C.int) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pclmulqdq128";
   function Xor_Vector (A, B : Vector) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pxor128";
   function And_Vector (A, B : Vector) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pand128";
   function Shift_Bytes (A : Vector; Bits : Interfaces.C.int) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psrldqi128";
   type Unaligned_Word is mod 2 ** 64 with Size => 64, Alignment => 1;

   function Detect return Boolean is
      A, B, C, D : Unsigned_32;
   begin
      System.Machine_Code.Asm
        ("cpuid", Outputs =>
           [Unsigned_32'Asm_Output ("=a", A), Unsigned_32'Asm_Output ("=b", B),
            Unsigned_32'Asm_Output ("=c", C), Unsigned_32'Asm_Output ("=d", D)],
         Inputs => [Unsigned_32'Asm_Input ("0", 1), Unsigned_32'Asm_Input ("2", 0)],
         Volatile => True);
      return (C and 2) /= 0;
   end Detect;
   Supported : constant Boolean := Detect;
   function Available return Boolean is (Supported);

   procedure Update (CRC : in out Unsigned_32; Bytes : Zip.Byte_Buffer) is
      Fold_64 : constant Vector := [16#0154_442B_D4#, 16#01C6_E415_96#];
      Fold_16 : constant Vector := [16#0175_1997_D0#, 16#00CC_AA00_9E#];
      Fold_4 : constant Vector := [16#0163_CD61_24#, 0];
      Polynomial : constant Vector := [16#01DB_7106_41#, 16#01F7_0116_41#];
      Low_32 : constant Vector := [16#FFFF_FFFF#, 16#FFFF_FFFF#];
      Lanes : array (Natural range 0 .. 3) of Vector;
      State, Part : Vector;
      Position : Integer := Bytes'First;
      Remaining : Natural := Bytes'Length - 64;
      function Load (At_Byte : Integer) return Vector with Inline_Always is
      begin
         pragma Assert (At_Byte in Bytes'Range and then Bytes'Last - At_Byte >= 15);
         declare
            Low : constant Unaligned_Word with Import, Address => Bytes (At_Byte)'Address;
            High : constant Unaligned_Word with Import, Address => Bytes (At_Byte + 8)'Address;
         begin
            return [Signed (Unsigned_64 (Low)), Signed (Unsigned_64 (High))];
         end;
      end Load;
   begin
      for Lane in Lanes'Range loop Lanes (Lane) := Load (Position + Lane * 16); end loop;
      Lanes (0) := Xor_Vector (Lanes (0), [Signed (Unsigned_64 (CRC)), 0]);
      if Remaining > 0 then Position := Position + 64; end if;
      while Remaining >= 64 loop
         for Lane in Lanes'Range loop
            Lanes (Lane) := Xor_Vector
              (Xor_Vector (Multiply (Lanes (Lane), Fold_64, 16#00#), Multiply (Lanes (Lane), Fold_64, 16#11#)),
               Load (Position + Lane * 16));
         end loop;
         Remaining := Remaining - 64;
         if Remaining > 0 then Position := Position + 64; end if;
      end loop;
      State := Lanes (0);
      for Lane in 1 .. 3 loop
         State := Xor_Vector
           (Xor_Vector (Multiply (State, Fold_16, 16#00#), Multiply (State, Fold_16, 16#11#)), Lanes (Lane));
      end loop;
      while Remaining > 0 loop
         State := Xor_Vector
           (Xor_Vector (Multiply (State, Fold_16, 16#00#), Multiply (State, Fold_16, 16#11#)), Load (Position));
         Remaining := Remaining - 16;
         if Remaining > 0 then Position := Position + 16; end if;
      end loop;
      Part := Multiply (State, Fold_16, 16#10#);
      State := Xor_Vector (Shift_Bytes (State, 64), Part);
      Part := Shift_Bytes (State, 32);
      State := Xor_Vector (Multiply (And_Vector (State, Low_32), Fold_4, 16#00#), Part);
      Part := Multiply (And_Vector (State, Low_32), Polynomial, 16#10#);
      Part := Multiply (And_Vector (Part, Low_32), Polynomial, 16#00#);
      State := Xor_Vector (State, Part);
      CRC := Unsigned_32 (Shift_Right (Unsigned (State (0)), 32));
   end Update;
end Epub.Checksums.Hardware;

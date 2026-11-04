with Ada.Characters.Handling;
with Ada.Unchecked_Conversion;
with System.Machine_Code;

package body Epub.Digests is
   use Interfaces;
   type Vector is array (0 .. 3) of Integer_32 with Alignment => 16;
   pragma Machine_Attribute (Vector, "vector_type");
   --  These equal-size scalar types admit every 32-bit pattern. Reinterpret
   --  lanes for GCC's signed-vector intrinsic ABI; SHA arithmetic is modular.
   function Signed is new Ada.Unchecked_Conversion (Unsigned_32, Integer_32);
   function Unsigned is new Ada.Unchecked_Conversion (Integer_32, Unsigned_32);
   function Rounds (A, B, Message : Vector) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_sha256rnds2";
   function Message_1 (A, B : Vector) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_sha256msg1";
   function Message_2 (A, B : Vector) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_sha256msg2";
   function Add (A, B : Vector) return Vector
     with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_paddd128";
   type Unaligned_Word is mod 2 ** 32 with Size => 32, Alignment => 1;
   function Byte_Swap (Value : Unsigned_32) return Unsigned_32
     with Import, Convention => Intrinsic, External_Name => "__builtin_bswap32";

   function Detect_Hardware return Boolean is
      A, B, C, D : Unsigned_32;
      procedure CPUID (Leaf : Unsigned_32) is
      begin
         System.Machine_Code.Asm
           ("cpuid", Outputs =>
              [Unsigned_32'Asm_Output ("=a", A), Unsigned_32'Asm_Output ("=b", B),
               Unsigned_32'Asm_Output ("=c", C), Unsigned_32'Asm_Output ("=d", D)],
            Inputs => [Unsigned_32'Asm_Input ("0", Leaf), Unsigned_32'Asm_Input ("2", 0)],
            Volatile => True);
      end CPUID;
   begin
      CPUID (0);
      if A < 7 then
         return False;
      end if;
      CPUID (7);
      return (B and 16#2000_0000#) /= 0;
   end Detect_Hardware;
   Available : constant Boolean := Detect_Hardware;
   function Hardware_Available return Boolean is (Available);
   function Initial_Context (Software_Only : Boolean := False) return Context is
   begin
      return Result : Context do
         Result.Hardware := Available and then not Software_Only;
      end return;
   end Initial_Context;

   --  Standard SHA-256 round constants, FIPS 180-4 section 4.2.2.
   K : constant array (Natural range 0 .. 63) of Unsigned_32 :=
     [16#428A2F98#, 16#71374491#, 16#B5C0FBCF#, 16#E9B5DBA5#,
      16#3956C25B#, 16#59F111F1#, 16#923F82A4#, 16#AB1C5ED5#,
      16#D807AA98#, 16#12835B01#, 16#243185BE#, 16#550C7DC3#,
      16#72BE5D74#, 16#80DEB1FE#, 16#9BDC06A7#, 16#C19BF174#,
      16#E49B69C1#, 16#EFBE4786#, 16#0FC19DC6#, 16#240CA1CC#,
      16#2DE92C6F#, 16#4A7484AA#, 16#5CB0A9DC#, 16#76F988DA#,
      16#983E5152#, 16#A831C66D#, 16#B00327C8#, 16#BF597FC7#,
      16#C6E00BF3#, 16#D5A79147#, 16#06CA6351#, 16#14292967#,
      16#27B70A85#, 16#2E1B2138#, 16#4D2C6DFC#, 16#53380D13#,
      16#650A7354#, 16#766A0ABB#, 16#81C2C92E#, 16#92722C85#,
      16#A2BFE8A1#, 16#A81A664B#, 16#C24B8B70#, 16#C76C51A3#,
      16#D192E819#, 16#D6990624#, 16#F40E3585#, 16#106AA070#,
      16#19A4C116#, 16#1E376C08#, 16#2748774C#, 16#34B0BCB5#,
      16#391C0CB3#, 16#4ED8AA4A#, 16#5B9CCA4F#, 16#682E6FF3#,
      16#748F82EE#, 16#78A5636F#, 16#84C87814#, 16#8CC70208#,
      16#90BEFFFA#, 16#A4506CEB#, 16#BEF9A3F7#, 16#C67178F2#];

   procedure Transform (State : in out State_Array; Block : String);
   pragma Machine_Attribute (Transform, "target", "sha,sse2");
   procedure Transform (State : in out State_Array; Block : String) is
      ABEF : Vector := [Signed (State (5)), Signed (State (4)), Signed (State (1)), Signed (State (0))];
      CDGH : Vector := [Signed (State (7)), Signed (State (6)), Signed (State (3)), Signed (State (2))];
      Messages : array (Natural range 0 .. 3) of Vector;
   begin
      pragma Assert (Block'Length mod 64 = 0);
      for Block_Number in 0 .. Block'Length / 64 - 1 loop
         declare
            Block_First : constant Integer := Block'First + Block_Number * 64;
            Original_ABEF : constant Vector := ABEF;
            Original_CDGH : constant Vector := CDGH;
         begin
            pragma Assert (Block_First <= Block'Last - 63);
            declare
               Bytes : constant String (1 .. 64) with Import, Address => Block (Block_First)'Address;
            begin
               for Group in 0 .. 15 loop
                  declare
                     Slot : constant Natural := Group mod 4;
                     Words : Vector;
                  begin
                     if Group < 4 then
                        for Lane in 0 .. 3 loop
                           declare
                              First : constant Positive := Group * 16 + Lane * 4 + 1;
                              Word : constant Unaligned_Word with Import, Address => Bytes (First)'Address;
                           begin
                              pragma Assert (First <= Bytes'Last - 3);
                              Messages (Slot)(Lane) := Signed (Byte_Swap (Unsigned_32 (Word)));
                           end;
                        end loop;
                     else
                        declare
                           Next_2 : constant Vector := Messages ((Group + 2) mod 4);
                           Next_3 : constant Vector := Messages ((Group + 3) mod 4);
                        begin
                           Messages (Slot) := Message_2
                             (Add (Message_1 (Messages (Slot), Messages ((Group + 1) mod 4)),
                                   [Next_2 (1), Next_2 (2), Next_2 (3), Next_3 (0)]), Next_3);
                        end;
                     end if;
                     Words := Add (Messages (Slot),
                       [Signed (K (Group * 4)), Signed (K (Group * 4 + 1)),
                        Signed (K (Group * 4 + 2)), Signed (K (Group * 4 + 3))]);
                     CDGH := Rounds (CDGH, ABEF, Words);
                     ABEF := Rounds (ABEF, CDGH, [Words (2), Words (3), Words (0), Words (0)]);
                  end;
               end loop;
            end;
            ABEF := Add (ABEF, Original_ABEF);
            CDGH := Add (CDGH, Original_CDGH);
         end;
      end loop;
      State := [Unsigned (ABEF (3)), Unsigned (ABEF (2)), Unsigned (CDGH (3)), Unsigned (CDGH (2)),
                Unsigned (ABEF (1)), Unsigned (ABEF (0)), Unsigned (CDGH (1)), Unsigned (CDGH (0))];
   end Transform;

   procedure Update (Item : in out Context; Bytes : String) is
      Position : Integer := Bytes'First;
   begin
      if not Item.Hardware then
         GNAT.SHA256.Update (Item.Software, Bytes);
         return;
      end if;
      if Unsigned_64 (Bytes'Length) > Unsigned_64'Last / 8 - Item.Bytes then
         raise Constraint_Error with "SHA-256 message length overflow";
      end if;
      Item.Bytes := Item.Bytes + Unsigned_64 (Bytes'Length);
      if Item.Used > 0 then
         declare
            Count : constant Natural := Natural'Min (64 - Item.Used, Bytes'Length);
         begin
            Item.Block (Item.Used + 1 .. Item.Used + Count) := Bytes (Position .. Position + Count - 1);
            Position := Position + Count;
            if Item.Used + Count = 64 then
               Transform (Item.State, Item.Block);
               Item.Used := 0;
            else
               Item.Used := Item.Used + Count;
            end if;
         end;
      end if;
      if Position <= Bytes'Last then
         declare
            Count : constant Natural := (Bytes'Last - Position + 1) / 64 * 64;
         begin
            if Count > 0 then
               Transform (Item.State, Bytes (Position .. Position + Count - 1));
               Position := Position + Count;
            end if;
         end;
      end if;
      if Position <= Bytes'Last then
         Item.Used := Bytes'Last - Position + 1;
         Item.Block (1 .. Item.Used) := Bytes (Position .. Bytes'Last);
      end if;
   end Update;

   procedure Update (Item : in out Context; Bytes : Ada.Streams.Stream_Element_Array) is
      View : constant String (1 .. Bytes'Length) with Import, Address => Bytes'Address;
   begin
      pragma Compile_Time_Error (Ada.Streams.Stream_Element'Size /= Character'Size, "Byte views require octets");
      Update (Item, View);
   end Update;

   function Digest (Item : Context) return String is
      Copy : Context := Item;
      Bit_Length : Unsigned_64 := Item.Bytes * 8;
      Hex : constant String := "0123456789ABCDEF";
      Result : String (1 .. 64);
   begin
      if not Copy.Hardware then
         return Ada.Characters.Handling.To_Upper (GNAT.SHA256.Digest (Copy.Software));
      end if;
      Copy.Block (Copy.Used + 1) := Character'Val (16#80#);
      if Copy.Used >= 56 then
         Copy.Block (Copy.Used + 2 .. 64) := [others => Character'Val (0)];
         Transform (Copy.State, Copy.Block);
         Copy.Block := [others => Character'Val (0)];
      else
         Copy.Block (Copy.Used + 2 .. 56) := [others => Character'Val (0)];
      end if;
      for Index in reverse 57 .. 64 loop
         Copy.Block (Index) := Character'Val (Bit_Length and 255);
         Bit_Length := Shift_Right (Bit_Length, 8);
      end loop;
      Transform (Copy.State, Copy.Block);
      for Word in Copy.State'Range loop
         for Digit in 0 .. 7 loop
            Result (Word * 8 + Digit + 1) := Hex
              (Natural (Shift_Right (Copy.State (Word), 28 - Digit * 4) and 15) + 1);
         end loop;
      end loop;
      return Result;
   end Digest;
   function Digest (Bytes : String) return String is
      Item : Context := Initial_Context;
   begin
      Update (Item, Bytes);
      return Digest (Item);
   end Digest;
end Epub.Digests;

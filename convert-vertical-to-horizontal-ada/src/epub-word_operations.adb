with Interfaces.C;

package body Epub.Word_Operations is
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_8;
   type Unaligned_Word is mod 2 ** 64 with Size => 64, Alignment => 1;
   function Trailing_Zeros (Value : Interfaces.Unsigned_64) return Interfaces.C.int
     with Import, Convention => Intrinsic, External_Name => "__builtin_ctzll";

   function Matching_Prefix
     (Data : Byte_Array; Left, Right : Index_Type; Limit : Natural) return Natural is
      Count : Natural := 0;
      function Load (Position : Index_Type) return Interfaces.Unsigned_64 is
         Value : constant Unaligned_Word with Import, Address => Data (Position)'Address;
      begin
         return Interfaces.Unsigned_64 (Value);
      end Load;
   begin
      --  Both supported targets are little-endian x86-64. Load only complete
      --  words within the caller's checked span; never invoke ctz with zero.
      while Limit - Count >= 8 loop
         declare
            Difference : constant Interfaces.Unsigned_64 :=
              Load (Left + Index_Type (Count)) xor Load (Right + Index_Type (Count));
         begin
            if Difference /= 0 then
               return Count + Natural (Trailing_Zeros (Difference)) / 8;
            end if;
            Count := Count + 8;
         end;
      end loop;
      while Count < Limit and then Data (Left + Index_Type (Count)) = Data (Right + Index_Type (Count)) loop
         Count := Count + 1;
      end loop;
      return Count;
   end Matching_Prefix;
end Epub.Word_Operations;

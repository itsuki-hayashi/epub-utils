package body Epub.Checksums is
   use Interfaces;
   type Lookup_Table is array (Natural range 0 .. 7, Natural range 0 .. 255) of Unsigned_32;
   function Make_Tables return Lookup_Table is
      Result : Lookup_Table;
      Value : Unsigned_32;
   begin
      for Byte in 0 .. 255 loop
         Value := Unsigned_32 (Byte);
         for Bit in 1 .. 8 loop
            Value := (if (Value and 1) /= 0 then Shift_Right (Value, 1) xor 16#EDB8_8320#
                      else Shift_Right (Value, 1));
         end loop;
         Result (0, Byte) := Value;
      end loop;
      for Row in 1 .. 7 loop
         for Byte in 0 .. 255 loop
            Value := Result (Row - 1, Byte);
            Result (Row, Byte) := Shift_Right (Value, 8) xor Result (0, Natural (Value and 255));
         end loop;
      end loop;
      return Result;
   end Make_Tables;
   Tables : constant Lookup_Table := Make_Tables;
   procedure Init (CRC : out Unsigned_32) is
   begin
      CRC := 16#FFFF_FFFF#;
   end Init;
   procedure Update (CRC : in out Unsigned_32; Bytes : Zip.Byte_Buffer) is
      Position : Integer := Bytes'First;
      Value : Unsigned_32 := CRC;
      Remaining : Natural := Bytes'Length;
   begin
      while Remaining >= 8 loop
         Value := Value xor (Unsigned_32 (Bytes (Position)) or
           Shift_Left (Unsigned_32 (Bytes (Position + 1)), 8) or
           Shift_Left (Unsigned_32 (Bytes (Position + 2)), 16) or
           Shift_Left (Unsigned_32 (Bytes (Position + 3)), 24));
         Value := Tables (7, Natural (Value and 255)) xor
           Tables (6, Natural (Shift_Right (Value, 8) and 255)) xor
           Tables (5, Natural (Shift_Right (Value, 16) and 255)) xor
           Tables (4, Natural (Shift_Right (Value, 24))) xor
           Tables (3, Natural (Bytes (Position + 4))) xor
           Tables (2, Natural (Bytes (Position + 5))) xor
           Tables (1, Natural (Bytes (Position + 6))) xor
           Tables (0, Natural (Bytes (Position + 7)));
         Remaining := Remaining - 8;
         exit when Remaining = 0;
         Position := Position + 8;
      end loop;
      if Remaining > 0 then
         for Index in Position .. Bytes'Last loop
            Value := Shift_Right (Value, 8) xor Tables (0, Natural ((Value xor Unsigned_32 (Bytes (Index))) and 255));
         end loop;
      end if;
      CRC := Value;
   end Update;
   function Final (CRC : Unsigned_32) return Unsigned_32 is (not CRC);
   function CRC32 (Bytes : String) return Unsigned_32 is
      View : constant Zip.Byte_Buffer (1 .. Bytes'Length) with Import, Address => Bytes'Address;
      State : Unsigned_32;
   begin
      pragma Compile_Time_Error (Zip.Byte'Size /= Character'Size, "Byte views require octets");
      Init (State);
      Update (State, View);
      return Final (State);
   end CRC32;
end Epub.Checksums;

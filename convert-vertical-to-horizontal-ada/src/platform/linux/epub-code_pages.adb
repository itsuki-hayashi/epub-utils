with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Interfaces;
with Epub.CP932_Tables;
with Epub.Encoding;

package body Epub.Code_Pages is
   use type Interfaces.Unsigned_16;
   package Scalars renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
   function Decode (Bytes : String) return String is
      Text : Wide_Wide_String (1 .. Bytes'Length);
      Count : Natural := 0;
      Position : Integer := Bytes'First;
   begin
      while Position <= Bytes'Last loop
         declare
            Code : Natural := Character'Pos (Bytes (Position));
         begin
            if Code in 16#81# .. 16#9F# | 16#E0# .. 16#FC# then
               Position := Position + 1;
               if Position > Bytes'Last then
                  raise Epub.Encoding.Invalid_Encoding with "Truncated CP932 resource";
               end if;
               Code := Code * 256 + Character'Pos (Bytes (Position));
            end if;
            if Epub.CP932_Tables.Decoding (Code) = Epub.CP932_Tables.Invalid then
               raise Epub.Encoding.Invalid_Encoding with "Invalid CP932 resource";
            end if;
            Count := Count + 1;
            Text (Count) := Wide_Wide_Character'Val (Epub.CP932_Tables.Decoding (Code));
         end;
         Position := Position + 1;
      end loop;
      return Scalars.Encode (Text (1 .. Count));
   end Decode;

   function Encode (Value : String) return String is
      Text : constant Wide_Wide_String := Scalars.Decode (Value);
      Bytes : String (1 .. Text'Length * 2);
      Count : Natural := 0;
   begin
      for Character_Value of Text loop
         declare
            Code : constant Natural := Wide_Wide_Character'Pos (Character_Value);
            Encoded : Interfaces.Unsigned_16;
         begin
            if Code > Epub.CP932_Tables.Encoding'Last then
               raise Epub.Encoding.Invalid_Encoding with "Text cannot be encoded in CP932";
            end if;
            Encoded := Epub.CP932_Tables.Encoding (Code);
            if Encoded = Epub.CP932_Tables.Invalid then
               raise Epub.Encoding.Invalid_Encoding with "Text cannot be encoded in CP932";
            end if;
            if Encoded > 255 then
               Count := Count + 1;
               Bytes (Count) := Character'Val (Encoded / 256);
            end if;
            Count := Count + 1;
            Bytes (Count) := Character'Val (Encoded mod 256);
         end;
      end loop;
      return Bytes (1 .. Count);
   end Encode;
end Epub.Code_Pages;

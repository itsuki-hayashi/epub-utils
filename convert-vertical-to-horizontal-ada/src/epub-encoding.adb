with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Epub.Code_Pages;

with Epub.Performance;
package body Epub.Encoding is
   use Ada.Strings.Unbounded;
   package UTF renames Ada.Strings.UTF_Encoding;
   package Scalars renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;

   function From_UTF8 (Value : String; Kind : Encoding_Kind) return String is
   begin
      declare
         Characters : constant Wide_Wide_String := Scalars.Decode (Value);
      begin
         if Scalars.Encode (Characters) /= Value then
            raise Invalid_Encoding with "Noncanonical UTF-8 input";
         end if;
         case Kind is
            when UTF8 =>
               return Scalars.Encode (Characters);
            when UTF16_LE =>
               return Scalars.Encode (Characters, UTF.UTF_16LE);
            when UTF16_BE =>
               return Scalars.Encode (Characters, UTF.UTF_16BE);
            when CP932 =>
               return Epub.Code_Pages.Encode (Value);
         end case;
      end;
   exception
      when UTF.Encoding_Error =>
         raise Invalid_Encoding with "Invalid UTF-8 text";
   end From_UTF8;

   function Decode (Bytes : String) return Payload is
      Result : Payload;
      First : Natural := Bytes'First;
      function Starts (Prefix : String) return Boolean is
        (Bytes'Length >= Prefix'Length
         and then Bytes (Bytes'First .. Bytes'First + Prefix'Length - 1) = Prefix);
      function Byte (Value : Natural) return Character is (Character'Val (Value));
   begin
      Epub.Performance.Start (Epub.Performance.Text_Decoding);
      Epub.Performance.Add (Epub.Performance.Text_Decodes);
      Result.Original := To_Unbounded_String (Bytes);
      if Starts (Byte (255) & Byte (254) & Byte (0) & Byte (0))
        or else Starts (Byte (0) & Byte (0) & Byte (254) & Byte (255))
      then
         raise Invalid_Encoding with "UTF-32 resources require manual review";
      elsif Starts (Byte (255) & Byte (254)) then
         Result.Kind := UTF16_LE;
         First := First + 2;
      elsif Starts (Byte (254) & Byte (255)) then
         Result.Kind := UTF16_BE;
         First := First + 2;
      elsif Starts (Byte (239) & Byte (187) & Byte (191)) then
         First := First + 3;
      else
         declare
            Probe : constant String := Ada.Characters.Handling.To_Lower
              (Bytes (Bytes'First .. Integer'Min (Bytes'Last, Bytes'First + 255)));
            Position : Natural := Probe'First;
            Marker : Natural;
         begin
            while Position <= Probe'Last and then
              Probe (Position) in ' ' | Character'Val (9) .. Character'Val (13)
            loop
               Position := Position + 1;
            end loop;
            if Position + 4 <= Probe'Last
              and then Probe (Position .. Position + 4) = "<?xml"
            then
               Marker := Ada.Strings.Fixed.Index (Probe, "encoding");
            elsif Position + 7 <= Probe'Last
              and then Probe (Position .. Position + 7) = "@charset"
            then
               Marker := Position + 8;
            else
               Marker := 0;
            end if;
            if Marker /= 0 then
               Position := Marker;
               while Position <= Probe'Last
                 and then Probe (Position) /= '"' and then Probe (Position) /= '''
               loop
                  Position := Position + 1;
               end loop;
               if Position <= Probe'Last then
                  declare
                     Quote : constant Character := Probe (Position);
                     Start : constant Natural := Position + 1;
                  begin
                     Position := Start;
                     while Position <= Probe'Last and then Probe (Position) /= Quote loop
                        Position := Position + 1;
                     end loop;
                     declare
                        Name : constant String := Probe (Start .. Position - 1);
                     begin
                        if Name = "utf-8" or else Name = "utf8" then
                           Result.Kind := UTF8;
                        elsif Name = "utf-16le" then
                           Result.Kind := UTF16_LE;
                        elsif Name = "utf-16be" then
                           Result.Kind := UTF16_BE;
                        elsif Name = "cp932" then
                           Result.Kind := CP932;
                        else
                           raise Invalid_Encoding with "Unsupported encoding: " & Name;
                        end if;
                     end;
                  end;
               end if;
            end if;
         end;
      end if;
      Result.Prefix := To_Unbounded_String (Bytes (Bytes'First .. First - 1));
      declare
         Body_Bytes : constant String := Bytes (First .. Bytes'Last);
         Decoded : constant String :=
           (case Result.Kind is
              when CP932 => Epub.Code_Pages.Decode (Body_Bytes),
              when UTF8 => Scalars.Encode (Scalars.Decode (Body_Bytes)),
              when UTF16_LE => Scalars.Encode (Scalars.Decode (Body_Bytes, UTF.UTF_16LE)),
              when UTF16_BE => Scalars.Encode (Scalars.Decode (Body_Bytes, UTF.UTF_16BE)));
      begin
         if Result.Kind /= CP932 and then
           From_UTF8 (Decoded, Result.Kind) /= Body_Bytes
         then
            raise Invalid_Encoding with "Invalid or noncanonical UTF resource";
         end if;
         for Value of Decoded loop
            if Value = Character'Val (0) then
               raise Invalid_Encoding with "Embedded NUL in text resource";
            end if;
         end loop;
         Result.Decoded := To_Unbounded_String (Decoded);
      end;
      Epub.Performance.Stop (Epub.Performance.Text_Decoding);
      return Result;
   exception
      when UTF.Encoding_Error =>
         raise Invalid_Encoding with "Invalid UTF resource";
   end Decode;

   function Text (Item : Payload) return String is (To_String (Item.Decoded));

   function Encode (Item : Payload; New_Text : String) return String is
   begin
      if New_Text = To_String (Item.Decoded) then
         return To_String (Item.Original);
      elsif To_String (Item.Prefix) & From_UTF8 (Text (Item), Item.Kind) /=
        To_String (Item.Original)
      then
         raise Invalid_Encoding with "Resource encoding does not round-trip exactly";
      end if;
      return To_String (Item.Prefix) & From_UTF8 (New_Text, Item.Kind);
   end Encode;
end Epub.Encoding;

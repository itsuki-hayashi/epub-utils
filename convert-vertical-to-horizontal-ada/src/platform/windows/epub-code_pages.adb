with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Interfaces.C;
with System;
with Epub.Encoding;

package body Epub.Code_Pages is
   use type Interfaces.C.int;
   package UTF renames Ada.Strings.UTF_Encoding;
   package Scalars renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
   function MultiByteToWideChar
     (Code_Page, Flags : Interfaces.C.unsigned;
      Input : System.Address; Input_Length : Interfaces.C.int;
      Output : System.Address; Capacity : Interfaces.C.int)
      return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "MultiByteToWideChar";

   function WideCharToMultiByte
     (Code_Page, Flags : Interfaces.C.unsigned;
      Input : System.Address; Input_Length : Interfaces.C.int;
      Output : System.Address; Capacity : Interfaces.C.int;
      Default_Character, Used_Default : System.Address)
      return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "WideCharToMultiByte";

   function Decode (Bytes : String) return String is
      Required : Interfaces.C.int;
   begin
      if Bytes'Length = 0 then
         return "";
      end if;
      Required := MultiByteToWideChar
        (932, 8, Bytes'Address, Bytes'Length, System.Null_Address, 0);
      if Required <= 0 then
         raise Epub.Encoding.Invalid_Encoding with "Invalid CP932 resource";
      end if;
      declare
         Buffer : String (1 .. Natural (Required) * 2);
         Written : constant Interfaces.C.int := MultiByteToWideChar
           (932, 8, Bytes'Address, Bytes'Length, Buffer'Address, Required);
      begin
         if Written /= Required then
            raise Epub.Encoding.Invalid_Encoding with "CP932 decoding failed";
         end if;
         return Scalars.Encode (Scalars.Decode (Buffer, UTF.UTF_16LE));
      end;
   end Decode;

   function Encode (Value : String) return String is
      Characters : constant Wide_Wide_String := Scalars.Decode (Value);
   begin
      if Value'Length = 0 then
         return "";
      end if;
      declare
         Wide_Bytes : constant String :=
           Scalars.Encode (Characters, UTF.UTF_16LE);
         Substituted : aliased Interfaces.C.int := 0;
         Required : constant Interfaces.C.int := WideCharToMultiByte
           (932, 16#400#, Wide_Bytes'Address, Wide_Bytes'Length / 2,
            System.Null_Address, 0, System.Null_Address,
            Substituted'Address);
      begin
         if Required <= 0 or else Substituted /= 0 then
            raise Epub.Encoding.Invalid_Encoding with "Text cannot be encoded in CP932";
         end if;
         declare
            Buffer : String (1 .. Natural (Required));
            Written : constant Interfaces.C.int := WideCharToMultiByte
              (932, 16#400#, Wide_Bytes'Address, Wide_Bytes'Length / 2,
               Buffer'Address, Required, System.Null_Address,
               Substituted'Address);
         begin
            if Written /= Required or else Substituted /= 0 then
               raise Epub.Encoding.Invalid_Encoding with "CP932 encoding failed";
            end if;
            return Buffer;
         end;
      end;
   end Encode;
end Epub.Code_Pages;

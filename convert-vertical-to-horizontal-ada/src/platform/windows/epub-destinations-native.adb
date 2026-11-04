with Epub.Files;
with Epub.Encoding;
with Epub.Windows;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Interfaces.C;
with System;
with System.Storage_Elements;

package body Epub.Destinations.Native is
   use Ada.Strings.Unbounded;
   use type Epub.Windows.BOOL;
   use type System.Address;
   package Win renames Epub.Windows;
   package Scalars renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
   function File_Information (Handle, Data : System.Address) return Win.BOOL
     with Import, Convention => Stdcall, External_Name => "GetFileInformationByHandle";
   function Map_String
     (Locale, Flags : Win.DWORD; Source : System.Address; Source_Length : Interfaces.C.int;
      Target : System.Address; Target_Length : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => Stdcall, External_Name => "LCMapStringW";
   function Fold (Value : String) return String is
      Bytes : constant String := Epub.Encoding.From_UTF8 (Value, Epub.Encoding.UTF16_LE);
      Needed : constant Interfaces.C.int := Map_String
        (16#007F#, 16#0200#, Bytes'Address, Interfaces.C.int (Bytes'Length / 2), System.Null_Address, 0);
   begin
      if Value'Length = 0 then return ""; end if;
      if Needed <= 0 then raise Constraint_Error with "Cannot compare destination names"; end if;
      declare
         Upper : String (1 .. Natural (Needed) * 2);
      begin
         if Map_String (16#007F#, 16#0200#, Bytes'Address, Interfaces.C.int (Bytes'Length / 2),
                        Upper'Address, Needed) /= Needed
         then
            raise Constraint_Error with "Cannot compare destination names";
         end if;
         return Scalars.Encode (Scalars.Decode (Upper, Ada.Strings.UTF_Encoding.UTF_16LE));
      end;
   end Fold;
   function Identify (Path : String) return Key is
      Result : Key;
      Parent : Unbounded_String := To_Unbounded_String (Epub.Files.Parent_Path (Path));
      Suffix : Unbounded_String;
      Invalid : constant System.Address := System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address'Last);
      type Information is array (0 .. 12) of Win.DWORD with Convention => C;
      Data : aliased Information;
   begin
      while not Epub.Files.Is_Directory (To_String (Parent)) loop
         declare
            Next : constant String := Epub.Files.Parent_Path (To_String (Parent));
         begin
            if Next = To_String (Parent) then
               Result.Scope := Whole_Run;
               return Result;
            end if;
            Suffix := To_Unbounded_String
              (Epub.Files.Join (Epub.Files.Basename (To_String (Parent)), To_String (Suffix)));
            Parent := To_Unbounded_String (Next);
         end;
      end loop;
      declare
         Text : constant String := To_String (Parent);
         Extended : constant String :=
           (if Text'Length >= 4 and then Text (1 .. 4) = "\\?\" then Text
            elsif Text'Length >= 2 and then Text (1 .. 2) = "\\" then "\\?\UNC\" & Text (3 .. Text'Last)
            else "\\?\" & Text);
         Wide : constant String := Epub.Encoding.From_UTF8 (Extended, Epub.Encoding.UTF16_LE)
           & Character'Val (0) & Character'Val (0);
         Handle : constant System.Address := Win.CreateFileW
           (Wide'Address, 0, 7, System.Null_Address, 3, 16#0200_0000#, System.Null_Address);
         Success, Closed : Win.BOOL;
      begin
         if Handle = Invalid then
            Result.Scope := Whole_Run;
            return Result;
         end if;
         Success := File_Information (Handle, Data'Address);
         Closed := Win.CloseHandle (Handle);
         if Success = 0 or else Closed = 0 then
            Result.Scope := Whole_Run;
            return Result;
         end if;
      end;
      Result.Anchor := To_Unbounded_String (Data (7)'Image & ":" & Data (11)'Image & ":" & Data (12)'Image);
      Result.Directory := Result.Anchor & "/" & Fold (To_String (Suffix));
      Result.Target := To_Unbounded_String (Fold (Epub.Files.Basename (Path)));
      if Index (Suffix, "~") /= 0 then
         Result.Scope := Whole_Anchor;
      elsif Index (Result.Target, "~") /= 0 then
         Result.Scope := Whole_Directory;
      end if;
      return Result;
   exception
      when Epub.Files.File_Error | Epub.Encoding.Invalid_Encoding | Constraint_Error =>
         Result.Scope := Whole_Run;
         return Result;
   end Identify;
end Epub.Destinations.Native;

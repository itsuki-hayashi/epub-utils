with Epub.Files;
with Interfaces;
with Interfaces.C;
with System;

package body Epub.Destinations.Native is
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   function Identity
     (Path : String; Device, Inode, Case_Sensitive : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_directory_identity";
   function Identify (Path : String) return Key is
      Result : Key;
      Parent : Unbounded_String := To_Unbounded_String (Epub.Files.Parent_Path (Path));
      Suffix : Unbounded_String;
      Device, Inode : aliased Interfaces.Unsigned_64 := 0;
      Case_Sensitive : aliased Interfaces.C.int := 0;
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
      if Identity (To_String (Parent) & Character'Val (0), Device'Address, Inode'Address,
                   Case_Sensitive'Address) /= 0
      then
         Result.Scope := Whole_Run;
         return Result;
      end if;
      Result.Anchor := To_Unbounded_String (Device'Image & ":" & Inode'Image);
      Result.Directory := Result.Anchor & "/" & Suffix;
      Result.Target := To_Unbounded_String (Epub.Files.Basename (Path));
      if Case_Sensitive = 0 then
         Result.Scope := (if Length (Suffix) = 0 then Whole_Directory else Whole_Anchor);
      end if;
      return Result;
   exception
      when Epub.Files.File_Error =>
         Result.Scope := Whole_Run;
         return Result;
   end Identify;
end Epub.Destinations.Native;

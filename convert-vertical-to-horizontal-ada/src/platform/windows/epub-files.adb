with Epub.Performance;
with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Finalization;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Text_IO;
with Epub.Digests;
with Interfaces;
with Interfaces.C;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;
with Epub.Encoding;
with Epub.Windows;
with Epub.Publication;

package body Epub.Files is
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type Epub.Publication.State;
   use System.Storage_Elements;
   package Win renames Epub.Windows;
   package Scalars renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
   package Wide_Access is new System.Address_To_Access_Conversions (Interfaces.Unsigned_16);
   package Pointer_Access is new System.Address_To_Access_Conversions (System.Address);
   Invalid_Handle : constant System.Address := To_Address (Integer_Address'Last);
   Sequence : Natural := 0;
   type File_Owner is new Ada.Finalization.Limited_Controlled with record
      Handle : System.Address := System.Null_Address;
   end record;
   overriding procedure Finalize (Owner : in out File_Owner);

   procedure Check (Success : Win.BOOL; Context : String) is
   begin
      if Success = 0 then
         raise File_Error with Context;
      end if;
   end Check;

   procedure Close (Owner : in out File_Owner) is
      Status : Win.BOOL;
   begin
      if Owner.Handle /= System.Null_Address and then Owner.Handle /= Invalid_Handle then
         Status := Win.CloseHandle (Owner.Handle);
         Owner.Handle := System.Null_Address;
         Check (Status, "Cannot close file handle");
      end if;
   end Close;

   overriding procedure Finalize (Owner : in out File_Owner) is
   begin
      Close (Owner);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
           "File cleanup failure: " & Ada.Exceptions.Exception_Message (Error));
   end Finalize;

   function Wide (Value : String) return String is
     (Epub.Encoding.From_UTF8 (Value, Epub.Encoding.UTF16_LE) &
        Character'Val (0) & Character'Val (0));

   function Read_Wide (Pointer : System.Address) return String is
      Bytes : Unbounded_String;
      Position : Natural := 0;
   begin
      loop
         declare
            Value : constant Interfaces.Unsigned_16 :=
              Wide_Access.To_Pointer (Pointer + Storage_Offset (Position * 2)).all;
         begin
            exit when Value = 0;
            Append (Bytes, Character'Val (Value mod 256));
            Append (Bytes, Character'Val (Value / 256));
            Position := Position + 1;
         end;
      end loop;
      return Scalars.Encode (Scalars.Decode
        (To_String (Bytes), Ada.Strings.UTF_Encoding.UTF_16LE));
   end Read_Wide;

   function Current_Directory return String is
      Required : constant Win.DWORD := Win.GetCurrentDirectoryW (0, System.Null_Address);
      Buffer : String (1 .. Natural (Required) * 2);
      Written : Win.DWORD;
   begin
      if Required = 0 then
         raise File_Error with "Cannot obtain current directory";
      end if;
      Written := Win.GetCurrentDirectoryW (Required, Buffer'Address);
      if Written = 0 or else Written >= Required then
         raise File_Error with "Current directory changed while being read";
      end if;
      return Read_Wide (Buffer'Address);
   end Current_Directory;

   function Absolute_Path (Path : String) return String is
      Input : constant String := Wide (Path);
      Required : constant Win.DWORD :=
        Win.GetFullPathNameW (Input'Address, 0, System.Null_Address, System.Null_Address);
      Buffer : String (1 .. Natural (Required) * 2);
      Written : Win.DWORD;
   begin
      if Required = 0 then
         raise File_Error with "Cannot resolve path: " & Path;
      end if;
      Written := Win.GetFullPathNameW (Input'Address, Required, Buffer'Address, System.Null_Address);
      if Written = 0 or else Written >= Required then
         raise File_Error with "Cannot resolve path: " & Path;
      end if;
      return Read_Wide (Buffer'Address);
   end Absolute_Path;

   function Native_Path (Path : String) return String is
      Absolute : constant String := Absolute_Path (Path);
   begin
      if Absolute'Length >= 4 and then Absolute (1 .. 4) = "\\?\" then
         return Wide (Absolute);
      elsif Absolute'Length >= 2 and then Absolute (1 .. 2) = "\\" then
         return Wide ("\\?\UNC\" & Absolute (3 .. Absolute'Last));
      else
         return Wide ("\\?\" & Absolute);
      end if;
   end Native_Path;

   function Join (Directory, Name : String) return String is
   begin
      if Directory'Length = 0 then
         return Name;
      elsif Directory (Directory'Last) in '\' | '/' then
         return Directory & Name;
      else
         return Directory & '\' & Name;
      end if;
   end Join;

   function Last_Separator (Path : String) return Natural is
   begin
      for Position in reverse Path'Range loop
         if Path (Position) in '\' | '/' then
            return Position;
         end if;
      end loop;
      return 0;
   end Last_Separator;

   function Parent_Path (Path : String) return String is
      Position : constant Natural := Last_Separator (Path);
   begin
      if Position = 0 then
         return ".";
      elsif Position = Path'First or else (Position = Path'First + 2 and then Path (Position - 1) = ':') then
         return Path (Path'First .. Position);
      else
         return Path (Path'First .. Position - 1);
      end if;
   end Parent_Path;

   function Basename (Path : String) return String is
      Position : constant Natural := Last_Separator (Path);
   begin
      return Path ((if Position = 0 then Path'First else Position + 1) .. Path'Last);
   end Basename;

   function Attributes (Path : String) return Win.DWORD is
      Native : constant String := Native_Path (Path);
   begin
      return Win.GetFileAttributesW (Native'Address);
   end Attributes;

   function Exists (Path : String) return Boolean is
      Value : constant Win.DWORD := Attributes (Path);
   begin
      if Value = 16#FFFF_FFFF# then
         declare
            Error_Code : constant Win.DWORD := Win.GetLastError;
         begin
            if Error_Code not in 2 | 3 then
               raise File_Error with "Cannot inspect path: " & Path;
            end if;
         end;
         return False;
      end if;
      return True;
   end Exists;

   function Is_Directory (Path : String) return Boolean is
      Value : constant Win.DWORD := Attributes (Path);
   begin
      return Value /= 16#FFFF_FFFF# and then (Value and 16#10#) /= 0;
   end Is_Directory;

   procedure Ensure_Directory (Path : String) is
   begin
      if Is_Directory (Path) then
         return;
      elsif Exists (Path) then
         raise File_Error with "Path exists but is not a directory: " & Path;
      end if;
      declare
         Parent : constant String := Parent_Path (Path);
         Native : constant String := Native_Path (Path);
      begin
         if Parent = Path then
            raise File_Error with "Cannot create directory: " & Path;
         end if;
         Ensure_Directory (Parent);
         if Win.CreateDirectoryW (Native'Address, System.Null_Address) = 0
           and then not Is_Directory (Path)
         then
            raise File_Error with "Cannot create directory: " & Path;
         end if;
      end;
   end Ensure_Directory;

   function Open_File (Path : String; Exclusive : Boolean) return File_Owner is
      Native : constant String := Native_Path (Path);
   begin
      return Owner : File_Owner do
         Owner.Handle := Win.CreateFileW
           (Native'Address, (if Exclusive then 16#4000_0000# else 16#8000_0000#),
            (if Exclusive then 0 else 1), System.Null_Address,
            (if Exclusive then 1 else 3), 16#80#, System.Null_Address);
         if Owner.Handle = Invalid_Handle then
            raise File_Error with "Cannot " & (if Exclusive then "create exclusively: " else "open: ") & Path;
         end if;
      end return;
   end Open_File;

   function Read (Path : String) return String is
      Owner : File_Owner := Open_File (Path, False);
      Size : aliased Interfaces.Unsigned_64 := 0;
   begin
      Check (Win.GetFileSizeEx (Owner.Handle, Size'Address), "Cannot determine file size: " & Path);
      if Size > Interfaces.Unsigned_64 (Natural'Last) then
         raise File_Error with "File exceeds the in-memory archive size limit: " & Path;
      end if;
      declare
         Bytes : String (1 .. Natural (Size));
         Position : Positive := 1;
         Transferred : aliased Win.DWORD := 0;
      begin
         while Position <= Bytes'Last loop
            Check (Win.ReadFile (Owner.Handle, Bytes (Position)'Address,
              Win.DWORD (Integer'Min (1_048_576, Bytes'Last - Position + 1)),
              Transferred'Address, System.Null_Address), "Cannot read: " & Path);
            if Transferred = 0 then
               raise File_Error with "Unexpected end of file: " & Path;
            end if;
            Position := Position + Natural (Transferred);
         end loop;
         Close (Owner);
         return Bytes;
      end;
   end Read;

   procedure Save_Exclusive
     (Path, Bytes : String; Created : not null access Boolean) is
   begin
      Created.all := False;
      declare
         Owner : File_Owner := Open_File (Path, True);
         Position : Integer := Bytes'First;
         Transferred : aliased Win.DWORD := 0;
      begin
         Created.all := True;
         while Position <= Bytes'Last loop
            Check (Win.WriteFile (Owner.Handle, Bytes (Position)'Address,
              Win.DWORD (Integer'Min (1_048_576, Bytes'Last - Position + 1)),
              Transferred'Address, System.Null_Address), "Cannot write: " & Path);
            if Transferred = 0 then
               raise File_Error with "Incomplete write: " & Path;
            end if;
            Position := Position + Natural (Transferred);
         end loop;
         Check (Win.FlushFileBuffers (Owner.Handle), "Cannot flush: " & Path);
         Close (Owner);
      end;
   end Save_Exclusive;

   procedure Write_Exclusive (Path, Bytes : String) is
      Created : aliased Boolean := False;
   begin
      Save_Exclusive (Path, Bytes, Created'Access);
   exception
      when others =>
         if Created then
            Remove (Path);
         end if;
         raise;
   end Write_Exclusive;

   procedure Remove (Path : String) is
      Native : constant String := Native_Path (Path);
   begin
      if Win.DeleteFileW (Native'Address) = 0 then
         declare
            Error_Code : constant Win.DWORD := Win.GetLastError;
         begin
            if Error_Code not in 2 | 3 then
               raise File_Error with "Cannot remove temporary output: " & Path;
            end if;
         end;
      end if;
   end Remove;

   procedure Publish (Temporary_Path, Destination : String) is
      Source : constant String := Native_Path (Temporary_Path);
      Target : constant String := Native_Path (Destination);
   begin
      Check (Win.MoveFileW (Source'Address, Target'Address),
             "Cannot publish without replacement: " & Destination);
   end Publish;

   procedure Write_Checked (Destination, Bytes : String; Expected_SHA256 : String := "") is
      Temporary : Unbounded_String;
      Expected : Unbounded_String;
      Reserved : aliased Boolean := False;
      State : Epub.Publication.State := Epub.Publication.Unverified;
   begin
      if Exists (Destination) then
         raise File_Error with "Refusing to overwrite: " & Destination;
      end if;
      if Expected_SHA256 = "" then
         Epub.Performance.Start (Epub.Performance.Hashing);
         Expected := To_Unbounded_String (Ada.Characters.Handling.To_Upper (Epub.Digests.Digest (Bytes)));
         Epub.Performance.Stop (Epub.Performance.Hashing);
      else
         Expected := To_Unbounded_String (Ada.Characters.Handling.To_Upper (Expected_SHA256));
      end if;
      if Length (Expected) /= 64 then
         raise File_Error with "Invalid expected SHA-256 digest";
      end if;
      for Value of To_String (Expected) loop
         if Value not in '0' .. '9' | 'A' .. 'F' then
            raise File_Error with "Invalid expected SHA-256 digest";
         end if;
      end loop;
      loop
         Sequence := Sequence + 1;
         Temporary := To_Unbounded_String (Join (Parent_Path (Destination),
           ".epub-horizontal-" & Ada.Strings.Fixed.Trim (Win.GetCurrentProcessId'Image, Ada.Strings.Both)
           & "-" & Ada.Strings.Fixed.Trim (Sequence'Image, Ada.Strings.Both) & ".tmp"));
         exit when not Exists (To_String (Temporary));
      end loop;
      Epub.Performance.Start (Epub.Performance.Output_Write);
      Save_Exclusive (To_String (Temporary), Bytes, Reserved'Access);
      Epub.Performance.Stop (Epub.Performance.Output_Write);
      declare
         Saved : constant String := Read (To_String (Temporary));
      begin
         Epub.Performance.Start (Epub.Performance.Hashing);
         if Ada.Characters.Handling.To_Upper (Epub.Digests.Digest (Saved)) /= To_String (Expected) then
            raise File_Error with "Temporary output verification failed";
         end if;
         Epub.Performance.Stop (Epub.Performance.Hashing);
         Verify_Bytes (Saved);
         Epub.Publication.Mark_Verified (State);
      end;
      if not Epub.Publication.Eligible (State, Exists (Destination)) then
         raise File_Error with "Refusing to publish unverified output or overwrite: " & Destination;
      end if;
      Epub.Performance.Start (Epub.Performance.Publication);
      Publish (To_String (Temporary), Destination);
      Epub.Performance.Stop (Epub.Performance.Publication);
      Epub.Publication.Mark_Published (State);
      pragma Assert (State = Epub.Publication.Published);
      Reserved := False;
   exception
      when Error : others =>
         if Reserved then
            begin
               Remove (To_String (Temporary));
            exception
               when Cleanup : others =>
                  raise File_Error with Ada.Exceptions.Exception_Message (Error) &
                    "; cleanup failed: " & Ada.Exceptions.Exception_Message (Cleanup);
            end;
         end if;
         raise;
   end Write_Checked;

   procedure Write_Verified (Destination, Bytes : String; Expected_SHA256 : String := "") is
      procedure No_Additional_Check (Saved : String) is
         pragma Unreferenced (Saved);
      begin
         null;
      end No_Additional_Check;
      procedure Save is new Write_Checked (No_Additional_Check);
   begin
      Save (Destination, Bytes, Expected_SHA256);
   end Write_Verified;

   procedure Sort (Items : in out Epub.Resources.String_Lists.Vector) is
   begin
      for Position in 2 .. Items.Last_Index loop
         declare
            Value : constant Unbounded_String := Items (Position);
            Cursor : Positive := Position;
         begin
            while Cursor > 1 and then To_String (Items (Cursor - 1)) > To_String (Value) loop
               Items.Replace_Element (Cursor, Items (Cursor - 1));
               Cursor := Cursor - 1;
            end loop;
            Items.Replace_Element (Cursor, Value);
         end;
      end loop;
   end Sort;

   function EPUB_Files (Path : String; Recursive : Boolean)
      return Epub.Resources.String_Lists.Vector is
      Queue, Result : Epub.Resources.String_Lists.Vector;
      Position : Positive := 1;
      function Is_EPUB (Name : String) return Boolean is
        (Name'Length >= 5 and then
         Ada.Characters.Handling.To_Lower (Name (Name'Last - 4 .. Name'Last)) = ".epub");
   begin
      if not Is_Directory (Path) then
         if not Exists (Path) or else not Is_EPUB (Path) then
            raise File_Error with "Input must be an existing EPUB file or directory";
         end if;
         Result.Append (To_Unbounded_String (Path));
         return Result;
      end if;
      Queue.Append (To_Unbounded_String (Path));
      while Position <= Queue.Last_Index loop
         declare
            Directory : constant String := To_String (Queue (Position));
            Pattern : constant String := Native_Path (Join (Directory, "*"));
            Data : Win.Find_Data;
            Handle : System.Address := Win.FindFirstFileW (Pattern'Address, Data'Address);
         begin
            if Handle = Invalid_Handle then
               if Win.GetLastError /= 2 then
                  raise File_Error with "Cannot enumerate directory: " & Directory;
               end if;
            else
               begin
                  loop
                     declare
                        Name : constant String := Read_Wide (Data.Filename'Address);
                        Candidate : constant String := Join (Directory, Name);
                     begin
                        if Name not in "." | ".." then
                           if (Data.Attributes and 16#10#) /= 0 then
                              if Recursive and then (Data.Attributes and 16#400#) = 0
                                and then Ada.Characters.Handling.To_Lower (Name) /= "horizontal"
                              then
                                 Queue.Append (To_Unbounded_String (Candidate));
                              end if;
                           elsif Is_EPUB (Name) then
                              Result.Append (To_Unbounded_String (Candidate));
                           end if;
                        end if;
                     end;
                     if Win.FindNextFileW (Handle, Data'Address) = 0 then
                        if Win.GetLastError /= 18 then
                           raise File_Error with "Directory enumeration failed: " & Directory;
                        end if;
                        exit;
                     end if;
                  end loop;
                  declare
                     Status : constant Win.BOOL := Win.FindClose (Handle);
                  begin
                     Handle := Invalid_Handle;
                     Check (Status, "Cannot close directory search");
                  end;
               exception
                  when others =>
                     if Handle /= Invalid_Handle then
                        Check (Win.FindClose (Handle), "Cannot close failed directory search");
                     end if;
                     raise;
               end;
            end if;
         end;
         Position := Position + 1;
      end loop;
      if Result.Is_Empty then
         raise File_Error with "No EPUB files found";
      end if;
      Sort (Result);
      return Result;
   end EPUB_Files;

   function Arguments return Epub.Resources.String_Lists.Vector is
      Count : aliased Interfaces.C.int := 0;
      Pointers : constant System.Address := Win.CommandLineToArgvW (Win.GetCommandLineW, Count'Address);
      Result : Epub.Resources.String_Lists.Vector;
   begin
      if Pointers = System.Null_Address then
         raise File_Error with "Cannot read Unicode command line";
      end if;
      begin
         for Position in 1 .. Integer (Count) - 1 loop
            Result.Append (To_Unbounded_String (Read_Wide
              (Pointer_Access.To_Pointer
                 (Pointers + Storage_Offset (Position * (System.Address'Size / 8))).all)));
         end loop;
      exception
         when others =>
            if Win.LocalFree (Pointers) /= System.Null_Address then
               raise File_Error with "Cannot free Unicode command line";
            end if;
            raise;
      end;
      if Win.LocalFree (Pointers) /= System.Null_Address then
         raise File_Error with "Cannot free Unicode command line";
      end if;
      return Result;
   end Arguments;

   procedure Configure_Console is
      Status : constant Win.BOOL := Win.SetConsoleOutputCP (65001);
   begin
      if Status = 0 then
         return;
      end if;
   end Configure_Console;
end Epub.Files;

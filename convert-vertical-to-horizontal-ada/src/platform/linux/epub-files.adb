with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Finalization;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.SHA256;
with Interfaces.C;
with System;
with Epub.Publication;

package body Epub.Files is
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Interfaces.C.long_long;
   use type Epub.Publication.State;
   function C_Open (Path : String; Exclusive : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_open";
   function C_Close (FD : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_close";
   function C_Flush (FD : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_flush";
   function C_Size (FD : Interfaces.C.int) return Interfaces.C.long_long
     with Import, Convention => C, External_Name => "epub_size";
   function C_Read (FD : Interfaces.C.int; Buffer : System.Address; Count : Interfaces.C.size_t)
     return Interfaces.C.long_long
     with Import, Convention => C, External_Name => "epub_read";
   function C_Write (FD : Interfaces.C.int; Buffer : System.Address; Count : Interfaces.C.size_t)
     return Interfaces.C.long_long
     with Import, Convention => C, External_Name => "epub_write";
   function C_Kind (Path : String; Follow : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_kind";
   function C_Remove (Path : String) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_remove";
   function C_Publish (Source, Destination : String) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_publish";
   function C_PID return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_pid";
   Sequence : Natural := 0;
   type File_Owner is new Ada.Finalization.Limited_Controlled with record
      FD : Interfaces.C.int := -1;
   end record;
   overriding procedure Finalize (Owner : in out File_Owner);

   function Native (Path : String) return String is
   begin
      for Value of Path loop
         if Value = Character'Val (0) then
            raise File_Error with "NUL in filesystem path";
         end if;
      end loop;
      return Path & Character'Val (0);
   end Native;

   procedure Check (Status : Interfaces.C.int; Context : String) is
   begin
      if Status < 0 then
         raise File_Error with Context & " (errno" & Interfaces.C.int'Image (-Status) & ")";
      end if;
   end Check;

   procedure Close (Owner : in out File_Owner) is
      Status : Interfaces.C.int;
   begin
      if Owner.FD >= 0 then
         Status := C_Close (Owner.FD);
         Owner.FD := -1;
         Check (Status, "Cannot close file");
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

   function Current_Directory return String is (Ada.Directories.Current_Directory);
   function Absolute_Path (Path : String) return String is (Ada.Directories.Full_Name (Path));
   function Join (Directory, Name : String) return String is
     (if Directory = "" then Name
      elsif Directory (Directory'Last) = '/' then Directory & Name
      else Directory & '/' & Name);
   function Parent_Path (Path : String) return String is
   begin
      for Position in reverse Path'Range loop
         if Path (Position) = '/' then
            return (if Position = Path'First then "/" else Path (Path'First .. Position - 1));
         end if;
      end loop;
      return ".";
   end Parent_Path;
   function Basename (Path : String) return String is
   begin
      for Position in reverse Path'Range loop
         if Path (Position) = '/' then
            return Path (Position + 1 .. Path'Last);
         end if;
      end loop;
      return Path;
   end Basename;
   function Kind (Path : String; Follow : Boolean := False) return Interfaces.C.int is
      Result : constant Interfaces.C.int := C_Kind (Native (Path), Boolean'Pos (Follow));
   begin
      Check (Result, "Cannot inspect path: " & Path);
      return Result;
   end Kind;
   function Exists (Path : String) return Boolean is (Kind (Path) /= 0);
   function Is_Directory (Path : String) return Boolean is (Kind (Path, True) = 2);
   procedure Ensure_Directory (Path : String) is
   begin
      if not Is_Directory (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   end Ensure_Directory;

   function Open_File (Path : String; Exclusive : Boolean) return File_Owner is
   begin
      return Owner : File_Owner do
         Owner.FD := C_Open (Native (Path), Boolean'Pos (Exclusive));
         Check (Owner.FD, "Cannot " & (if Exclusive then "create exclusively: " else "open: ") & Path);
      end return;
   end Open_File;
   function Read (Path : String) return String is
      Owner : File_Owner := Open_File (Path, False);
      Size : constant Interfaces.C.long_long := C_Size (Owner.FD);
   begin
      if Size < 0 or else Size > Interfaces.C.long_long (Natural'Last) then
         raise File_Error with "Cannot read file size or file exceeds the in-memory archive size limit: " & Path;
      end if;
      declare
         Bytes : String (1 .. Natural (Size));
         Position : Positive := 1;
      begin
         while Position <= Bytes'Last loop
            declare
               Count : constant Interfaces.C.long_long := C_Read
                 (Owner.FD, Bytes (Position)'Address,
                  Interfaces.C.size_t (Integer'Min (1_048_576, Bytes'Last - Position + 1)));
            begin
               if Count <= 0 then
                  raise File_Error with "Cannot read complete file: " & Path;
               end if;
               Position := Position + Natural (Count);
            end;
         end loop;
         Close (Owner);
         return Bytes;
      end;
   end Read;

   procedure Save_Exclusive (Path, Bytes : String; Created : not null access Boolean) is
   begin
      Created.all := False;
      declare
         Owner : File_Owner := Open_File (Path, True);
         Position : Integer := Bytes'First;
      begin
         Created.all := True;
         while Position <= Bytes'Last loop
            declare
               Count : constant Interfaces.C.long_long := C_Write
                 (Owner.FD, Bytes (Position)'Address,
                  Interfaces.C.size_t (Integer'Min (1_048_576, Bytes'Last - Position + 1)));
            begin
               if Count <= 0 then
                  raise File_Error with "Cannot write complete file: " & Path;
               end if;
               Position := Position + Natural (Count);
            end;
         end loop;
         Check (C_Flush (Owner.FD), "Cannot flush: " & Path);
         Close (Owner);
      end;
   end Save_Exclusive;
   procedure Remove (Path : String) is
   begin
      Check (C_Remove (Native (Path)), "Cannot remove temporary output: " & Path);
   end Remove;
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
   procedure Publish (Temporary_Path, Destination : String) is
   begin
      Check (C_Publish (Native (Temporary_Path), Native (Destination)),
        "Cannot publish without replacement: " & Destination);
   end Publish;

   procedure Write_Checked (Destination, Bytes : String) is
      Temporary : Unbounded_String;
      Reserved : aliased Boolean := False;
      State : Epub.Publication.State := Epub.Publication.Unverified;
   begin
      if Exists (Destination) then
         raise File_Error with "Refusing to overwrite: " & Destination;
      end if;
      loop
         Sequence := Sequence + 1;
         Temporary := To_Unbounded_String (Join (Parent_Path (Destination),
           ".epub-horizontal-" & Ada.Strings.Fixed.Trim (C_PID'Image, Ada.Strings.Both) & "-" &
           Ada.Strings.Fixed.Trim (Sequence'Image, Ada.Strings.Both) & ".tmp"));
         exit when not Exists (To_String (Temporary));
      end loop;
      Save_Exclusive (To_String (Temporary), Bytes, Reserved'Access);
      declare
         Saved : constant String := Read (To_String (Temporary));
      begin
         if GNAT.SHA256.Digest (Saved) /= GNAT.SHA256.Digest (Bytes) then
            raise File_Error with "Temporary output verification failed";
         end if;
         Verify_Bytes (Saved);
         Epub.Publication.Mark_Verified (State);
      end;
      if not Epub.Publication.Eligible (State, Exists (Destination)) then
         raise File_Error with "Refusing to publish unverified output or overwrite: " & Destination;
      end if;
      Publish (To_String (Temporary), Destination);
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
   procedure Write_Verified (Destination, Bytes : String) is
      procedure No_Additional_Check (Saved : String) is
         pragma Unreferenced (Saved);
      begin
         null;
      end No_Additional_Check;
      procedure Save is new Write_Checked (No_Additional_Check);
   begin
      Save (Destination, Bytes);
   end Write_Verified;

   function EPUB_Files (Path : String; Recursive : Boolean)
     return Epub.Resources.String_Lists.Vector is
      Queue, Result : Epub.Resources.String_Lists.Vector;
      Position : Positive := 1;
      function Is_EPUB (Name : String) return Boolean is
        (Name'Length >= 5 and then
         Ada.Characters.Handling.To_Lower (Name (Name'Last - 4 .. Name'Last)) = ".epub");
   begin
      if not Is_Directory (Path) then
         if Kind (Path, True) /= 1 or else not Is_EPUB (Path) then
            raise File_Error with "Input must be an existing EPUB file or directory";
         end if;
         Result.Append (To_Unbounded_String (Path));
         return Result;
      end if;
      Queue.Append (To_Unbounded_String (Path));
      while Position <= Queue.Last_Index loop
         declare
            Directory : constant String := To_String (Queue (Position));
            Search : Ada.Directories.Search_Type;
            Entry_Info : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Start_Search (Search, Directory, "");
            begin
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Entry_Info);
                  declare
                     Name : constant String := Ada.Directories.Simple_Name (Entry_Info);
                     Candidate : constant String := Join (Directory, Name);
                     Entry_Kind : constant Interfaces.C.int := Kind (Candidate);
                  begin
                     if Name not in "." | ".." then
                        if Entry_Kind = 2 and then Recursive and then
                          Ada.Characters.Handling.To_Lower (Name) /= "horizontal"
                        then
                           Queue.Append (To_Unbounded_String (Candidate));
                        elsif Entry_Kind in 1 | 3 and then Is_EPUB (Name)
                          and then Kind (Candidate, True) = 1
                        then
                           Result.Append (To_Unbounded_String (Candidate));
                        end if;
                     end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
            exception
               when others =>
                  Ada.Directories.End_Search (Search);
                  raise;
            end;
         end;
         Position := Position + 1;
      end loop;
      if Result.Is_Empty then
         raise File_Error with "No EPUB files found";
      end if;
      for Index in 2 .. Result.Last_Index loop
         declare
            Value : constant Unbounded_String := Result (Index);
            Cursor : Positive := Index;
         begin
            while Cursor > 1 and then To_String (Result (Cursor - 1)) > To_String (Value) loop
               Result.Replace_Element (Cursor, Result (Cursor - 1));
               Cursor := Cursor - 1;
            end loop;
            Result.Replace_Element (Cursor, Value);
         end;
      end loop;
      return Result;
   end EPUB_Files;
   function Arguments return Epub.Resources.String_Lists.Vector is
      Result : Epub.Resources.String_Lists.Vector;
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         Result.Append (To_Unbounded_String (Ada.Command_Line.Argument (Index)));
      end loop;
      return Result;
   end Arguments;
   procedure Configure_Console is
   begin
      null;
   end Configure_Console;
end Epub.Files;

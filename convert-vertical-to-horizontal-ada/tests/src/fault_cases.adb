with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with Epub.Files;
with Epub.Resources;

package body Fault_Cases is
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;
   use type Native_Faults.Operation;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Native_Faults.Operation; Skip : Natural := 0)
      return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      Result.all.Skip := Skip;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Native failure: " & Item.Kind'Image & " skip=" & Item.Skip'Image));

   overriding procedure Run_Test (Item : in out Unit_Case) is
      Stamp : constant String := Ada.Calendar.Formatting.Image
        (Ada.Calendar.Clock, Include_Time_Fraction => True);
      Root : Unbounded_String := To_Unbounded_String
        (Epub.Files.Absolute_Path ("../test-results/native-" & Item.Kind'Image & Item.Skip'Image & "-"));
      Rejected : Boolean := False;
      Snapshot : Unbounded_String;
   begin
      for Value of Stamp loop
         if Value in '0' .. '9' then
            Append (Root, Value);
         end if;
      end loop;
      Epub.Files.Ensure_Directory (To_String (Root));
      declare
         Input : constant String := Epub.Files.Join (To_String (Root), "input.epub");
         Output : constant String := Epub.Files.Join (To_String (Root), "output.epub");
      begin
         Epub.Files.Write_Exclusive (Input, "payload");
         Native_Faults.Arm (Item.Kind, Item.Skip);
         begin
            case Item.Kind is
               when Native_Faults.Open_File | Native_Faults.Read_File |
                    Native_Faults.Zero_Read | Native_Faults.File_Size =>
                  Snapshot := To_Unbounded_String (Epub.Files.Read (Input));
               when Native_Faults.Write_File | Native_Faults.Zero_Write |
                    Native_Faults.Flush_File | Native_Faults.Close_File | Native_Faults.Move_File =>
                  Epub.Files.Write_Verified (Output, "payload");
               when Native_Faults.Delete_File =>
                  Epub.Files.Remove (Input);
               when Native_Faults.File_Attributes =>
                  Snapshot := To_Unbounded_String (Epub.Files.Exists (Input)'Image);
               when Native_Faults.Create_Directory =>
                  Epub.Files.Ensure_Directory (Output & "-directory");
               when Native_Faults.Find_First | Native_Faults.Find_Next | Native_Faults.Close_Search =>
                  declare
                     Found : constant Epub.Resources.String_Lists.Vector :=
                       Epub.Files.EPUB_Files (To_String (Root), True);
                  begin
                     Snapshot := To_Unbounded_String (Found.Last_Index'Image);
                  end;
               when Native_Faults.Current_Directory =>
                  Snapshot := To_Unbounded_String (Epub.Files.Current_Directory);
               when Native_Faults.Full_Path =>
                  Snapshot := To_Unbounded_String (Epub.Files.Absolute_Path (Input));
               when Native_Faults.Arguments | Native_Faults.Free_Arguments =>
                  declare
                     Found : constant Epub.Resources.String_Lists.Vector := Epub.Files.Arguments;
                  begin
                     Snapshot := To_Unbounded_String (Found.Last_Index'Image);
                  end;
               when Native_Faults.Console_Codepage =>
                  Epub.Files.Configure_Console;
               when Native_Faults.None =>
                  null;
            end case;
         exception
            when Error : Epub.Files.File_Error =>
               Rejected := True;
               Snapshot := To_Unbounded_String (Ada.Exceptions.Exception_Message (Error));
         end;
         Native_Faults.Arm (Native_Faults.None);
         if Item.Kind = Native_Faults.Console_Codepage then
            Assert (not Rejected, "A redirected console need not accept a codepage");
         else
            Assert (Rejected, "Injected failure did not propagate; returned " & To_String (Snapshot));
            Assert (Length (Snapshot) > 0, "Failure must have a diagnostic");
         end if;
         Assert (not Epub.Files.Exists (Output), "Failed operation must not publish an output");
         Assert (Epub.Files.Read (Input) = "payload", "Injected failure must preserve the source");
         declare
            Leftover : Boolean := False;
            procedure Found (Directory_Item : Ada.Directories.Directory_Entry_Type) is
            begin
               Leftover := Leftover or else Ada.Directories.Simple_Name (Directory_Item)'Length > 0;
            end Found;
         begin
            Ada.Directories.Search (To_String (Root), ".epub-horizontal-*.tmp", Process => Found'Access);
            Assert (not Leftover, "Injected failure must clean its temporary file");
         end;
      end;
   exception
      when others =>
         Native_Faults.Arm (Native_Faults.None);
         raise;
   end Run_Test;
end Fault_Cases;

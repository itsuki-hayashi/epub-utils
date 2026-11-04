with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with AUnit.Assertions;
with Epub.Files;
with Epub.Resources;
with Epub.File_Streams;
with Epub.Files.Write_Stream_Checked;
with Interfaces;
with GNAT.SHA256;
with Zip_Streams;
with Epub.Stream_IO;
with Epub.CPUs;
with Epub.Archives.Concurrent;
with Epub.Conversion;

package body Fault_Cases is
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;
   use type Native_Faults.Operation;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Native_Faults.Operation; Skip : Natural := 0; Streaming : Boolean := False;
                    Parallel : Boolean := False; Cleanup_Close : Boolean := False)
      return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      Result.all.Skip := Skip;
      Result.all.Streaming := Streaming;
      Result.all.Parallel := Parallel;
      Result.all.Cleanup_Close := Cleanup_Close;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Native failure: " & Item.Kind'Image & " skip=" & Item.Skip'Image &
       (if Item.Streaming then " streamed" elsif Item.Parallel then " parallel" else "") &
       (if Item.Cleanup_Close then " then close failure" else "")));

   procedure Run_Parallel (Item : Unit_Case; Root : String) is
      Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Sources, Outputs : Epub.Resources.String_Lists.Vector;
      Results : Epub.Conversion.Result_Lists.Vector;
      Settings : constant Epub.Conversion.Options := (others => <>);
      Input : constant String := Epub.Files.Join (Root, "source.epub");
      Original : constant String := Epub.Files.Read
        ("../../convert-vertical-to-horizontal-perl/t/fixtures/input/vertical CSS variants.epub");
      Errors, Successes : Natural := 0;
      Leftover : Boolean := False;
      use type Epub.Conversion.Processing_Status;
      procedure Found (Entry_Value : Ada.Directories.Directory_Entry_Type) is
         pragma Unreferenced (Entry_Value);
      begin
         Leftover := True;
      end Found;
   begin
      if Topology.Cores.Last_Index < 2 then return; end if;
      Cores.Append (Topology.Cores (1)); Cores.Append (Topology.Cores (2));
      Epub.Files.Write_Exclusive (Input, Original);
      for Index in 1 .. 2 loop
         Sources.Append (To_Unbounded_String (Input));
         Outputs.Append (To_Unbounded_String (Epub.Files.Join (Root, "output" & Index'Image & ".epub")));
      end loop;
      if Item.Cleanup_Close then Native_Faults.Arm_Write_Then_Close;
      else Native_Faults.Arm (Item.Kind, Item.Skip); end if;
      Epub.Archives.Concurrent.Process (Sources, Outputs, Settings, Cores, False, Results);
      Native_Faults.Arm (Native_Faults.None);
      for Result of Results loop
         if Result.Status = Epub.Conversion.Failed then
            Errors := Errors + 1;
            Assert (Length (Result.Error) > 0 and then not Epub.Files.Exists (To_String (Result.Output)),
                    "A failed parallel book reports its error and never publishes");
            if Item.Cleanup_Close then
               Assert (Ada.Strings.Fixed.Index (To_String (Result.Error), "Cannot write binary stream") = 1
                 and then Ada.Strings.Fixed.Index
                   (To_String (Result.Error), "; cleanup failed: Cannot close binary stream") > 0,
                 "Cleanup preserves the earlier write error and reports the secondary close failure");
            end if;
         else
            Successes := Successes + 1;
            Assert (Result.Status = Epub.Conversion.Converted and then Epub.Files.Exists (To_String (Result.Output)),
                    "An unrelated book completes after a worker filesystem error");
         end if;
      end loop;
      Assert (Errors = 1 and then Successes = 1, "One injected filesystem failure affects exactly one parallel book");
      Assert (Epub.Files.Read (Input) = Original, "Parallel failures preserve source bytes");
      Ada.Directories.Search (Root, ".epub-horizontal-*.tmp", Process => Found'Access);
      Assert (not Leftover, "Parallel failure cleanup releases every temporary file");
   exception
      when others => Native_Faults.Arm (Native_Faults.None); raise;
   end Run_Parallel;

   overriding procedure Run_Test (Item : in out Unit_Case) is
      Stamp : constant String := Ada.Calendar.Formatting.Image
        (Ada.Calendar.Clock, Include_Time_Fraction => True);
      Root : Unbounded_String := To_Unbounded_String
        (Epub.Files.Absolute_Path ("../test-results/native-" & Item.Kind'Image & Item.Skip'Image &
          (if Item.Streaming then "-streamed-" else "-")));
      Rejected : Boolean := False;
      Snapshot : Unbounded_String;
   begin
      for Value of Stamp loop
         if Value in '0' .. '9' then
            Append (Root, Value);
         end if;
      end loop;
      Epub.Files.Ensure_Directory (To_String (Root));
      if Item.Parallel then Run_Parallel (Item, To_String (Root)); return; end if;
      declare
         Input : constant String := Epub.Files.Join (To_String (Root), "input.epub");
         Output : constant String := Epub.Files.Join (To_String (Root), "output.epub");
         procedure Build
           (Stream : in out Zip_Streams.Root_Zipstream_Type'Class; Digest : out Unbounded_String) is
         begin
            Stream.Write ([112, 97, 121, 108, 111, 97, 100]);
            Digest := To_Unbounded_String (GNAT.SHA256.Digest ("payload"));
         end Build;
         procedure Check (Stream : in out Zip_Streams.Root_Zipstream_Type'Class) is
            pragma Unreferenced (Stream);
         begin
            null;
         end Check;
         procedure Save is new Epub.Files.Write_Stream_Checked (Build, Check);
         Bytes : Interfaces.Unsigned_64 := 0;
         Digest : Unbounded_String;
      begin
         Epub.Files.Write_Exclusive (Input, "payload");
         Native_Faults.Arm (Item.Kind, Item.Skip);
         begin
            case Item.Kind is
               when Native_Faults.Open_File | Native_Faults.Read_File |
                    Native_Faults.Zero_Read | Native_Faults.File_Size =>
                  if Item.Streaming then
                     declare
                        Stream : Epub.File_Streams.Stream;
                     begin
                        Stream.Open (Input);
                        Snapshot := To_Unbounded_String (Epub.Stream_IO.Digest (Stream));
                     end;
                  else
                     Snapshot := To_Unbounded_String (Epub.Files.Read (Input));
                  end if;
               when Native_Faults.Write_File | Native_Faults.Zero_Write |
                    Native_Faults.Flush_File | Native_Faults.Close_File | Native_Faults.Move_File =>
                  if Item.Streaming then
                     Save (Output, Bytes, Digest);
                     Snapshot := Digest & Bytes'Image;
                  else
                     Epub.Files.Write_Verified (Output, "payload");
                  end if;
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
            when Error : Epub.Files.File_Error | Epub.File_Streams.File_Error =>
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

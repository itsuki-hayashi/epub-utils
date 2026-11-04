with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Epub.Books;
with Epub.Conversion;
with Epub.Files;
with Epub.Reports;
with Epub.Resources;
with Epub.Performance;
with Epub.CPUs;
with Epub.Archives.Concurrent;

package body Epub.CLI is
   use Ada.Strings.Unbounded;
   use type Epub.Conversion.Processing_Status;
   procedure Help is
   begin
      Ada.Text_IO.Put_Line ("Usage: epub-v2h [options]");
      Ada.Text_IO.Put_Line ("  --input-path PATH        EPUB file or directory (default: current directory)");
      Ada.Text_IO.Put_Line ("  --output-directory DIR   Output directory (default: current-directory/horizontal)");
      Ada.Text_IO.Put_Line ("  --recursive, -r          Descend; write beside each source directory");
      Ada.Text_IO.Put_Line ("  --analyze-only           Inspect without creating output books");
      Ada.Text_IO.Put_Line ("  --what-if                Preview without creating books, directories or reports");
      Ada.Text_IO.Put_Line ("  --report-path FILE       Write a JSON report; never overwrite");
      Ada.Text_IO.Put_Line ("  --json                   JSON stdout; diagnostics use stderr");
      Ada.Text_IO.Put_Line ("  --verbose                Show input paths on stderr");
      Ada.Text_IO.Put_Line ("  --jobs auto|N            Physical performance-core workers (default: auto; 1 is sequential)");
      Ada.Text_IO.Put_Line ("  --help, -h               Show this help");
      Ada.Text_IO.Put_Line ("PowerShell-style aliases: --InputPath, --OutputDirectory, --Recursive,");
      Ada.Text_IO.Put_Line ("--AnalyzeOnly, --WhatIf, --ReportPath, --Verbose.");
      Ada.Text_IO.Put_Line ("Preserved books are exact copies. Conversion uses DEFLATE with stored fallback.");
      Ada.Text_IO.Put_Line ("Recursive mode ignores --output-directory,");
      Ada.Text_IO.Put_Line ("skips horizontal directories and does not follow directory links/junctions.");
   end Help;

   function Run return Natural is
      Arguments : constant Epub.Resources.String_Lists.Vector := Epub.Files.Arguments;
      Input_Path, Output_Directory, Report_Path : Unbounded_String;
      Settings : Epub.Conversion.Options;
      Recursive, JSON_Output, Verbose, Show_Help : Boolean := False;
      Position : Positive := 1;
      Results : Epub.Conversion.Result_Lists.Vector;
      Failures : Natural := 0;
      Jobs : Natural := 0;
      function Option_Value (Inline_Value : String; Has_Equals : Boolean) return String is
      begin
         if Has_Equals then
            return Inline_Value;
         elsif Position < Arguments.Last_Index then
            Position := Position + 1;
            return To_String (Arguments (Position));
         else
            raise Constraint_Error with "Missing option value";
         end if;
      end Option_Value;
   begin
      Epub.Files.Configure_Console;
      while Position <= Arguments.Last_Index loop
         declare
            Argument : constant String := To_String (Arguments (Position));
            Equals : constant Natural := Ada.Strings.Fixed.Index (Argument, "=");
            Name : constant String := Argument
              (Argument'First .. (if Equals = 0 then Argument'Last else Equals - 1));
            Value : constant String :=
              (if Equals = 0 then "" else Argument (Equals + 1 .. Argument'Last));
         begin
            if Name in "--input-path" | "--InputPath" then
               Input_Path := To_Unbounded_String (Option_Value (Value, Equals /= 0));
            elsif Name in "--output-directory" | "--OutputDirectory" then
               Output_Directory := To_Unbounded_String (Option_Value (Value, Equals /= 0));
            elsif Name in "--report-path" | "--ReportPath" then
               Report_Path := To_Unbounded_String (Option_Value (Value, Equals /= 0));
            elsif Name in "--jobs" | "--Jobs" then
               declare
                  Text : constant String := Option_Value (Value, Equals /= 0);
               begin
                  if Text = "auto" then
                     Jobs := 0;
                  else
                     if Text'Length = 0 then raise Constraint_Error; end if;
                     for Digit of Text loop
                        if Digit not in '0' .. '9' then raise Constraint_Error; end if;
                     end loop;
                     Jobs := Positive'Value (Text);
                     if Jobs = 0 then raise Constraint_Error; end if;
                  end if;
               exception
                  when Constraint_Error =>
                     raise Constraint_Error with "--jobs requires auto or a positive integer";
               end;
            elsif Equals /= 0 then
               raise Constraint_Error with "Unknown option or unexpected value: " & Argument;
            elsif Name in "--recursive" | "--Recursive" | "-r" then
               Recursive := True;
            elsif Name in "--analyze-only" | "--AnalyzeOnly" then
               Settings.Analyze_Only := True;
            elsif Name in "--what-if" | "--WhatIf" then
               Settings.Dry_Run := True;
            elsif Name = "--json" then
               JSON_Output := True;
            elsif Name in "--verbose" | "--Verbose" then
               Verbose := True;
            elsif Name in "--help" | "-h" then
               Show_Help := True;
            else
               raise Constraint_Error with "Unknown option: " & Argument;
            end if;
         end;
         Position := Position + 1;
      end loop;
      if Show_Help then
         Help;
         return 0;
      end if;
      Input_Path := To_Unbounded_String (Epub.Files.Absolute_Path
        ((if Length (Input_Path) = 0 then Epub.Files.Current_Directory else To_String (Input_Path))));
      if not Recursive then
         Output_Directory := To_Unbounded_String (Epub.Files.Absolute_Path
           ((if Length (Output_Directory) = 0
             then Epub.Files.Join (Epub.Files.Current_Directory, "horizontal")
             else To_String (Output_Directory))));
      end if;
      if Length (Report_Path) /= 0 then
         Report_Path := To_Unbounded_String (Epub.Files.Absolute_Path (To_String (Report_Path)));
         if not Settings.Dry_Run and then Epub.Files.Exists (To_String (Report_Path)) then
            raise Epub.Files.File_Error with "Refusing to overwrite report: " & To_String (Report_Path);
         elsif not Epub.Files.Is_Directory (Epub.Files.Parent_Path (To_String (Report_Path))) then
            raise Epub.Files.File_Error with "Report directory must already exist";
         end if;
      end if;
      declare
         Sources : constant Epub.Resources.String_Lists.Vector :=
           Epub.Files.EPUB_Files (To_String (Input_Path), Recursive);
         Outputs : Epub.Resources.String_Lists.Vector;
         Topology : Epub.CPUs.Topology;
         Selected : Epub.CPUs.Processor_Lists.Vector;
         procedure Emit_Result (Ordinal : Positive; Result : Epub.Conversion.Book_Result) is
         begin
            if Verbose then
               Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "Inspecting " & To_String (Sources (Ordinal)));
            end if;
               if Result.Status = Epub.Conversion.Failed then
                  Failures := Failures + 1;
                  Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                    To_String (Result.Book) & ": " & To_String (Result.Error));
               end if;
               if not JSON_Output then
                  Ada.Text_IO.Put_Line (Epub.Conversion.Status_Name (Result.Status) & Character'Val (9) &
                    (if Result.Has_Reason then Epub.Books.Reason_Name (Result.Reason) else "") &
                    Character'Val (9) & To_String (Result.Book));
               end if;
         end Emit_Result;
      begin
         for Source of Sources loop
            declare
               Path : constant String := To_String (Source);
            begin
               Outputs.Append (To_Unbounded_String (Epub.Files.Join
                 ((if Recursive then Epub.Files.Join (Epub.Files.Parent_Path (Path), "horizontal")
                   else To_String (Output_Directory)), Epub.Files.Basename (Path))));
            end;
         end loop;
         if Jobs /= 1 and then (Jobs > 1 or else not Sources.Is_Empty) then
            Topology := Epub.CPUs.Discover;
            if Jobs > Natural'Max (1, Topology.Cores.Last_Index) then
               raise Constraint_Error with "--jobs exceeds the available physical performance cores";
            end if;
            for Index in 1 .. (if Jobs = 0 then Topology.Cores.Last_Index else Jobs) loop
               Selected.Append (Topology.Cores (Index));
            end loop;
            if Verbose then
               Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                 "Eligible physical core workers:" & Natural'Max (1, Selected.Last_Index)'Image);
               if not Topology.Classes_Known then
                  Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                    "Core classes unavailable; using identifiable OS-visible physical cores.");
               end if;
            end if;
         end if;
         Epub.Archives.Concurrent.Process
           (Sources, Outputs, Settings, Selected, Automatic => Jobs = 0,
            Results => Results, Observer => Emit_Result'Access);
      end;
      declare
         Report : constant String := Epub.Reports.JSON (Results);
      begin
         if Length (Report_Path) /= 0 and then not Settings.Dry_Run then
            Epub.Reports.Write_Report (To_String (Report_Path), Report);
         end if;
         if JSON_Output then
            Ada.Text_IO.Put (Report);
         end if;
      end;
      Epub.Performance.Dump;
      if Failures /= 0 then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
           Ada.Strings.Fixed.Trim (Failures'Image, Ada.Strings.Both) &
           " EPUB(s) failed; other books were processed independently.");
         return 1;
      end if;
      return 0;
   end Run;
end Epub.CLI;

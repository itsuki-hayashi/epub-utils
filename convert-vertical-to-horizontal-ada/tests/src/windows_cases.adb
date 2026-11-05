with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with AUnit.Assertions;
with Epub.Conversion;
with Epub.Files;
with Epub.Resources;
with Epub.XML;
with Epub.Markup;
with GNAT.SHA256;
with Epub.CPUs;
with Epub.Workers;
with Epub.Archives.Concurrent;
with Interfaces.C;

package body Windows_Cases is
   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Epub.Conversion.Processing_Status;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Windows: " & Item.Kind'Image));

   function Fresh_Directory (Kind : Case_Kind) return String is
      Image : constant String := Ada.Calendar.Formatting.Image (Ada.Calendar.Clock, Include_Time_Fraction => True);
      Root : Unbounded_String := To_Unbounded_String
        (Epub.Files.Absolute_Path ("../test-results/windows-" & Kind'Image & "-"));
   begin
      for Value of Image loop
         if Value in '0' .. '9' then
            Append (Root, Value);
         end if;
      end loop;
      Epub.Files.Ensure_Directory (To_String (Root));
      return To_String (Root);
   end Fresh_Directory;

   procedure Check_CPU_APIs is
      procedure Mock (Flags : Interfaces.C.unsigned)
        with Import, Convention => C, External_Name => "epub_test_cpu_apis";
      Original : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Pool : Epub.Workers.Pool;
      Rejected : Boolean;
   begin
      Mock (1);
      declare
         Fallback : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      begin
         Assert (not Fallback.Classes_Known and then not Fallback.Cores.Is_Empty,
                 "Missing CPU-set API uses physical processor relationships without inventing core classes");
      end;
      Mock (3);
      Assert (Epub.CPUs.Discover.Cores.Is_Empty, "Unavailable native topology returns the sequential fallback");
      if not Original.Cores.Is_Empty then
         Cores.Append (Original.Cores (1));
         for Mode in 1 .. 3 loop
            Mock (case Mode is when 1 => 4, when 2 => 8, when others => 16);
            Rejected := False;
            begin Pool.Start (Cores);
            exception when Epub.Workers.Worker_Error => Rejected := True; end;
            Assert (Rejected and then Pool.Snapshot.Submitted = 0,
                    "Native affinity rejection and incorrect readback fail before any conversion job");
         end loop;
      end if;
      Mock (0);
   exception when others => Mock (0); raise;
   end Check_CPU_APIs;

   procedure Check_Rolling_Queue (Root : String) is
      function Begin_Rolling return Interfaces.C.int
        with Import, Convention => C, External_Name => "epub_test_begin_rolling";
      function End_Rolling return Interfaces.C.int
        with Import, Convention => C, External_Name => "epub_test_end_rolling";
      use type Interfaces.C.int;
      Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Sources, Outputs : Epub.Resources.String_Lists.Vector;
      Results : Epub.Conversion.Result_Lists.Vector;
      Original : constant String := Epub.Files.Read
        ("../../convert-vertical-to-horizontal-perl/t/fixtures/input/vertical CSS variants.epub");
      Seen : Natural := 0;
      procedure Observe (Ordinal : Positive; Result : Epub.Conversion.Book_Result) is
      begin
         if Seen = 0 then
            Assert (Ordinal = 2 and then Result.Status = Epub.Conversion.Converted,
                    "The completed second book reports while the first book is still blocked");
         end if;
         Seen := Seen + 1;
      end Observe;
   begin
      if Topology.Cores.Last_Index < 2 then return; end if;
      Cores.Append (Topology.Cores (1)); Cores.Append (Topology.Cores (2));
      Sources.Append (To_Unbounded_String (Epub.Files.Join (Root, "rolling-first.epub")));
      Sources.Append (To_Unbounded_String (Epub.Files.Join (Root, "rolling-second.epub")));
      Sources.Append (To_Unbounded_String (Epub.Files.Join (Root, "rolling-third.epub")));
      for Index in 1 .. Sources.Last_Index loop
         Epub.Files.Write_Exclusive (To_String (Sources (Index)), (if Index = 3 then "invalid archive" else Original));
         Outputs.Append (To_Unbounded_String (Epub.Files.Join (Root, "output" & Index'Image & ".epub")));
      end loop;
      Assert (Begin_Rolling = 1, "Create the deterministic queue gate");
      Epub.Archives.Concurrent.Process (Sources, Outputs, (others => False), Cores, False, Results, Observe'Access);
      Assert (End_Rolling = 1,
              "A reused worker starts the third queued book before the blocked first book can finish");
      Assert (Seen = 3 and then Results.Last_Index = 3, "Every queued book completes independently");
   exception
      when others =>
         declare
            Ignored : constant Interfaces.C.int := End_Rolling;
            pragma Unreferenced (Ignored);
         begin null; end;
         raise;
   end Check_Rolling_Queue;

   procedure Check_XML_Allocation_Recovery is
      procedure Arm (Skip : Interfaces.C.unsigned)
        with Import, Convention => C, External_Name => "epub_test_heap_failure";
      procedure Clear
        with Import, Convention => C, External_Name => "epub_test_heap_clear";
      Document : constant String :=
        "<html xmlns='urn:test'><body><p class='vertical' id='sentinel'>visible</p></body></html>";
      Failures : Natural := 0;
      procedure Inspect is
         Summary : constant Epub.XML.Summary := Epub.XML.Inspect_Content (Document);
      begin
         Assert (Epub.XML.Has_Visible_Text (Summary), "Successful parse after allocation failure");
      end Inspect;
   begin
      Inspect;
      for Skip in 0 .. 63 loop
         Arm (Interfaces.C.unsigned (Skip));
         begin
            declare
               Summary : constant Epub.XML.Summary := Epub.XML.Inspect_Content (Document);
            begin
               Clear;
               Assert (Epub.XML.Has_Visible_Text (Summary), "Parse with a later failure point");
            end;
         exception
            when Storage_Error => Failures := Failures + 1;
         end;
         Clear;
         Inspect;
      end loop;
      for Skip in 0 .. 15 loop
         Arm (Interfaces.C.unsigned (Skip));
         begin
            declare
               Text : constant String := Epub.Markup.Convert
                 ("<p STYLE='writing-mode:vertical-rl' data-x='x'>visible</p>");
            begin
               Clear;
               Assert (Ada.Strings.Fixed.Index (Text, "horizontal-tb") > 0, "Source spans survive a later failure point");
            end;
         exception when Storage_Error => Failures := Failures + 1; end;
         Clear;
         Inspect;
      end loop;
      Assert (Failures > 0, "Inject actual XML allocation failures");
   exception
      when others => Clear; raise;
   end Check_XML_Allocation_Recovery;

   overriding procedure Run_Test (Item : in out Unit_Case) is
      Root : constant String := Fresh_Directory (Item.Kind);
   begin
      case Item.Kind is
         when CPU_API_Fallbacks => Check_CPU_APIs;
         when Rolling_Book_Queue => Check_Rolling_Queue (Root);
         when XML_Allocation_Recovery => Check_XML_Allocation_Recovery;
         when Long_Unicode_Paths =>
            declare
               Directory : Unbounded_String := To_Unbounded_String (Root);
               Japanese : constant String := Character'Val (16#E6#) & Character'Val (16#97#) &
                 Character'Val (16#A5#) & Character'Val (16#F0#) & Character'Val (16#9F#) &
                 Character'Val (16#93#) & Character'Val (16#9A#);
               Segment : constant String (1 .. 40) := [others => 'x'];
               Source : constant String := Epub.Files.Read
                 ("../../convert-vertical-to-horizontal-perl/t/fixtures/input/vertical CSS variants.epub");
            begin
               for Level in 1 .. 7 loop
                  Directory := To_Unbounded_String (Epub.Files.Join
                    (To_String (Directory), "segment" & Level'Image & Segment));
               end loop;
               Epub.Files.Ensure_Directory (To_String (Directory));
               declare
                  Input : constant String := Epub.Files.Join (To_String (Directory), Japanese & " [literal].epub");
                  Output : constant String := Epub.Files.Join (To_String (Directory), Japanese & " [output].epub");
                  Outcome : Epub.Conversion.Book_Result;
               begin
                  Epub.Files.Write_Exclusive (Input, Source);
                  Outcome := Epub.Conversion.Process_Book (Input, Output, (others => False));
                  Assert (Outcome.Status = Epub.Conversion.Converted, "Long Unicode conversion: " & To_String (Outcome.Error));
                  Assert (GNAT.SHA256.Digest (Epub.Files.Read (Input)) = GNAT.SHA256.Digest (Source), "Source remains unchanged");
                  Assert (Epub.Files.Exists (Output), "Unicode output published");
                  Assert (Epub.Files.EPUB_Files (To_String (Directory), False).Last_Index = 2, "Wide directory enumeration");
               end;
            end;
         when Publication_Collision =>
            declare
               Destination : constant String := Epub.Files.Join (Root, "existing.epub");
               Temporary : constant String := Epub.Files.Join (Root, "temporary.tmp");
               Rejected : Boolean := False;
            begin
               Epub.Files.Write_Exclusive (Destination, "original");
               Epub.Files.Write_Exclusive (Temporary, "replacement");
               begin
                  Epub.Files.Publish (Temporary, Destination);
               exception
                  when Epub.Files.File_Error => Rejected := True;
               end;
               Assert (Rejected, "Publication refuses existing destination");
               Assert (Epub.Files.Read (Destination) = "original", "Destination untouched");
               Assert (Epub.Files.Read (Temporary) = "replacement", "Refused source remains owned");
            end;
         when Verification_Cleanup =>
            declare
               Destination : constant String := Epub.Files.Join (Root, "output.epub");
               procedure Reject (Bytes : String) is
               begin
                  Assert (Bytes = "payload", "Verifier sees persisted bytes");
                  raise Constraint_Error with "Injected verification failure";
               end Reject;
               procedure Save is new Epub.Files.Write_Checked (Reject);
               Rejected : Boolean := False;
               Search : Ada.Directories.Search_Type;
               Any_Temporary : Boolean;
            begin
               begin
                  Save (Destination, "payload");
               exception
                  when Constraint_Error => Rejected := True;
               end;
               Assert (Rejected, "Verification failure propagates");
               Assert (not Epub.Files.Exists (Destination), "Failed output is not published");
               Ada.Directories.Start_Search (Search, Root, ".epub-horizontal-*.tmp");
               Any_Temporary := Ada.Directories.More_Entries (Search);
               Ada.Directories.End_Search (Search);
               Assert (not Any_Temporary, "Failed temporary output removed");
            end;
         when Recursive_Enumeration =>
            declare
               Child : constant String := Epub.Files.Join (Root, "author");
               Ignored : constant String := Epub.Files.Join (Root, "HoRiZoNtAl");
               Found : Epub.Resources.String_Lists.Vector;
            begin
               Epub.Files.Ensure_Directory (Child);
               Epub.Files.Ensure_Directory (Ignored);
               Epub.Files.Write_Exclusive (Epub.Files.Join (Root, "root.epub"), "x");
               Epub.Files.Write_Exclusive (Epub.Files.Join (Child, "child.EPUB"), "x");
               Epub.Files.Write_Exclusive (Epub.Files.Join (Ignored, "generated.epub"), "x");
               Found := Epub.Files.EPUB_Files (Root, True);
               Assert (Found.Last_Index = 2, "Recursive scan skips mixed-case output directory");
               Assert (Epub.Resources.Contains (Found, Epub.Files.Join (Child, "child.EPUB")), "Case-insensitive extension");
            end;
      end case;
   end Run_Test;
end Windows_Cases;

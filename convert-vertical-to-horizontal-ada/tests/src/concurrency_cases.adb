with Ada.Streams;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with Epub.CPUs;
with Epub.Archive_Sources;
with Epub.File_Streams;
with Epub.Files;
with Epub.Temporary_Files;
with Epub.Workers;
with Epub.Destinations;
with Epub.Resources;
with GNAT.OS_Lib;
with Zip_Streams;
with Epub.Archives.Concurrent;
with Epub.Conversion;
with Test_Files;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;

package body Concurrency_Cases is
   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Zip_Streams.ZS_Size_Type;
   use type Epub.Workers.Job_Access;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Concurrency: " & Item.Kind'Image));

   protected Job_Status is
      procedure Reset (Expected : Positive);
      procedure Begin_Job;
      entry First_Jobs;
      procedure Finish_Job (Error : Boolean);
      function Completed return Natural;
      function Failures return Natural;
      function Peak return Natural;
   private
      Count, Errors, Active, Maximum, Started : Natural := 0;
      Wanted : Positive := 1;
   end Job_Status;
   protected body Job_Status is
      procedure Reset (Expected : Positive) is
      begin
         Count := 0; Errors := 0; Active := 0; Maximum := 0; Started := 0; Wanted := Expected;
      end Reset;
      procedure Begin_Job is
      begin
         Active := Active + 1;
         Started := Started + 1;
         Maximum := Natural'Max (Maximum, Active);
      end Begin_Job;
      entry First_Jobs when Started >= Wanted is begin null; end First_Jobs;
      procedure Finish_Job (Error : Boolean) is
      begin
         Active := Active - 1;
         Count := Count + 1;
         if Error then Errors := Errors + 1; end if;
      end Finish_Job;
      function Completed return Natural is (Count);
      function Failures return Natural is (Errors);
      function Peak return Natural is (Maximum);
   end Job_Status;
   type Pool_Pointer is access all Epub.Workers.Pool;
   type Test_Job is new Epub.Workers.Job with record
      Owner : Pool_Pointer;
      Step : Natural := 0;
   end record;
   overriding procedure Execute (Item : in out Test_Job);
   overriding procedure Failed (Item : in out Test_Job; Message : String);
   procedure Advance (Item : Test_Job) is
   begin
      if Item.Step < 31 then
         declare
            Work : Epub.Workers.Job_Access := new Test_Job'
              (Epub.Workers.Job with Owner => Item.Owner, Step => Item.Step + 1);
            Accepted : Boolean;
         begin
            Item.Owner.all.Submit (Work, Accepted);
            if not Accepted then
               Epub.Workers.Destroy (Work);
               raise Program_Error with "Continuation queue unexpectedly full";
            end if;
         end;
      end if;
   end Advance;
   overriding procedure Execute (Item : in out Test_Job) is
   begin
      Job_Status.Begin_Job;
      if Item.Step = 0 then Job_Status.First_Jobs; end if;
      if Item.Step in 11 | 22 then
         raise Constraint_Error with "Injected job failure";
      end if;
      Job_Status.Finish_Job (False);
      Advance (Item);
   end Execute;
   overriding procedure Failed (Item : in out Test_Job; Message : String) is
   begin
      Assert (Message = "Injected job failure", "Worker forwards the original job exception");
      Job_Status.Finish_Job (True);
      Advance (Item);
   end Failed;

   procedure Check_Workers is
      Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Pool : aliased Epub.Workers.Pool;
   begin
      if Topology.Cores.Is_Empty then return; end if;
      for Index in 1 .. Natural'Min (2, Topology.Cores.Last_Index) loop
         Cores.Append (Topology.Cores (Index));
      end loop;
      Job_Status.Reset (Cores.Last_Index);
      Pool.Start (Cores);
      for Index in 1 .. Cores.Last_Index loop
         declare
            Work : Epub.Workers.Job_Access := new Test_Job'
              (Epub.Workers.Job with Owner => Pool'Unchecked_Access, Step => 0);
            Accepted : Boolean;
         begin
            Pool.Submit (Work, Accepted);
            Assert (Accepted and then Work = null, "Fresh worker pool accepts and owns root jobs");
         end;
      end loop;
      Pool.Join;
      Assert (Job_Status.Completed = 32 * Cores.Last_Index and then
              Job_Status.Failures = 2 * Cores.Last_Index and then Job_Status.Peak = Cores.Last_Index,
              "Pinned workers execute continuations and recover from job failures");
      Assert (Pool.Snapshot.Completed = Job_Status.Completed and then
              Pool.Snapshot.Queue_High_Water <= 4 * Cores.Last_Index,
              "Pool accounting includes child jobs and bounded queue occupancy");
      declare
         Path : constant String := "concurrent-workers.csv";
         Had_Value : constant Boolean := Ada.Environment_Variables.Exists ("EPUB_CONCURRENCY_STATS");
         Previous : constant String := Ada.Environment_Variables.Value ("EPUB_CONCURRENCY_STATS", "");
         procedure Restore is
         begin
            if Had_Value then Ada.Environment_Variables.Set ("EPUB_CONCURRENCY_STATS", Previous);
            else Ada.Environment_Variables.Clear ("EPUB_CONCURRENCY_STATS"); end if;
         end Restore;
      begin
         Ada.Environment_Variables.Set ("EPUB_CONCURRENCY_STATS", Path);
         Pool.Write_Statistics (2 * Cores.Last_Index, Cores.Last_Index);
         Restore;
         declare
            Data : constant String := Epub.Files.Read (Path);
         begin
            Assert (Ada.Strings.Fixed.Index (Data, "submitted," & Natural'Image (32 * Cores.Last_Index)) /= 0
                    and then Ada.Strings.Fixed.Index (Data, "batch_high_water," & Natural'Image (2 * Cores.Last_Index)) /= 0
                    and then Ada.Strings.Fixed.Index (Data, "worker 1_logical," & Natural'Image (Cores (1).Logical)) /= 0,
                    "Persisted diagnostics match executed continuations, admission limits and selected cores");
         end;
         Epub.Files.Remove (Path);
      exception
         when others => Restore; Epub.Files.Remove (Path); raise;
      end;
      Pool.Stop;
   end Check_Workers;

   procedure Check_Topology is
      use Epub.CPUs;
      Raw : Processor_Lists.Vector;
   begin
      for Core in 0 .. 7 loop
         for Thread in 0 .. 1 loop
            Raw.Append ((0, 2 * Core + Thread, Core, 2, True, True, True));
         end loop;
      end loop;
      for Core in 8 .. 15 loop
         Raw.Append ((0, Core + 8, Core, 0, True, True, True));
      end loop;
      Raw.Append ((1, 0, 0, 2, True, True, True));
      declare
         Selected : constant Topology := Select_Cores (Raw);
      begin
         Assert (Selected.Cores.Last_Index = 9 and then Selected.Classes_Known,
                 "Select physical P cores across groups and exclude E cores and SMT siblings");
      end;
      for Index in 1 .. Raw.Last_Index loop
         declare
            CPU : Processor := Raw (Index);
         begin
            CPU.Allowed := CPU.Efficiency = 0;
            Raw.Replace_Element (Index, CPU);
         end;
      end loop;
      declare
         Selected : constant Topology := Select_Cores (Raw);
      begin
         Assert (Selected.Cores.Last_Index = 1 and then Selected.Restricted_Fallback,
                 "An E-only restriction cannot expand to inaccessible P cores");
      end;
      for Index in 1 .. Raw.Last_Index loop
         declare
            CPU : Processor := Raw (Index);
         begin
            CPU.Class_Known := False;
            Raw.Replace_Element (Index, CPU);
         end;
      end loop;
      Assert (Select_Cores (Raw).Cores.Last_Index = 8, "Unknown core classes use identifiable physical cores");
      declare
         Empty : Processor_Lists.Vector;
      begin
         Assert (Select_Cores (Empty).Cores.Is_Empty, "Unavailable topology cannot invent logical/2 cores");
      end;
   end Check_Topology;

   procedure Check_Destinations is
      Paths : Epub.Resources.String_Lists.Vector;
      Parent : constant String := Epub.Files.Current_Directory;
      use type Epub.Destinations.Collision_Scope;
   begin
      Paths.Append (To_Unbounded_String (Epub.Files.Join (Parent, "collision-a.epub")));
      Paths.Append (To_Unbounded_String (Epub.Files.Join (Parent, "collision-b.epub")));
      Paths.Append (Paths (1));
      declare
         Groups : constant Epub.Destinations.Group_Lists.Vector := Epub.Destinations.Groups (Paths);
         Key : constant Epub.Destinations.Key := Epub.Destinations.Describe (To_String (Paths (1)));
      begin
         Assert (Groups.Last_Index = 3 and then Groups (1) = Groups (3),
                 "Identical destinations have one ordered publication group");
         if Key.Scope = Epub.Destinations.Exact_Name then
            Assert (Groups (1) /= Groups (2), "Independent known filenames can publish as ready");
         end if;
      end;
      Paths.Append (To_Unbounded_String (Epub.Files.Join (Parent, "COLLISION-A.EPUB")));
      declare
         Groups : constant Epub.Destinations.Group_Lists.Vector := Epub.Destinations.Groups (Paths);
      begin
         if GNAT.OS_Lib.Directory_Separator = '\' then
            Assert (Groups (1) = Groups (4), "Windows case aliases preserve input-order precedence");
         end if;
      end;
      Paths.Append (To_Unbounded_String (Epub.Files.Join (Parent, "COLLIS~1.EPU")));
      declare
         Groups : constant Epub.Destinations.Group_Lists.Vector := Epub.Destinations.Groups (Paths);
      begin
         if GNAT.OS_Lib.Directory_Separator = '\' then
            Assert (Groups (1) = Groups (2) and then Groups (1) = Groups (5),
                    "Potential DOS aliases conservatively serialize their directory");
         end if;
      end;
   end Check_Destinations;

   procedure Check_Readers is
      Path : constant String := "concurrent-source.bin";
      Data : String (1 .. 262_144);
   begin
      Epub.Files.Remove (Path);
      for Index in Data'Range loop
         Data (Index) := Character'Val (Index mod 251);
      end loop;
      Epub.Files.Write_Exclusive (Path, Data);
      declare
         Source : aliased Epub.Archive_Sources.Reference := Epub.Archive_Sources.Open (Path);
         Empty : Epub.Archive_Sources.Reference;
         protected Status is
            procedure Started;
            entry All_Started;
            entry Start;
            procedure Release;
            procedure Failed;
            function Success return Boolean;
         private
            Ready : Natural := 0;
            Go, Error : Boolean := False;
         end Status;
         protected body Status is
            procedure Started is begin Ready := Ready + 1; end Started;
            entry All_Started when Ready = 8 is begin null; end All_Started;
            entry Start when Go is begin null; end Start;
            procedure Release is begin Go := True; end Release;
            procedure Failed is begin Error := True; end Failed;
            function Success return Boolean is (not Error);
         end Status;
         task type Worker (ID : Positive);
         task body Worker is
         begin
            declare
               Input : Epub.Archive_Sources.Reader := Epub.Archive_Sources.View
                 (Source, Zip_Streams.ZS_Index_Type (ID * 17), 100_001);
               Buffer : Ada.Streams.Stream_Element_Array (-3 .. 65_537);
               Last : Ada.Streams.Stream_Element_Offset;
            begin
               Status.Started;
               Status.Start;
               for Pass in 1 .. 4 loop
                  Input.Set_Index (1);
                  while not Input.End_Of_Stream loop
                     declare
                        First : constant Natural := ID * 17 + Natural (Input.Index) - 1;
                     begin
                        Input.Read (Buffer, Last);
                        for Index in Buffer'First .. Last loop
                           if Buffer (Index) /= Ada.Streams.Stream_Element
                             ((First + Natural (Index - Buffer'First)) mod 251)
                           then
                              Status.Failed;
                           end if;
                        end loop;
                     end;
                  end loop;
                  Assert (Input.Index = 100_002, "Reader has an independent bounded cursor");
               end loop;
               begin
                  Input.Set_Index (100_003);
                  Status.Failed;
               exception
                  when Epub.File_Streams.File_Error => null;
               end;
            end;
         exception
            when others => Status.Failed;
         end Worker;
      begin
         declare
            W1 : Worker (1); W2 : Worker (2); W3 : Worker (3); W4 : Worker (4);
            W5 : Worker (5); W6 : Worker (6); W7 : Worker (7); W8 : Worker (8);
         begin
            Status.All_Started;
            Source := Empty;
            Status.Release;
         end;
         Assert (Status.Success, "Concurrent readers survive release of the original reference");
      end;
      Epub.Files.Remove (Path);
   end Check_Readers;

   procedure Check_Temporaries is
      type Paths is array (Positive range 1 .. 64) of Unbounded_String;
      protected Status is
         procedure Add (Path : Unbounded_String);
         procedure Failed;
         function Success return Boolean;
      private
         Seen : Paths;
         Used : Natural := 0;
         Error : Boolean := False;
      end Status;
      protected body Status is
         procedure Add (Path : Unbounded_String) is
         begin
            for Index in 1 .. Used loop
               Error := Error or else Seen (Index) = Path;
            end loop;
            Used := Used + 1;
            Seen (Used) := Path;
         end Add;
         procedure Failed is begin Error := True; end Failed;
         function Success return Boolean is (not Error and then Used = 64);
      end Status;
      task type Worker;
      task body Worker is
      begin
         for Pass in 1 .. 8 loop
            declare
               Output : Epub.File_Streams.Stream;
               Path : Unbounded_String;
            begin
               Epub.Temporary_Files.Reserve (".", Output, Path);
               Status.Add (Path);
               Output.Write ([1, 2, 3]);
               Output.Close;
               if Epub.Files.Read (To_String (Path)) /= Character'Val (1) & Character'Val (2) & Character'Val (3) then
                  Status.Failed;
               end if;
               Epub.Files.Remove (To_String (Path));
            end;
         end loop;
      exception
         when others => Status.Failed;
      end Worker;
   begin
      declare
         Workers : array (1 .. 8) of Worker;
      begin
         null;
      end;
      Assert (Status.Success, "Concurrent exclusive reservations never share a temporary name");
   end Check_Temporaries;

   procedure Check_Archives (Failure_Test : Boolean) is
      Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Sources, Outputs : Epub.Resources.String_Lists.Vector;
      Results : Epub.Conversion.Result_Lists.Vector;
      Seen : Natural := 0;
      Settings : constant Epub.Conversion.Options := (others => <>);
      use type Epub.Conversion.Processing_Status;
      procedure Observe (Ordinal : Positive; Result : Epub.Conversion.Book_Result) is
      begin
         Seen := Seen + 1;
         Assert (Ordinal = Seen, "Coordinator reports in input order despite completion order");
         Assert (Length (Result.Book) > 0, "Completed report retains source identity");
      end Observe;
      procedure Clean is
      begin
         Epub.Files.Remove ("concurrent-book.epub");
         Epub.Files.Remove ("concurrent-invalid.epub");
         Epub.Files.Remove ("concurrent-serial.epub");
         Epub.Files.Remove ("concurrent-first.epub");
         Epub.Files.Remove ("concurrent-second.epub");
      end Clean;
   begin
      if Topology.Cores.Last_Index < 2 then return; end if;
      Cores.Append (Topology.Cores (1)); Cores.Append (Topology.Cores (2));
      Clean;
      declare
         Items : Epub.Archives.Catalogue := Epub.Archives.Read (Test_Files.Read
           ("../../convert-vertical-to-horizontal-perl/t/fixtures/input/vertical CSS variants.epub"));
         Large : constant String (1 .. 300_000) := [others => 'x'];
      begin
         for Index in 1 .. 96 loop
            Items.Append (Epub.Archives.Create_Member ("assets/tiny" & Index'Image, "abc" & Index'Image));
         end loop;
         Items.Append (Epub.Archives.Create_Member ("assets/A.bin", Large));
         Items.Append (Epub.Archives.Create_Member ("assets/a.bin", Large));
         Epub.Files.Write_Exclusive ("concurrent-book.epub", Epub.Archives.Rebuild (Items));
      end;
      if Failure_Test then
         Epub.Files.Write_Exclusive ("concurrent-invalid.epub", "invalid archive");
         Sources.Append (To_Unbounded_String ("concurrent-invalid.epub"));
         Outputs.Append (To_Unbounded_String ("concurrent-first.epub"));
      else
         declare
            Serial : constant Epub.Conversion.Book_Result := Epub.Conversion.Process_Book
              ("concurrent-book.epub", "concurrent-serial.epub", Settings);
         begin
            Assert (Serial.Status = Epub.Conversion.Converted, "Synthetic many-entry book converts sequentially");
         end;
         Sources.Append (To_Unbounded_String ("concurrent-book.epub"));
         Outputs.Append (To_Unbounded_String ("concurrent-first.epub"));
      end if;
      Sources.Append (To_Unbounded_String ("concurrent-book.epub"));
      Outputs.Append (To_Unbounded_String ("concurrent-second.epub"));
      Sources.Append (To_Unbounded_String ("concurrent-book.epub"));
      Outputs.Append (To_Unbounded_String ("concurrent-first.epub"));
      Epub.Archives.Concurrent.Process (Sources, Outputs, Settings, Cores, False, Results, Observe'Access);
      Assert (Seen = 3 and then Results.Last_Index = 3, "Every input yields exactly one ordered result");
      Assert (Results (2).Status = Epub.Conversion.Converted, "Independent book succeeds alongside collision or error");
      if Failure_Test then
         Assert (Results (1).Status = Epub.Conversion.Failed and then Results (3).Status = Epub.Conversion.Converted,
                 "A failed predecessor releases its destination without cancelling other books");
      else
         Assert (Results (1).Status = Epub.Conversion.Converted and then Results (3).Status = Epub.Conversion.Failed,
                 "Input precedence chooses the first successful publisher for a colliding destination");
         Assert (Epub.Files.Read ("concurrent-serial.epub") = Epub.Files.Read ("concurrent-first.epub"),
                 "Parallel batches preserve exact archive bytes, metadata and compression decisions");
      end if;
      Assert (Epub.Files.Read ("concurrent-first.epub") = Epub.Files.Read ("concurrent-second.epub"),
              "Independent and collision-serialized books have identical output");
      Clean;
   exception
      when others => Clean; raise;
   end Check_Archives;

   procedure Check_Affinity_Failure is
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Pool : Epub.Workers.Pool;
      Rejected : Boolean := False;
   begin
      Cores.Append ((Natural'Last, Natural'Last, 0, 0, True, True, False));
      begin Pool.Start (Cores);
      exception when Epub.Workers.Worker_Error => Rejected := True; end;
      Assert (Rejected and then Pool.Snapshot.Submitted = 0,
              "Affinity startup failure is reported before conversion work is admitted");
      Pool.Stop;
      Assert (Pool.Snapshot.Completed = 0, "Failed startup leaves no active pool");
   end Check_Affinity_Failure;

   protected Reverse_Gate is
      procedure Reset;
      entry Second_Finished;
      procedure Finish (Number : Positive);
      function Correct return Boolean;
   private
      Count, First : Natural := 0;
   end Reverse_Gate;
   protected body Reverse_Gate is
      procedure Reset is begin Count := 0; First := 0; end Reset;
      entry Second_Finished when Count > 0 is begin null; end Second_Finished;
      procedure Finish (Number : Positive) is
      begin
         if Count = 0 then First := Number; end if;
         Count := Count + 1;
      end Finish;
      function Correct return Boolean is (Count = 2 and then First = 2);
   end Reverse_Gate;
   type Reverse_Job is new Epub.Workers.Job with record Number : Positive; end record;
   overriding procedure Execute (Item : in out Reverse_Job);
   overriding procedure Failed (Item : in out Reverse_Job; Message : String);
   overriding procedure Completed (Item : in out Reverse_Job);
   overriding procedure Execute (Item : in out Reverse_Job) is
   begin
      --  A test-only barrier forces the first submitted result to arrive last.
      if Item.Number = 1 then Reverse_Gate.Second_Finished; end if;
   end Execute;
   overriding procedure Failed (Item : in out Reverse_Job; Message : String) is
      pragma Unreferenced (Item);
   begin
      raise Program_Error with Message;
   end Failed;
   overriding procedure Completed (Item : in out Reverse_Job) is
   begin
      Reverse_Gate.Finish (Item.Number);
   end Completed;
   procedure Check_Reversed is
      Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Pool : Epub.Workers.Pool;
   begin
      if Topology.Cores.Last_Index < 2 then return; end if;
      Cores.Append (Topology.Cores (1)); Cores.Append (Topology.Cores (2));
      Reverse_Gate.Reset;
      Pool.Start (Cores);
      for Index in 1 .. 2 loop
         declare
            Work : Epub.Workers.Job_Access := new Reverse_Job'(Epub.Workers.Job with Number => Index);
            Accepted : Boolean;
         begin
            Pool.Submit (Work, Accepted);
            Assert (Accepted and then Work = null, "Both reversed-order jobs are owned by the pool");
         end;
      end loop;
      Pool.Join;
      Assert (Reverse_Gate.Correct, "Continuation delivery supports deterministically reversed completion");
   end Check_Reversed;

   procedure Check_Startup_Fallback is
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Sources, Outputs, Empty : Epub.Resources.String_Lists.Vector;
      Results : Epub.Conversion.Result_Lists.Vector;
      Settings : constant Epub.Conversion.Options := (others => <>);
      Rejected : Boolean := False;
      use type Epub.Conversion.Processing_Status;
      procedure Clean is
      begin
         Epub.Files.Remove ("concurrent-start-source.epub");
         Epub.Files.Remove ("concurrent-start-first.epub");
         Epub.Files.Remove ("concurrent-start-second.epub");
      end Clean;
   begin
      Clean;
      Cores.Append ((Natural'Last, Natural'Last, 0, 0, True, True, False));
      Cores.Append (Cores (1));
      Epub.Archives.Concurrent.Process (Empty, Empty, Settings, Cores, True, Results);
      Assert (Results.Is_Empty, "Empty input does not create workers");
      Epub.Files.Write_Exclusive ("concurrent-start-source.epub", Test_Files.Read
        ("../../convert-vertical-to-horizontal-perl/t/fixtures/input/vertical CSS variants.epub"));
      Sources.Append (To_Unbounded_String ("concurrent-start-source.epub"));
      begin
         Epub.Archives.Concurrent.Process (Sources, Empty, Settings, Cores, True, Results);
      exception when Constraint_Error => Rejected := True; end;
      Assert (Rejected, "Every input must have a destination before worker startup");
      Sources.Append (Sources (1));
      Outputs.Append (To_Unbounded_String ("concurrent-start-first.epub"));
      Outputs.Append (To_Unbounded_String ("concurrent-start-second.epub"));
      Rejected := False;
      begin
         Epub.Archives.Concurrent.Process (Sources, Outputs, Settings, Cores, False, Results);
      exception when Epub.Workers.Worker_Error => Rejected := True; end;
      Assert (Rejected and then not Epub.Files.Exists (To_String (Outputs (1))) and then
              not Epub.Files.Exists (To_String (Outputs (2))), "Explicit startup failure cannot publish any book");
      Epub.Archives.Concurrent.Process (Sources, Outputs, Settings, Cores, True, Results);
      Assert (Results.Last_Index = 2 and then Results (1).Status = Epub.Conversion.Converted and then
              Results (2).Status = Epub.Conversion.Converted, "Automatic startup failure falls back to the sequential converter");
      Assert (Epub.Files.Read (To_String (Outputs (1))) = Epub.Files.Read (To_String (Outputs (2))),
              "Startup fallback keeps exact archive output");
      Clean;
   exception when others => Clean; raise;
   end Check_Startup_Fallback;

   procedure Check_Failure_Precedence is
      Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Sources, Outputs : Epub.Resources.String_Lists.Vector;
      Results : Epub.Conversion.Result_Lists.Vector;
      Settings : constant Epub.Conversion.Options := (others => <>);
      function Header (Bytes : String; Central : Boolean; Ordinal : Positive) return Positive is
         Signature : constant String := "PK" & (if Central then Character'Val (1) & Character'Val (2)
                                                else Character'Val (3) & Character'Val (4));
         Position : Natural := 0;
      begin
         for Index in 1 .. Ordinal loop
            Position := Ada.Strings.Fixed.Index (Bytes, Signature, Position + 1);
            Assert (Position /= 0, "Generated test archive contains the expected ZIP header");
         end loop;
         return Position;
      end Header;
      procedure Break_CRC (Bytes : in out String; Ordinal : Positive) is
         Local : constant Positive := Header (Bytes, False, Ordinal) + 14;
         Central : constant Positive := Header (Bytes, True, Ordinal) + 16;
      begin
         Assert (Bytes (Local .. Local + 3) = Bytes (Central .. Central + 3), "Local and central CRC mutations agree");
         Bytes (Local) := Character'Val ((Character'Pos (Bytes (Local)) + 1) mod 256);
         Bytes (Central) := Bytes (Local);
      end Break_CRC;
      procedure Clean is
      begin
         Epub.Files.Remove ("concurrent-error-source.epub");
         Epub.Files.Remove ("concurrent-error-serial.epub");
         Epub.Files.Remove ("concurrent-error-parallel.epub");
      end Clean;
      use type Epub.Conversion.Processing_Status;
   begin
      if Topology.Cores.Last_Index < 2 then return; end if;
      Cores.Append (Topology.Cores (1)); Cores.Append (Topology.Cores (2));
      Sources.Append (To_Unbounded_String ("concurrent-error-source.epub"));
      Outputs.Append (To_Unbounded_String ("concurrent-error-parallel.epub"));
      declare
         Original : constant Epub.Archives.Catalogue := Epub.Archives.Read (Test_Files.Read
           ("../../convert-vertical-to-horizontal-perl/t/fixtures/input/vertical CSS variants.epub"));
         Items : Epub.Archives.Catalogue;
         Large : Unbounded_String;
         Chunk : constant String (1 .. 1024) := [others => 'x'];
      begin
         for Pass in 1 .. 8192 loop Append (Large, Chunk); end loop;
         for Index in 1 .. Original.Last_Index loop
            Items.Append (Original (Index));
            if Index = 4 then Items.Append (Epub.Archives.Create_Member ("assets/large.bin", To_String (Large))); end if;
         end loop;
         for Index in 1 .. 100 loop
            Items.Append (Epub.Archives.Create_Member ("assets/tiny" & Index'Image, "small"));
         end loop;
         declare
            Valid : constant String := Epub.Archives.Rebuild (Items);
         begin
            for Variant in 1 .. 3 loop
               Clean;
               declare
                  Bytes : String := Valid;
               begin
                  if Variant /= 3 then Break_CRC (Bytes, 5); end if;
                  if Variant = 1 then Break_CRC (Bytes, 80);
                  else
                     Bytes (Header (Bytes, False, 7) + 30) := 'Q';
                  end if;
                  Epub.Files.Write_Exclusive (To_String (Sources (1)), Bytes);
                  declare
                     Serial : constant Epub.Conversion.Book_Result := Epub.Conversion.Process_Book
                       (To_String (Sources (1)), "concurrent-error-serial.epub", Settings);
                  begin
                     Epub.Archives.Concurrent.Process (Sources, Outputs, Settings, Cores, False, Results);
                     Assert (Serial.Status = Epub.Conversion.Failed and then Results (1).Status = Serial.Status and then
                             Results (1).Error = Serial.Error and then Results (1).Input_Bytes = Serial.Input_Bytes,
                             "Earlier payload errors precede later payload or deferred local-header errors");
                  end;
                  Assert (Epub.Files.Read (To_String (Sources (1))) = Bytes, "Malformed source bytes are preserved");
                  Assert (not Epub.Files.Exists (To_String (Outputs (1))), "A failed validation cannot publish");
               end;
            end loop;
         end;
      end;
      Clean;
   exception when others => Clean; raise;
   end Check_Failure_Precedence;

   overriding procedure Run_Test (Item : in out Unit_Case) is
   begin
      case Item.Kind is
         when Topology_Selection => Check_Topology;
         when Native_Topology =>
            declare
               Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
            begin
               for CPU of Topology.Cores loop
                  Assert (CPU.Allowed, "Native topology respects allowed CPUs");
               end loop;
            end;
         when Shared_Source_Readers => Check_Readers;
         when Temporary_Reservations => Check_Temporaries;
         when Worker_Continuations => Check_Workers;
         when Destination_Groups => Check_Destinations;
         when Archive_Equivalence => Check_Archives (False);
         when Failure_Isolation => Check_Archives (True);
         when Affinity_Failure => Check_Affinity_Failure;
         when Reversed_Completion => Check_Reversed;
         when Startup_Fallback => Check_Startup_Fallback;
         when Failure_Precedence => Check_Failure_Precedence;
      end case;
   end Run_Test;
end Concurrency_Cases;

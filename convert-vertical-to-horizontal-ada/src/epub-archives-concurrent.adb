with Ada.Unchecked_Deallocation;
with Epub.Diagnostics;
with Epub.Files;
with Epub.Workers;

package body Epub.Archives.Concurrent is
   use Ada.Strings.Unbounded;
   type Reply is record
      Ordinal : Positive;
      Result : Epub.Conversion.Book_Result;
      Warnings : Unbounded_String;
   end record;
   type Reply_Access is access Reply;
   type Reply_Array is array (Positive range <>) of Reply_Access;
   type Reply_Array_Access is access Reply_Array;
   procedure Free_Reply is new Ada.Unchecked_Deallocation (Reply, Reply_Access);
   procedure Free_Replies is new Ada.Unchecked_Deallocation (Reply_Array, Reply_Array_Access);

   protected type Completions is
      procedure Initialize (Storage : Reply_Array_Access);
      procedure Post (Value : Reply_Access; Accepted : out Boolean);
      entry Take (Value : out Reply_Access);
      procedure Try_Take (Value : out Reply_Access);
      function Broken return Boolean;
   private
      Values : Reply_Array_Access;
      Head, Tail : Positive := 1;
      Used : Natural := 0;
      Overflow : Boolean := False;
   end Completions;
   protected body Completions is
      procedure Initialize (Storage : Reply_Array_Access) is
      begin
         Values := Storage;
      end Initialize;
      procedure Post (Value : Reply_Access; Accepted : out Boolean) is
      begin
         Accepted := Used < Values.all'Length;
         if Accepted then
            Values.all (Tail) := Value;
            Tail := Tail mod Values.all'Length + 1;
            Used := Used + 1;
         else
            Overflow := True;
         end if;
      end Post;
      entry Take (Value : out Reply_Access) when Used > 0 or Overflow is
      begin
         Try_Take (Value);
      end Take;
      procedure Try_Take (Value : out Reply_Access) is
      begin
         Value := null;
         if Used > 0 then
            Value := Values.all (Head);
            Values.all (Head) := null;
            Head := Head mod Values.all'Length + 1;
            Used := Used - 1;
         end if;
      end Try_Take;
      function Broken return Boolean is (Overflow);
   end Completions;

   protected type Activity is
      procedure Begin_Book;
      procedure End_Book;
      function Peak return Natural;
   private
      Active, Maximum : Natural := 0;
   end Activity;
   protected body Activity is
      procedure Begin_Book is
      begin
         Active := Active + 1;
         Maximum := Natural'Max (Maximum, Active);
      end Begin_Book;
      procedure End_Book is
      begin
         pragma Assert (Active > 0);
         Active := Active - 1;
      end End_Book;
      function Peak return Natural is (Maximum);
   end Activity;

   type Run_State is limited record
      Mail : Completions;
      Books : Activity;
   end record;
   type Run_Access is access all Run_State;
   type Book_Job is new Epub.Workers.Job with record
      Owner : Run_Access;
      Input, Destination : Unbounded_String;
      Settings : Epub.Conversion.Options;
      Value : Reply_Access;
      Started : Boolean := False;
   end record;
   overriding procedure Execute (Item : in out Book_Job);
   overriding procedure Failed (Item : in out Book_Job; Message : String);
   overriding procedure Completed (Item : in out Book_Job);
   overriding procedure Discard (Item : in out Book_Job);
   Current_Reply : Reply_Access := null;
   pragma Thread_Local_Storage (Current_Reply);

   procedure Capture_Warning (Message : String) is
   begin
      if Current_Reply /= null then
         Append (Current_Reply.all.Warnings, Message & Character'Val (10));
      end if;
   end Capture_Warning;
   overriding procedure Execute (Item : in out Book_Job) is
   begin
      Item.Owner.all.Books.Begin_Book;
      Item.Started := True;
      Current_Reply := Item.Value;
      Epub.Diagnostics.Capture (Capture_Warning'Access);
      Item.Value.all.Result := Epub.Conversion.Process_Book
        (To_String (Item.Input), To_String (Item.Destination), Item.Settings);
   end Execute;
   overriding procedure Failed (Item : in out Book_Job; Message : String) is
   begin
      Item.Value.all.Result.Status := Epub.Conversion.Failed;
      Item.Value.all.Result.Error := To_Unbounded_String (Message);
   end Failed;
   overriding procedure Completed (Item : in out Book_Job) is
      Accepted : Boolean;
      Value : Reply_Access := Item.Value;
   begin
      Epub.Diagnostics.Capture (null);
      Current_Reply := null;
      if Item.Started then
         Item.Owner.all.Books.End_Book;
         Item.Started := False;
      end if;
      Item.Value := null;
      Item.Owner.all.Mail.Post (Value, Accepted);
      if not Accepted then
         Free_Reply (Value);
         raise Epub.Workers.Worker_Error with "Book completion queue overflow";
      end if;
   end Completed;
   overriding procedure Discard (Item : in out Book_Job) is
   begin
      Free_Reply (Item.Value);
   end Discard;

   procedure Process
     (Sources, Outputs : Epub.Resources.String_Lists.Vector;
      Settings : Epub.Conversion.Options; Cores : Epub.CPUs.Processor_Lists.Vector;
      Automatic : Boolean; Results : out Epub.Conversion.Result_Lists.Vector;
      Observer : access procedure (Ordinal : Positive; Result : Epub.Conversion.Book_Result) := null) is
      Pool : Epub.Workers.Pool;
      State : aliased Run_State;
      Storage : Reply_Array_Access;
      type Job_Array is array (Positive range <>) of Epub.Workers.Job_Access;
      type Job_Array_Access is access Job_Array;
      procedure Free_Jobs is new Ada.Unchecked_Deallocation (Job_Array, Job_Array_Access);
      Jobs : Job_Array_Access;
      Value : Reply_Access := null;
      Empty : Epub.Conversion.Result_Lists.Vector;
      Finished : Natural := 0;
      procedure Serial is
      begin
         for Index in 1 .. Sources.Last_Index loop
            declare
               Result : constant Epub.Conversion.Book_Result := Epub.Conversion.Process_Book
                 (To_String (Sources (Index)), To_String (Outputs (Index)), Settings);
            begin
               Results.Append (Result);
               if Observer /= null then Observer.all (Index, Result); end if;
            end;
         end loop;
      end Serial;
      procedure Cleanup is
      begin
         Pool.Stop;
         Free_Reply (Value);
         if Jobs /= null then
            for Job of Jobs.all loop Epub.Workers.Destroy (Job); end loop;
            Free_Jobs (Jobs);
         end if;
         if Storage /= null then
            loop
               State.Mail.Try_Take (Value);
               exit when Value = null;
               Free_Reply (Value);
            end loop;
            Free_Replies (Storage);
         end if;
      end Cleanup;
   begin
      Results := Empty;
      if Sources.Last_Index /= Outputs.Last_Index then
         raise Constraint_Error with "Each source requires one destination";
      end if;
      if Sources.Is_Empty then return; end if;
      if Cores.Last_Index <= 1 then Serial; return; end if;

      --  All book metadata is ready before any worker can run a job. Only
      --  descriptors and completed reports scale with the number of inputs;
      --  at most one complete book is processed by each worker at a time.
      Storage := new Reply_Array'(1 .. Sources.Last_Index => null);
      State.Mail.Initialize (Storage);
      Jobs := new Job_Array'(1 .. Sources.Last_Index => null);
      for Index in Jobs.all'Range loop
         declare
            Input : constant Unbounded_String := Sources (Index);
            Destination : constant Unbounded_String := Outputs (Index);
            Data : Reply_Access := new Reply'(Ordinal => Index, others => <>);
         begin
            begin
               Data.all.Result.Book := To_Unbounded_String (Epub.Files.Basename (To_String (Input)));
               Data.all.Result.Output := Destination;
               Jobs.all (Index) := new Book_Job'
                 (Epub.Workers.Job with Owner => State'Unchecked_Access,
                  Input => Input, Destination => Destination, Settings => Settings,
                  Value => Data, Started => False);
            exception
               when others => Free_Reply (Data); raise;
            end;
         end;
      end loop;
      begin
         Pool.Start (Cores, Queue_Capacity => Sources.Last_Index);
      exception
         when Epub.Workers.Worker_Error | Epub.CPUs.Affinity_Error | Storage_Error | Tasking_Error =>
            Cleanup;
            if not Automatic then raise; end if;
            Epub.Diagnostics.Report ("Parallel workers unavailable; processing sequentially.");
            Serial;
            return;
      end;
      for Job of Jobs.all loop
         declare
            Accepted : Boolean;
         begin
            Pool.Submit (Job, Accepted);
            if not Accepted then raise Epub.Workers.Worker_Error with "Book queue rejected a prepared task"; end if;
         end;
      end loop;
      Pool.Finish_Submission;
      while Finished < Sources.Last_Index loop
         if Pool.Problem'Length > 0 or else State.Mail.Broken then
            raise Epub.Workers.Worker_Error with "Book worker failed: " & Pool.Problem;
         end if;
         select
            State.Mail.Take (Value);
         or
            delay 0.05;
         end select;
         if Value /= null then
            Results.Append (Value.all.Result);
            if Length (Value.all.Warnings) > 0 then
               Epub.Diagnostics.Report (To_String (Value.all.Warnings));
            end if;
            if Observer /= null then Observer.all (Value.all.Ordinal, Value.all.Result); end if;
            Free_Reply (Value);
            Finished := Finished + 1;
         end if;
      end loop;
      Pool.Join;
      Pool.Write_Statistics (0, State.Books.Peak);
      Cleanup;
   exception
      when others => Cleanup; raise;
   end Process;
end Epub.Archives.Concurrent;

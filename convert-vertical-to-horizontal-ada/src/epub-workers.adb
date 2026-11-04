with Ada.Exceptions;
with Ada.Unchecked_Deallocation;
with Epub.Performance;
with Ada.Environment_Variables;
with Ada.Text_IO;

package body Epub.Workers is
   use type Ada.Real_Time.Time;
   procedure Free_Job is new Ada.Unchecked_Deallocation (Job'Class, Job_Access);
   procedure Free_Worker is new Ada.Unchecked_Deallocation (Worker, Worker_Access);
   procedure Free_Array is new Ada.Unchecked_Deallocation (Worker_Array, Workers_Access);
   procedure Free_State is new Ada.Unchecked_Deallocation (State, State_Access);
   procedure Free_Jobs is new Ada.Unchecked_Deallocation (Job_Array, Job_Array_Access);
   procedure Free_Measurements is new Ada.Unchecked_Deallocation
     (Worker_Statistics_Array, Worker_Statistics_Access);
   procedure Destroy (Item : in out Job_Access) is
   begin
      if Item /= null then Discard (Item.all); end if;
      Free_Job (Item);
   end Destroy;
   function Exception_Text (Error : Ada.Exceptions.Exception_Occurrence) return String is
      Message : constant String := Ada.Exceptions.Exception_Message (Error);
   begin
      return (if Message'Length = 0 then Ada.Exceptions.Exception_Name (Error) else Message);
   end Exception_Text;
   protected body Queue is
      procedure Initialize (Storage : Job_Array_Access; Worker_Count : Positive) is
      begin
         Jobs := Storage;
         Capacity := Storage.all'Length;
         Expected := Worker_Count;
      end Initialize;
      procedure Save_Error (Message : String) is
      begin
         if Failure_Length = 0 then
            Failure_Length := Natural'Min (Failure'Length, Message'Length);
            Failure (1 .. Failure_Length) := Message (Message'First .. Message'First + Failure_Length - 1);
         end if;
      end Save_Error;
      procedure Add (Work : Job_Access; Accepted : out Boolean) is
      begin
         Accepted := not Closing and then Count < Capacity;
         if Accepted then
            Jobs.all (Tail) := Work;
            Tail := Tail mod Capacity + 1;
            Count := Count + 1;
            Totals.Submitted := Totals.Submitted + 1;
            Totals.Queue_High_Water := Natural'Max (Totals.Queue_High_Water, Count);
         end if;
      end Add;
      entry Take (Work : out Job_Access) when Count > 0 or Closing is
      begin
         if Count = 0 then
            Work := null;
         else
            Work := Jobs.all (Head);
            Jobs.all (Head) := null;
            Head := Head mod Capacity + 1;
            Count := Count - 1;
            Active := Active + 1;
         end if;
      end Take;
      procedure Complete is
      begin
         pragma Assert (Active > 0);
         Active := Active - 1;
         Totals.Completed := Totals.Completed + 1;
      end Complete;
      procedure Discard_Next (Work : out Job_Access) is
      begin
         Work := null;
         if Count > 0 then
            Work := Jobs.all (Head);
            Jobs.all (Head) := null;
            Head := Head mod Capacity + 1;
            Count := Count - 1;
         end if;
      end Discard_Next;
      procedure Started (Message : String) is
      begin
         Save_Error (Message);
         Ready := Ready + 1;
      end Started;
      entry Wait_Started when Ready = Expected is begin null; end Wait_Started;
      entry Wait_Idle when Count = 0 and Active = 0 is begin null; end Wait_Idle;
      procedure Close is begin Closing := True; end Close;
      procedure Fatal (Message : String) is
      begin
         Save_Error (Message);
      end Fatal;
      function Error return String is (Failure (1 .. Failure_Length));
      function Snapshot return Statistics is (Totals);
   end Queue;
   task body Worker is
      Work : Job_Access;
      Bound : Boolean := True;
      Beginning : Ada.Real_Time.Time;
   begin
      begin
         Epub.CPUs.Pin_Current (Shared.all.Cores (Number));
      exception
         when Error : others =>
            Shared.all.Jobs.Started (Exception_Text (Error));
            Bound := False;
      end;
      if Bound then
         Shared.all.Jobs.Started ("");
         loop
         Shared.all.Jobs.Take (Work);
         exit when Work = null;
         Beginning := Ada.Real_Time.Clock;
         begin
            Execute (Work.all);
         exception
            when Error : others =>
               begin
                  Failed (Work.all, Exception_Text (Error));
               exception
                  when Callback_Error : others =>
                     Shared.all.Jobs.Fatal (Exception_Text (Callback_Error));
               end;
         end;
         begin
            Completed (Work.all);
         exception
            when Error : others => Shared.all.Jobs.Fatal (Exception_Text (Error));
         end;
         begin
            Destroy (Work);
         exception
            when Error : others => Shared.all.Jobs.Fatal (Exception_Text (Error));
         end;
         Shared.all.Measurements.all (Number).Jobs := Shared.all.Measurements.all (Number).Jobs + 1;
         Shared.all.Measurements.all (Number).Busy_Seconds :=
           Shared.all.Measurements.all (Number).Busy_Seconds +
           Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Beginning);
         Shared.all.Jobs.Complete;
         end loop;
      end if;
      Epub.Performance.End_Task;
   exception
      when Error : others =>
         Shared.all.Jobs.Fatal (Exception_Text (Error));
         begin
            Destroy (Work);
         exception
            when Cleanup : others => Shared.all.Jobs.Fatal (Exception_Text (Cleanup));
         end;
         Epub.Performance.End_Task;
   end Worker;

   procedure Start (Item : in out Pool; Cores : Epub.CPUs.Processor_Lists.Vector) is
   begin
      if Item.Shared /= null or else Cores.Is_Empty then
         raise Worker_Error with "Worker pool requires a fresh pool and eligible cores";
      end if;
      Item.Shared := new State;
      Item.Shared.all.Cores := Cores;
      Item.Shared.all.Measurements := new Worker_Statistics_Array (1 .. Cores.Last_Index);
      Item.Shared.all.Storage := new Job_Array'(1 .. 4 * Cores.Last_Index => null);
      Item.Shared.all.Jobs.Initialize (Item.Shared.all.Storage, Cores.Last_Index);
      Item.Tasks := new Worker_Array'(1 .. Cores.Last_Index => null);
      for Number in Item.Tasks.all'Range loop
         Item.Tasks.all (Number) := new Worker (Item.Shared, Number);
      end loop;
      Item.Shared.all.Jobs.Wait_Started;
      if Item.Shared.all.Jobs.Error'Length > 0 then
         raise Worker_Error with Item.Shared.all.Jobs.Error;
      end if;
   exception
      when others =>
         Stop (Item);
         raise;
   end Start;
   procedure Submit (Item : in out Pool; Work : in out Job_Access; Accepted : out Boolean) is
   begin
      if Item.Shared = null or else Work = null then
         raise Worker_Error with "Cannot submit to an inactive worker pool";
      end if;
      Item.Shared.all.Jobs.Add (Work, Accepted);
      if Accepted then
         Work := null;
      end if;
   end Submit;
   procedure Join (Item : in out Pool) is
   begin
      if Item.Shared /= null then
         Item.Shared.all.Jobs.Wait_Idle;
         if Item.Shared.all.Jobs.Error'Length > 0 then
            raise Worker_Error with Item.Shared.all.Jobs.Error;
         end if;
      end if;
   end Join;
   procedure Stop (Item : in out Pool) is
      Work : Job_Access;
   begin
      if Item.Shared /= null then
         Item.Shared.all.Jobs.Close;
         if Item.Tasks /= null then
            for Task_Object of Item.Tasks.all loop
               if Task_Object /= null then
                  while not Task_Object.all'Terminated loop
                     delay 0.001;
                  end loop;
                  Free_Worker (Task_Object);
               end if;
            end loop;
            Free_Array (Item.Tasks);
         end if;
         loop
            Item.Shared.all.Jobs.Discard_Next (Work);
            exit when Work = null;
            Destroy (Work);
         end loop;
         Free_Jobs (Item.Shared.all.Storage);
         Free_Measurements (Item.Shared.all.Measurements);
         Free_State (Item.Shared);
      end if;
   end Stop;
   function Snapshot (Item : Pool) return Statistics is
     (if Item.Shared = null then (0, 0, 0) else Item.Shared.all.Jobs.Snapshot);
   function Problem (Item : Pool) return String is
     (if Item.Shared = null then "" else Item.Shared.all.Jobs.Error);
   procedure Write_Statistics (Item : Pool; Batch_High_Water, Book_High_Water : Natural) is
      File : Ada.Text_IO.File_Type;
      procedure Metric (Name : String; Value : Natural) is
      begin
         Ada.Text_IO.Put_Line (File, Name & "," & Value'Image);
      end Metric;
   begin
      if Item.Shared = null or else not Ada.Environment_Variables.Exists ("EPUB_CONCURRENCY_STATS") then return; end if;
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File,
        Ada.Environment_Variables.Value ("EPUB_CONCURRENCY_STATS"));
      Ada.Text_IO.Put_Line (File, "Metric,Value");
      Metric ("workers", Item.Shared.all.Cores.Last_Index);
      Metric ("submitted", Item.Snapshot.Submitted);
      Metric ("completed", Item.Snapshot.Completed);
      Metric ("queue_high_water", Item.Snapshot.Queue_High_Water);
      Metric ("batch_high_water", Batch_High_Water);
      Metric ("book_high_water", Book_High_Water);
      Ada.Text_IO.Put_Line (File, "pool_elapsed_seconds," &
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Item.Shared.all.Beginning)'Image);
      for Index in 1 .. Item.Shared.all.Cores.Last_Index loop
         declare
            Prefix : constant String := "worker" & Index'Image;
            CPU : constant Epub.CPUs.Processor := Item.Shared.all.Cores (Index);
         begin
            Metric (Prefix & "_group", CPU.Group);
            Metric (Prefix & "_logical", CPU.Logical);
            Metric (Prefix & "_core", CPU.Core);
            Metric (Prefix & "_jobs", Item.Shared.all.Measurements.all (Index).Jobs);
            Ada.Text_IO.Put_Line (File, Prefix & "_busy_wall_seconds," &
              Item.Shared.all.Measurements.all (Index).Busy_Seconds'Image);
         end;
      end loop;
      Ada.Text_IO.Close (File);
      pragma Assert (not Ada.Text_IO.Is_Open (File));
   end Write_Statistics;
   overriding procedure Finalize (Item : in out Pool) is
   begin
      Stop (Item);
   end Finalize;
end Epub.Workers;

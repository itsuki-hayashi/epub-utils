with Ada.Finalization;
with Epub.CPUs;
with Ada.Real_Time;

package Epub.Workers is
   --  A job must not wait for child jobs. Its completion schedules a continuation.
   type Job is abstract tagged null record;
   procedure Execute (Item : in out Job) is abstract;
   procedure Failed (Item : in out Job; Message : String) is abstract;
   --  Called after Execute/Failed and their local resources have finalized.
   procedure Completed (Item : in out Job) is null;
   procedure Discard (Item : in out Job) is null;
   type Job_Access is access all Job'Class;
   procedure Destroy (Item : in out Job_Access);

   type Statistics is record
      Submitted, Completed, Queue_High_Water : Natural := 0;
   end record;
   type Pool is new Ada.Finalization.Limited_Controlled with private;
   procedure Start (Item : in out Pool; Cores : Epub.CPUs.Processor_Lists.Vector;
                    Queue_Capacity : Natural := 0);
   --  Accepted jobs are owned and finalized by the pool, including failure paths.
   procedure Submit (Item : in out Pool; Work : in out Job_Access; Accepted : out Boolean);
   --  No more jobs will be submitted. Workers drain the queue and then exit.
   procedure Finish_Submission (Item : in out Pool);
   procedure Join (Item : in out Pool);
   procedure Stop (Item : in out Pool);
   function Snapshot (Item : Pool) return Statistics;
   function Problem (Item : Pool) return String;
   procedure Write_Statistics (Item : Pool; Batch_High_Water, Book_High_Water : Natural);
   Worker_Error : exception;
private
   type Job_Array is array (Positive range <>) of Job_Access;
   type Job_Array_Access is access Job_Array;
   protected type Queue is
      procedure Initialize (Storage : Job_Array_Access; Worker_Count : Positive);
      procedure Add (Work : Job_Access; Accepted : out Boolean);
      entry Take (Work : out Job_Access);
      procedure Complete;
      procedure Discard_Next (Work : out Job_Access);
      procedure Started (Message : String);
      entry Wait_Started;
      entry Wait_Idle;
      procedure Close;
      procedure Fatal (Message : String);
      function Error return String;
      function Snapshot return Statistics;
   private
      Jobs : Job_Array_Access;
      Capacity : Positive := 1;
      Expected : Natural := 0;
      Head, Tail : Positive := 1;
      Count, Active, Ready : Natural := 0;
      Closing : Boolean := False;
      Failure : String (1 .. 4_096);
      Failure_Length : Natural := 0;
      Totals : Statistics;
      procedure Save_Error (Message : String);
   end Queue;
   type Worker_Statistics is record
      Jobs : Natural := 0;
      Busy_Seconds : Duration := 0.0;
   end record;
   type Worker_Statistics_Array is array (Positive range <>) of Worker_Statistics;
   type Worker_Statistics_Access is access Worker_Statistics_Array;
   type State is limited record
      Jobs : Queue;
      Storage : Job_Array_Access;
      Cores : Epub.CPUs.Processor_Lists.Vector;
      Measurements : Worker_Statistics_Access;
      Beginning : Ada.Real_Time.Time := Ada.Real_Time.Clock;
   end record;
   type State_Access is access State;
   task type Worker (Shared : not null State_Access; Number : Positive)
     with Storage_Size => 16 * 1024 * 1024;
   type Worker_Access is access Worker;
   type Worker_Array is array (Positive range <>) of Worker_Access;
   type Workers_Access is access Worker_Array;
   type Pool is new Ada.Finalization.Limited_Controlled with record
      Shared : State_Access;
      Tasks : Workers_Access;
   end record;
   overriding procedure Finalize (Item : in out Pool);
end Epub.Workers;

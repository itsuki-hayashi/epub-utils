with Epub.Name_Indexes;
with Epub.Allocation_Stats;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Interfaces;

package body Epub.Performance is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;
   use type Epub.Allocation_Stats.Count;
   type Frame is record
      Kind : Phase := Phase'First;
      Beginning : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Children : Duration := 0.0;
   end record;
   type Frames is array (Positive range 1 .. 64) of Frame;
   type Timings is array (Phase) of Duration;
   type Calls_Array is array (Phase) of Natural;
   type Counters is array (Counter) of Interfaces.Unsigned_64;
   type Measurements is record
      Inclusive, Exclusive : Timings := [others => 0.0];
      Calls : Calls_Array := [others => 0];
      Counts : Counters := [others => 0];
      Abandoned : Natural := 0;
      Allocations, Bytes : Epub.Allocation_Stats.Count := 0;
   end record;
   type Context is record
      Stack : Frames;
      Depth, Book : Natural := 0;
      Data : Measurements;
   end record;
   type Context_Access is access Context;
   Local : Context_Access := null;
   pragma Thread_Local_Storage (Local);
   Last_Allocations, Last_Bytes : Epub.Allocation_Stats.Count := 0;
   pragma Thread_Local_Storage (Last_Allocations);
   pragma Thread_Local_Storage (Last_Bytes);
   procedure Free is new Ada.Unchecked_Deallocation (Context, Context_Access);

   --  Only publication of task-local totals and per-book decode identities needs
   --  a lock. Codec timers and allocation increments never share mutable state.
   protected Totals is
      procedure Merge (Value : Measurements);
      procedure Next_Book (ID : out Natural);
      procedure Decode (Book, Ordinal : Natural; Repeated : out Boolean);
      procedure Snapshot (Value : out Measurements);
   private
      Data : Measurements;
      Books : Natural := 0;
      Seen : Epub.Name_Indexes.Index;
   end Totals;
   protected body Totals is
      procedure Merge (Value : Measurements) is
      begin
         for Kind in Phase loop
            Data.Inclusive (Kind) := Data.Inclusive (Kind) + Value.Inclusive (Kind);
            Data.Exclusive (Kind) := Data.Exclusive (Kind) + Value.Exclusive (Kind);
            Data.Calls (Kind) := Data.Calls (Kind) + Value.Calls (Kind);
         end loop;
         for Kind in Counter loop
            Data.Counts (Kind) := Data.Counts (Kind) + Value.Counts (Kind);
         end loop;
         Data.Abandoned := Data.Abandoned + Value.Abandoned;
         Data.Allocations := Data.Allocations + Value.Allocations;
         Data.Bytes := Data.Bytes + Value.Bytes;
      end Merge;
      procedure Next_Book (ID : out Natural) is
      begin
         Books := Books + 1;
         ID := Books;
      end Next_Book;
      procedure Decode (Book, Ordinal : Natural; Repeated : out Boolean) is
         Key : constant String := Book'Image & ":" & Ordinal'Image;
      begin
         Repeated := Seen.Find (Key) /= 0;
         if not Repeated then Seen.Insert_First (Key, 1); end if;
      end Decode;
      procedure Snapshot (Value : out Measurements) is
      begin
         Value := Data;
      end Snapshot;
   end Totals;

   procedure Ensure_Context is
   begin
      if Local = null then Local := new Context; end if;
   end Ensure_Context;
   function New_Book return Natural is
      ID : Natural;
   begin
      Totals.Next_Book (ID);
      return ID;
   end New_Book;
   procedure Begin_Job (Book : Natural) is
   begin
      Ensure_Context;
      Local.all.Data.Abandoned := Local.all.Data.Abandoned + Local.all.Depth;
      Local.all.Depth := 0;
      Local.all.Book := Book;
   end Begin_Job;
   procedure Begin_Book is
   begin
      Begin_Job (New_Book);
   end Begin_Book;
   procedure End_Task is
      Data : Measurements;
   begin
      if Local /= null then
         Data := Local.all.Data;
         Data.Abandoned := Data.Abandoned + Local.all.Depth;
      end if;
      Data.Allocations := Epub.Allocation_Stats.Allocations - Last_Allocations;
      Data.Bytes := Epub.Allocation_Stats.Requested_Bytes - Last_Bytes;
      Last_Allocations := Epub.Allocation_Stats.Allocations;
      Last_Bytes := Epub.Allocation_Stats.Requested_Bytes;
      Totals.Merge (Data);
      Free (Local);
   end End_Task;
   procedure Add (Kind : Counter; Amount : Natural := 1) is
   begin
      Ensure_Context;
      Local.all.Data.Counts (Kind) := Local.all.Data.Counts (Kind) + Interfaces.Unsigned_64 (Amount);
   end Add;
   procedure Resource_Decode (Ordinal : Positive) is
      Repeated : Boolean;
   begin
      Add (Member_Decodes);
      Totals.Decode (Local.all.Book, Ordinal, Repeated);
      if Repeated then Add (Repeated_Member_Decodes); end if;
   end Resource_Decode;
   procedure Start (Kind : Phase) is
   begin
      Ensure_Context;
      if Local.all.Depth = Local.all.Stack'Length then
         raise Program_Error with "Profiling timer stack exhausted";
      end if;
      Local.all.Depth := Local.all.Depth + 1;
      Local.all.Stack (Local.all.Depth) := (Kind, Ada.Real_Time.Clock, 0.0);
   end Start;
   procedure Stop (Kind : Phase) is
      Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Elapsed : Duration;
   begin
      if Local = null or else Local.all.Depth = 0 or else Local.all.Stack (Local.all.Depth).Kind /= Kind then
         raise Program_Error with "Unbalanced profiling timer";
      end if;
      Elapsed := Ada.Real_Time.To_Duration (Now - Local.all.Stack (Local.all.Depth).Beginning);
      Local.all.Data.Inclusive (Kind) := Local.all.Data.Inclusive (Kind) + Elapsed;
      Local.all.Data.Exclusive (Kind) := Local.all.Data.Exclusive (Kind) + Elapsed -
        Local.all.Stack (Local.all.Depth).Children;
      Local.all.Data.Calls (Kind) := Local.all.Data.Calls (Kind) + 1;
      Local.all.Depth := Local.all.Depth - 1;
      if Local.all.Depth > 0 then
         Local.all.Stack (Local.all.Depth).Children := Local.all.Stack (Local.all.Depth).Children + Elapsed;
      end if;
   end Stop;
   procedure Dump is
      File : Ada.Text_IO.File_Type;
      Data : Measurements;
   begin
      End_Task;
      if Ada.Environment_Variables.Exists ("EPUB_PROFILE_PATH") then
         Totals.Snapshot (Data);
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Ada.Environment_Variables.Value ("EPUB_PROFILE_PATH"));
         Ada.Text_IO.Put_Line (File, "phase,inclusive_seconds,calls,exclusive_seconds");
         for Kind in Phase loop
            Ada.Text_IO.Put_Line (File, Kind'Image & "," & Data.Inclusive (Kind)'Image & "," &
              Data.Calls (Kind)'Image & "," & Data.Exclusive (Kind)'Image);
         end loop;
         Ada.Text_IO.Close (File);
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File,
           Ada.Environment_Variables.Value ("EPUB_PROFILE_PATH") & ".counters.csv");
         Ada.Text_IO.Put_Line (File, "counter,count");
         for Kind in Counter loop
            Ada.Text_IO.Put_Line (File, Kind'Image & "," & Data.Counts (Kind)'Image);
         end loop;
         Ada.Text_IO.Put_Line (File, "ABANDONED_TIMERS," & Data.Abandoned'Image);
         Ada.Text_IO.Put_Line (File, "OWNED_CONTAINER_ALLOCATIONS," & Data.Allocations'Image);
         Ada.Text_IO.Put_Line (File, "OWNED_CONTAINER_REQUESTED_BYTES," & Data.Bytes'Image);
         Ada.Text_IO.Close (File);
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File,
           Ada.Environment_Variables.Value ("EPUB_PROFILE_PATH") & ".units.txt");
         Ada.Text_IO.Put_Line (File, "Phase seconds sum task-local wall durations; overlapping jobs add.");
         Ada.Text_IO.Put_Line (File, "They are neither process CPU seconds nor end-to-end elapsed seconds.");
         Ada.Text_IO.Put_Line (File, "Use process CPU / (elapsed * workers) for aggregate utilization.");
         Ada.Text_IO.Close (File);
      end if;
   end Dump;
end Epub.Performance;

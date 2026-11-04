with Epub.Name_Indexes;
with Epub.Allocation_Stats;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Text_IO;
with Interfaces;

package body Epub.Performance is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;
   Seen : Epub.Name_Indexes.Index;
   type Frame is record
      Kind : Phase := Phase'First;
      Beginning : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Children : Duration := 0.0;
   end record;
   Stack : array (Positive range 1 .. 64) of Frame;
   Depth : Natural := 0;
   Inclusive, Exclusive : array (Phase) of Duration := [others => 0.0];
   Calls : array (Phase) of Natural := [others => 0];
   Counts : array (Counter) of Interfaces.Unsigned_64 := [others => 0];
   Abandoned : Natural := 0;

   procedure Begin_Book is
   begin
      --  Exceptions can bypass explicit Stop calls; never charge the next book.
      Abandoned := Abandoned + Depth;
      Depth := 0;
      Seen.Clear;
   end Begin_Book;
   procedure Add (Kind : Counter; Amount : Natural := 1) is
   begin
      Counts (Kind) := Counts (Kind) + Interfaces.Unsigned_64 (Amount);
   end Add;
   procedure Resource_Decode (Ordinal : Positive) is
   begin
      Add (Member_Decodes);
      if Seen.Find (Ordinal'Image) /= 0 then
         Add (Repeated_Member_Decodes);
      else
         Seen.Insert_First (Ordinal'Image, Ordinal);
      end if;
   end Resource_Decode;
   procedure Start (Kind : Phase) is
   begin
      if Depth = Stack'Length then
         raise Program_Error with "Profiling timer stack exhausted";
      end if;
      Depth := Depth + 1;
      Stack (Depth) := (Kind, Ada.Real_Time.Clock, 0.0);
   end Start;
   procedure Stop (Kind : Phase) is
      Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Elapsed : Duration;
   begin
      if Depth = 0 or else Stack (Depth).Kind /= Kind then
         raise Program_Error with "Unbalanced profiling timer";
      end if;
      Elapsed := Ada.Real_Time.To_Duration (Now - Stack (Depth).Beginning);
      Inclusive (Kind) := Inclusive (Kind) + Elapsed;
      Exclusive (Kind) := Exclusive (Kind) + Elapsed - Stack (Depth).Children;
      Calls (Kind) := Calls (Kind) + 1;
      Depth := Depth - 1;
      if Depth > 0 then
         Stack (Depth).Children := Stack (Depth).Children + Elapsed;
      end if;
   end Stop;
   procedure Dump is
      File : Ada.Text_IO.File_Type;
   begin
      if Ada.Environment_Variables.Exists ("EPUB_PROFILE_PATH") then
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File,
           Ada.Environment_Variables.Value ("EPUB_PROFILE_PATH"));
         Ada.Text_IO.Put_Line (File, "phase,inclusive_seconds,calls,exclusive_seconds");
         for Kind in Phase loop
            Ada.Text_IO.Put_Line (File, Kind'Image & "," & Inclusive (Kind)'Image & "," &
              Calls (Kind)'Image & "," & Exclusive (Kind)'Image);
         end loop;
         Ada.Text_IO.Close (File);
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File,
           Ada.Environment_Variables.Value ("EPUB_PROFILE_PATH") & ".counters.csv");
         Ada.Text_IO.Put_Line (File, "counter,count");
         for Kind in Counter loop
            Ada.Text_IO.Put_Line (File, Kind'Image & "," & Counts (Kind)'Image);
         end loop;
         Ada.Text_IO.Put_Line (File, "ABANDONED_TIMERS," & Natural'Image (Abandoned + Depth));
         Ada.Text_IO.Put_Line (File, "OWNED_CONTAINER_ALLOCATIONS," & Epub.Allocation_Stats.Allocations'Image);
         Ada.Text_IO.Put_Line (File, "OWNED_CONTAINER_REQUESTED_BYTES," & Epub.Allocation_Stats.Requested_Bytes'Image);
         Ada.Text_IO.Close (File);
      end if;
   end Dump;
end Epub.Performance;

package body Epub.Allocation_Stats is
   Calls, Bytes_Requested : Count := 0;
   procedure Record_Allocation (Bytes : Count) is
   begin
      Calls := Calls + 1;
      Bytes_Requested := Bytes_Requested + Bytes;
   end Record_Allocation;
   function Allocations return Count is (Calls);
   function Requested_Bytes return Count is (Bytes_Requested);
end Epub.Allocation_Stats;

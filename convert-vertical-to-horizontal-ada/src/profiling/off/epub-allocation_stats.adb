package body Epub.Allocation_Stats is
   procedure Record_Allocation (Bytes : Count) is
      pragma Unreferenced (Bytes);
   begin
      null;
   end Record_Allocation;
   function Allocations return Count is (0);
   function Requested_Bytes return Count is (0);
end Epub.Allocation_Stats;

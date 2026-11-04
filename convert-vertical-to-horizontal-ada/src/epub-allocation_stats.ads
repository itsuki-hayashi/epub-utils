package Epub.Allocation_Stats is
   pragma Preelaborate;
   type Count is mod 2 ** 64;
   procedure Record_Allocation (Bytes : Count) with Inline_Always;
   function Allocations return Count with Inline_Always;
   function Requested_Bytes return Count with Inline_Always;
end Epub.Allocation_Stats;

package body Epub.Performance is
   procedure Begin_Book is null;
   function New_Book return Natural is (0);
   procedure Begin_Job (Book : Natural) is
      pragma Unreferenced (Book);
   begin
      null;
   end Begin_Job;
   procedure End_Task is null;
   procedure Add (Kind : Counter; Amount : Natural := 1) is
      pragma Unreferenced (Kind, Amount);
   begin
      null;
   end Add;
   procedure Resource_Decode (Ordinal : Positive) is
      pragma Unreferenced (Ordinal);
   begin
      null;
   end Resource_Decode;
   procedure Start (Kind : Phase) is
      pragma Unreferenced (Kind);
   begin
      null;
   end Start;
   procedure Stop (Kind : Phase) is
      pragma Unreferenced (Kind);
   begin
      null;
   end Stop;
   procedure Dump is
   begin
      null;
   end Dump;
end Epub.Performance;

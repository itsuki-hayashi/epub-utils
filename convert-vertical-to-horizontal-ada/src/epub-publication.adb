package body Epub.Publication with SPARK_Mode is
   function Eligible (Current : State; Destination_Exists : Boolean) return Boolean is
     (Current = Verified and then not Destination_Exists);
   procedure Mark_Verified (Current : in out State) is
   begin
      Current := Verified;
   end Mark_Verified;
   procedure Mark_Published (Current : in out State) is
   begin
      Current := Published;
   end Mark_Published;
end Epub.Publication;

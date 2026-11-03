package Epub.Publication with SPARK_Mode, Pure is
   type State is (Unverified, Verified, Published);
   function Eligible (Current : State; Destination_Exists : Boolean) return Boolean
     with Global => null,
       Post => Eligible'Result = (Current = Verified and then not Destination_Exists);
   procedure Mark_Verified (Current : in out State)
     with Global => null, Pre => Current = Unverified, Post => Current = Verified;
   procedure Mark_Published (Current : in out State)
     with Global => null, Pre => Current = Verified, Post => Current = Published;
end Epub.Publication;

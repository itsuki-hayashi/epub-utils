with AUnit;
with AUnit.Simple_Test_Cases;

package Stream_Cases is
   type Case_Kind is (Bulk_Roundtrip, Seek_Overwrite, Access_And_Lifetime, Hashed_Output,
                     String_View, Source_Ranges, Buffered_Output, Input_Cache, Memory_Output);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Bulk_Roundtrip;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Stream_Cases;

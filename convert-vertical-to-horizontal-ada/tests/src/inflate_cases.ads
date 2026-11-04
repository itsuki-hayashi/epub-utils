with AUnit;
with AUnit.Simple_Test_Cases;

package Inflate_Cases is
   type Case_Kind is (Differential, Malformed, Long_Codes, Compatibility_Method, Mutations,
                     Bounded_Input, Original_Representation);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Differential;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Inflate_Cases;

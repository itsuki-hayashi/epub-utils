with AUnit;
with AUnit.Simple_Test_Cases;
package XML_Cases is
   type Case_Kind is (Summary_Semantics, Context_Lifetimes, Concurrent_Isolation, Large_Inputs, Token_Queries);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Summary_Semantics;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end XML_Cases;

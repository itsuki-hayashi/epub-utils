with AUnit;
with AUnit.Simple_Test_Cases;

package Report_Cases is
   type Case_Kind is (Fixture_Manifest, Report_Schema, JSON_Escapes);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Fixture_Manifest;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Report_Cases;

with AUnit;
with AUnit.Simple_Test_Cases;

package Core_Cases is
   type Case_Kind is (Classification_Boundaries, Patch_Preservation,
                      Mode_Mapping, Publication_Decisions, Generated_Scanners,
                      List_Ownership);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Classification_Boundaries;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Core_Cases;

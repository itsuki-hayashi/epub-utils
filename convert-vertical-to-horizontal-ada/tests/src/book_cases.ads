with AUnit;
with AUnit.Simple_Test_Cases;

package Book_Cases is
   type Case_Kind is (Missing_Resource, Duplicate_Manifest, Unknown_And_Empty_Spine,
                      Rootfile_Counts, Signature_Guards, Fixed_Layout_Order,
                      Import_Cycles, Nonspine_Editing, Package_Encoding,
                      Unsupported_Evidence, XML_Entity_Policy, Image_Thresholds);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Missing_Resource;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Book_Cases;

with AUnit;
with AUnit.Simple_Test_Cases;

package Text_Cases is
   type Case_Kind is
     (CSS_Matrix, Markup_Preservation, Package_Metadata, Resource_References,
      CSS_Imports, Active_Selectors, Encoding_Roundtrips, Encoding_Errors,
      Reference_Matrix, Rejected_References, Scanner_Boundaries);
   function Create (Kind : Case_Kind)
      return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := CSS_Matrix;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Text_Cases;

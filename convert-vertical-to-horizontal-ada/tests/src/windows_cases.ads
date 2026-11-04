with AUnit;
with AUnit.Simple_Test_Cases;

package Windows_Cases is
   type Case_Kind is (Long_Unicode_Paths, Publication_Collision,
                      Verification_Cleanup, Recursive_Enumeration, CPU_API_Fallbacks);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Long_Unicode_Paths;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Windows_Cases;

with AUnit;
with AUnit.Simple_Test_Cases;
with Native_Faults;

package Fault_Cases is
   function Create (Kind : Native_Faults.Operation; Skip : Natural := 0; Streaming : Boolean := False)
      return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Native_Faults.Operation := Native_Faults.None;
      Skip : Natural := 0;
      Streaming : Boolean := False;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Fault_Cases;

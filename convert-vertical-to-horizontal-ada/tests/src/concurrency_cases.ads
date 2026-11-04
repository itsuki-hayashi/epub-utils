with AUnit;
with AUnit.Simple_Test_Cases;

package Concurrency_Cases is
   type Case_Kind is (Topology_Selection, Native_Topology, Shared_Source_Readers,
                     Temporary_Reservations, Worker_Continuations, Destination_Groups,
                     Archive_Equivalence, Failure_Isolation, Affinity_Failure, Reversed_Completion,
                     Startup_Fallback, Failure_Precedence);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Topology_Selection;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Concurrency_Cases;

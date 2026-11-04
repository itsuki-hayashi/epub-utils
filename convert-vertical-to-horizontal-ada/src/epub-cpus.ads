with Epub.Lists;

package Epub.CPUs is
   type Processor is record
      Group, Logical, Core, Efficiency : Natural := 0;
      Allowed, Physical_Known, Class_Known : Boolean := False;
   end record;
   package Processor_Lists is new Epub.Lists (Processor);
   type Topology is record
      Cores : Processor_Lists.Vector;
      Classes_Known : Boolean := False;
      Restricted_Fallback : Boolean := False;
   end record;
   function Select_Cores (Raw : Processor_Lists.Vector) return Topology;
   function Discover return Topology;
   procedure Pin_Current (Core : Processor);
   Affinity_Error : exception;
end Epub.CPUs;

with Interfaces.C;
with System;

package body Epub.CPUs.Native is
   use type Interfaces.C.long_long;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned;
   function Count return Interfaces.C.unsigned
     with Import, Convention => C, External_Name => "epub_cpu_count";
   function Read_Topology (Buffer : System.Address; Capacity : Interfaces.C.size_t)
      return Interfaces.C.long_long
     with Import, Convention => C, External_Name => "epub_cpu_topology";
   function Pin (CPU : Interfaces.C.unsigned) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_cpu_pin";
   type Native_Processor is record
      Group, Logical, Core, Efficiency, Allowed, Physical_Known, Class_Known : Interfaces.C.unsigned;
   end record with Convention => C;
   type Native_Array is array (Positive range <>) of Native_Processor with Convention => C;
   function Probe return Processor_Lists.Vector is
      Result : Processor_Lists.Vector;
      Raw : aliased Native_Array (1 .. Natural (Count));
      Used : Interfaces.C.long_long;
   begin
      if Raw'Length = 0 then
         return Result;
      end if;
      Used := Read_Topology (Raw'Address, Interfaces.C.size_t (Raw'Length));
      if Used <= 0 or else Used > Interfaces.C.long_long (Raw'Length) then
         return Result;
      end if;
      for Position in 1 .. Natural (Used) loop
         declare
            CPU : Native_Processor renames Raw (Position);
         begin
            Result.Append ((Natural (CPU.Group), Natural (CPU.Logical), Natural (CPU.Core),
                            Natural (CPU.Efficiency), CPU.Allowed /= 0, CPU.Physical_Known /= 0,
                            CPU.Class_Known /= 0));
         end;
      end loop;
      return Result;
   exception
      when Constraint_Error =>
         declare
            Empty : Processor_Lists.Vector;
         begin
            return Empty;
         end;
   end Probe;
   procedure Bind (Core : Processor) is
   begin
      if Pin (Interfaces.C.unsigned (Core.Logical)) /= 0 then
         raise Affinity_Error with "Cannot pin worker to its physical core";
      end if;
   end Bind;
end Epub.CPUs.Native;

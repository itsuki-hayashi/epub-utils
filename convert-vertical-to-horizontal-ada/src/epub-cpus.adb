with Epub.CPUs.Native;

package body Epub.CPUs is
   function Select_Cores (Raw : Processor_Lists.Vector) return Topology is
      Result : Topology;
      Highest : Natural := 0;
      Have_Class : Boolean := False;
   begin
      for CPU of Raw loop
         if CPU.Class_Known then
            Have_Class := True;
            Highest := Natural'Max (Highest, CPU.Efficiency);
         end if;
      end loop;
      Result.Classes_Known := Have_Class;
      for CPU of Raw loop
         if CPU.Allowed and then CPU.Physical_Known and then
           (not Have_Class or else (CPU.Class_Known and then CPU.Efficiency = Highest))
         then
            declare
               Duplicate : Boolean := False;
            begin
               for Chosen of Result.Cores loop
                  Duplicate := Duplicate or else (Chosen.Group = CPU.Group and then Chosen.Core = CPU.Core);
               end loop;
               if not Duplicate then
                  Result.Cores.Append (CPU);
               end if;
            end;
         end if;
      end loop;
      if Result.Cores.Is_Empty then
         for CPU of Raw loop
            if CPU.Allowed then
               Result.Cores.Append (CPU);
               Result.Restricted_Fallback := True;
               exit;
            end if;
         end loop;
      end if;
      return Result;
   end Select_Cores;
   function Discover return Topology is
   begin
      return Select_Cores (Native.Probe);
   end Discover;
   procedure Pin_Current (Core : Processor) is
   begin
      Native.Bind (Core);
   end Pin_Current;
end Epub.CPUs;

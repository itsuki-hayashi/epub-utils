private package Epub.CPUs.Native is
   function Probe return Processor_Lists.Vector;
   procedure Bind (Core : Processor);
end Epub.CPUs.Native;

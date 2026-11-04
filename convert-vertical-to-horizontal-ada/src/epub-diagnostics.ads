package Epub.Diagnostics is
   type Sink is access procedure (Message : String);
   --  Capture is task-local. Worker jobs forward diagnostics to their result;
   --  ordinary sequential callers retain immediate stderr diagnostics.
   procedure Capture (Target : Sink);
   procedure Report (Message : String);
end Epub.Diagnostics;

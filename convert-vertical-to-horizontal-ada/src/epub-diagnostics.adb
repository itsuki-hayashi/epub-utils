with Ada.Text_IO;

package body Epub.Diagnostics is
   Target_Sink : Sink := null;
   pragma Thread_Local_Storage (Target_Sink);
   procedure Capture (Target : Sink) is
   begin
      Target_Sink := Target;
   end Capture;
   procedure Report (Message : String) is
   begin
      if Target_Sink = null then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Message);
      else
         Target_Sink.all (Message);
      end if;
   end Report;
end Epub.Diagnostics;

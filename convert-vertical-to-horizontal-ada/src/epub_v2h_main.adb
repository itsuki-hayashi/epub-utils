with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Text_IO;
with Epub.CLI;

procedure Epub_V2h_Main is
begin
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Epub.CLI.Run));
exception
   when Error : others =>
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Epub_V2h_Main;

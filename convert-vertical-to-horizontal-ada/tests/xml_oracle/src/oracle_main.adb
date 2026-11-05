with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with Oracle_IO;
with Oracle_XML;
procedure Oracle_Main is
   procedure Inspect (Path : String) is
   begin
      declare
      Document : constant Oracle_XML.Document := Oracle_XML.Parse (Oracle_IO.Read (Path));
      begin
      Put_Line ("OK");
      for Position in 1 .. Document.Last_Index loop
         declare
            Item : constant Oracle_XML.Node := Document (Position);
         begin
            Put (Item.Parent'Image & Character'Val (9) & Oracle_IO.Hex (To_String (Item.Name)) &
                 Character'Val (9) & Oracle_IO.Hex (To_String (Item.Content)));
            for Attr_Position in 1 .. Item.Attributes.Last_Index loop
               declare
                  Attr : constant Oracle_XML.Attribute := Item.Attributes (Attr_Position);
               begin
                  Put (Character'Val (9) & Oracle_IO.Hex (To_String (Attr.Name)) & "=" & Oracle_IO.Hex (To_String (Attr.Value)));
               end;
            end loop;
            New_Line;
         end;
      end loop;
      end;
   exception
      when Failure : others => Put_Line ("ERR:" & Oracle_IO.Hex (Ada.Exceptions.Exception_Message (Failure)));
   end Inspect;
begin
   while not End_Of_File loop
      Inspect (Get_Line);
      Put_Line (".");
   end loop;
end Oracle_Main;

with Ada.Exceptions;
with Ada.Text_IO; use Ada.Text_IO;
with Epub.XML;
with Oracle_IO;
procedure Summary_Main is
   procedure Emit (Item : Epub.XML.Summary) is
   begin
      Put_Line ("OK");
      Put_Line (Epub.XML.Has_Visible_Text (Item)'Image & Character'Val (9) &
                Epub.XML.Has_Image (Item)'Image & Character'Val (9) & Epub.XML.Is_Fixed (Item)'Image);
      for Position in 1 .. Epub.XML.Count (Item) loop
         Put (Epub.XML.Kind (Item, Position)'Image & Character'Val (9) &
              Epub.XML.Parent_Kind (Item, Position)'Image & Character'Val (9) &
              Oracle_IO.Hex (Epub.XML.Direct_Text (Item, Position)));
         for Attribute_Field in Epub.XML.Field_Kind loop
            Put (Character'Val (9) & Oracle_IO.Hex (Epub.XML.Field_Value (Item, Position, Attribute_Field)));
         end loop;
         New_Line;
      end loop;
   end Emit;
   procedure Inspect (Request : String) is
      Text : constant String := Oracle_IO.Read (Request (Request'First + 1 .. Request'Last));
   begin
      case Request (Request'First) is
         when 'C' => Emit (Epub.XML.Inspect_Container (Text));
         when 'P' => Emit (Epub.XML.Inspect_Package (Text));
         when others => Emit (Epub.XML.Inspect_Content (Text));
      end case;
   exception
      when Failure : others => Put_Line ("ERR:" & Oracle_IO.Hex (Ada.Exceptions.Exception_Message (Failure)));
   end Inspect;
begin
   while not End_Of_File loop
      Inspect (Get_Line);
      Put_Line (".");
   end loop;
end Summary_Main;

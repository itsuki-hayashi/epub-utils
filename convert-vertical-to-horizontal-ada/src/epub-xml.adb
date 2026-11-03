with Ada.Strings.Fixed;
with Input_Sources.Strings;
with Sax.Attributes;
with Sax.Readers;
with Unicode.CES.UTF8;

package body Epub.XML is
   use Ada.Strings.Unbounded;
   package Indices is new Epub.Lists (Natural);
   type Collector is new Sax.Readers.Reader with record
      Nodes : Document;
      Stack : Indices.Vector;
   end record;

   overriding procedure Start_Element
     (Handler : in out Collector; Namespace_URI, Local_Name, Qname : String;
      Atts : Sax.Attributes.Attributes'Class);
   overriding procedure End_Element
     (Handler : in out Collector; Namespace_URI, Local_Name, Qname : String);
   overriding procedure Characters (Handler : in out Collector; Ch : String);
   overriding procedure Internal_Entity_Decl
     (Handler : in out Collector; Name, Value : String);
   overriding procedure External_Entity_Decl
     (Handler : in out Collector; Name, Public_Id, System_Id : String);
   overriding function Resolve_Entity
     (Handler : Collector; Public_Id, System_Id : String)
      return Input_Sources.Input_Source_Access;

   overriding procedure Start_Element
     (Handler : in out Collector; Namespace_URI, Local_Name, Qname : String;
      Atts : Sax.Attributes.Attributes'Class) is
      pragma Unreferenced (Namespace_URI, Qname);
      Item : Node;
   begin
      Item.Name := To_Unbounded_String (Local_Name);
      if not Handler.Stack.Is_Empty then
         Item.Parent := Handler.Stack.Last_Element;
      end if;
      for Attribute_Position in 0 .. Integer (Atts.Get_Length) - 1 loop
         Item.Attributes.Append
           (Attribute'(Name => To_Unbounded_String (Atts.Get_Qname (Attribute_Position)),
                       Value => To_Unbounded_String (Atts.Get_Value (Attribute_Position))));
      end loop;
      Handler.Nodes.Append (Item);
      Handler.Stack.Append (Handler.Nodes.Last_Index);
   end Start_Element;

   overriding procedure End_Element
     (Handler : in out Collector; Namespace_URI, Local_Name, Qname : String) is
      pragma Unreferenced (Namespace_URI, Local_Name, Qname);
   begin
      Handler.Stack.Delete_Last;
   end End_Element;

   overriding procedure Characters (Handler : in out Collector; Ch : String) is
   begin
      if not Handler.Stack.Is_Empty then
         declare
            Position : constant Positive := Handler.Stack.Last_Element;
            Item : Node := Handler.Nodes (Position);
         begin
            Append (Item.Content, Ch);
            Handler.Nodes.Replace_Element (Position, Item);
         end;
      end if;
   end Characters;

   overriding procedure Internal_Entity_Decl
     (Handler : in out Collector; Name, Value : String) is
      pragma Unreferenced (Handler, Name, Value);
   begin
      raise Invalid_XML with "XML entity declarations require manual review";
   end Internal_Entity_Decl;

   overriding procedure External_Entity_Decl
     (Handler : in out Collector; Name, Public_Id, System_Id : String) is
      pragma Unreferenced (Handler, Name, Public_Id, System_Id);
   begin
      raise Invalid_XML with "External XML entity declarations are unsupported";
   end External_Entity_Decl;

   overriding function Resolve_Entity
     (Handler : Collector; Public_Id, System_Id : String)
      return Input_Sources.Input_Source_Access is
      pragma Unreferenced (Handler, Public_Id, System_Id);
   begin
      raise Invalid_XML with "External XML resources are unsupported";
      return null;
   end Resolve_Entity;

   function Inspection_Text (Text : String) return String is
      Declaration_End : constant Natural := Ada.Strings.Fixed.Index (Text, "?>");
   begin
      if Text'Length >= 5 and then Text (Text'First .. Text'First + 4) = "<?xml"
        and then Declaration_End /= 0
      then
         declare
            Position : Natural := Ada.Strings.Fixed.Index
              (Text (Text'First .. Declaration_End), "encoding");
            Quote : Character;
            Start : Natural;
         begin
            if Position /= 0 then
               while Position < Declaration_End
                 and then Text (Position) /= '"' and then Text (Position) /= '''
               loop
                  Position := Position + 1;
               end loop;
               if Position < Declaration_End then
                  Quote := Text (Position);
                  Start := Position + 1;
                  Position := Start;
                  while Position < Declaration_End and then Text (Position) /= Quote loop
                     Position := Position + 1;
                  end loop;
                  return Text (Text'First .. Start - 1) & "UTF-8"
                    & Text (Position .. Text'Last);
               end if;
            end if;
         end;
      end if;
      return Text;
   end Inspection_Text;

   function Parse (Text : String) return Document is
      Parser : Collector;
      Input : Input_Sources.Strings.String_Input;
   begin
      Parser.Set_Feature (Sax.Readers.External_General_Entities_Feature, False);
      Parser.Set_Feature (Sax.Readers.External_Parameter_Entities_Feature, False);
      Input_Sources.Strings.Open
        (Inspection_Text (Text), Unicode.CES.UTF8.UTF8_Encoding, Input);
      begin
         Parser.Parse (Input);
      exception
         when others =>
            Input.Close;
            raise;
      end;
      Input.Close;
      return Parser.Nodes;
   end Parse;

   function Get_Attribute (Item : Node; Name : String) return String is
   begin
      for Attr of Item.Attributes loop
         if To_String (Attr.Name) = Name then
            return To_String (Attr.Value);
         end if;
      end loop;
      return "";
   end Get_Attribute;
end Epub.XML;

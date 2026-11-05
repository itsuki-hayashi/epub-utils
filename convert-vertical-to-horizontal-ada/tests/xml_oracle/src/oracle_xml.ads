with Ada.Strings.Unbounded;
with Epub.Lists;

package Oracle_XML is
   type Attribute is record
      Name, Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   package Attribute_Lists is new Epub.Lists (Attribute);
   type Node is record
      Name, Content : Ada.Strings.Unbounded.Unbounded_String;
      Attributes : Attribute_Lists.Vector;
      Parent : Natural := 0;
   end record;
   package Node_Lists is new Epub.Lists (Node);
   subtype Document is Node_Lists.Vector;
   function Parse (Text : String) return Document;
   function Get_Attribute (Item : Node; Name : String) return String;
   Invalid_XML : exception;
end Oracle_XML;

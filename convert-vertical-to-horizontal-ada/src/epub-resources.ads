with Ada.Strings.Unbounded;
with Epub.Lists;

package Epub.Resources is
   use type Ada.Strings.Unbounded.Unbounded_String;
   package String_Lists is new Epub.Lists (Ada.Strings.Unbounded.Unbounded_String);
   function Resolve (Base_Path, Reference : String) return String;
   function Contains (Items : String_Lists.Vector; Value : String) return Boolean;
   procedure Include (Items : in out String_Lists.Vector; Value : String);
   function Tokens (Value : String) return String_Lists.Vector;
   function Imports (Stylesheet : String) return String_Lists.Vector;
   function Uses_Vertical
     (Stylesheet : String; Classes, Ids : String_Lists.Vector) return Boolean;
   Invalid_Resource : exception;
end Epub.Resources;

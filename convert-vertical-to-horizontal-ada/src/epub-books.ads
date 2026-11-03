with Ada.Strings.Unbounded;
with Epub.Archives;
with Epub.Classification;
with Epub.Lists;

package Epub.Books is
   type Resource_Patch is record
      Name, Payload : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   package Patch_Lists is new Epub.Lists (Resource_Patch);
   type Book_Plan is record
      Reason : Epub.Classification.Layout := Epub.Classification.Horizontal;
      Patches : Patch_Lists.Vector;
   end record;
   function Analyze_Book (Items : Epub.Archives.Catalogue) return Book_Plan;
   function Apply (Items : Epub.Archives.Catalogue; Plan : Book_Plan)
      return Epub.Archives.Catalogue;
   function Reason_Name (Reason : Epub.Classification.Layout) return String;
   Invalid_Book : exception;
end Epub.Books;

with Ada.Strings.Unbounded;
with Epub.Classification;
with Epub.Lists;
with Epub.Resources;

package Epub.Conversion is
   type Processing_Status is (Analyzed, What_If, Preserved, Converted, Failed);
   type Options is record
      Analyze_Only, Dry_Run : Boolean := False;
   end record;
   type Book_Result is record
      Book, Output, Error, Input_SHA256, Output_SHA256 : Ada.Strings.Unbounded.Unbounded_String;
      Status : Processing_Status := Failed;
      Reason : Epub.Classification.Layout := Epub.Classification.Horizontal;
      Has_Reason : Boolean := False;
      Changed_Entries : Epub.Resources.String_Lists.Vector;
      Entries_Verified, Input_Bytes, Output_Bytes : Natural := 0;
      Has_Output_Bytes : Boolean := False;
   end record;
   package Result_Lists is new Epub.Lists (Book_Result);
   function Process_Book (Input, Destination : String; Settings : Options) return Book_Result;
   function Status_Name (Status : Processing_Status) return String;
end Epub.Conversion;

with Epub.Conversion;

package Epub.Reports is
   function JSON (Results : Epub.Conversion.Result_Lists.Vector) return String;
   function Quote (Value : String) return String;
   procedure Write_Report (Path, Text : String);
end Epub.Reports;

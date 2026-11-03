package body Epub.Patches with SPARK_Mode is
   function Replace
     (Source : String; Offset, Count : Natural; Replacement : String)
      return String is
      Result : constant String
        (1 .. Source'Length - Count + Replacement'Length) :=
          Source (1 .. Offset) & Replacement
          & Source (Offset + Count + 1 .. Source'Last);
   begin
      return Result;
   end Replace;
end Epub.Patches;

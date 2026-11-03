package Epub.Patches with SPARK_Mode, Pure is
   function Replace
     (Source : String; Offset, Count : Natural; Replacement : String)
      return String
   with Global => null,
     Pre => Source'First = 1 and then Replacement'First = 1
       and then Offset <= Source'Length
       and then Count <= Source'Length - Offset
       and then Source'Length < Natural'Last
       and then Replacement'Length < Natural'Last - Source'Length,
     Post => Replace'Result'First = 1
       and then Replace'Result'Length =
         Source'Length - Count + Replacement'Length
       and then Replace'Result (1 .. Offset) = Source (1 .. Offset)
       and then Replace'Result
         (Offset + 1 .. Offset + Replacement'Length) = Replacement
       and then Replace'Result
         (Offset + Replacement'Length + 1 .. Replace'Result'Last) =
           Source (Offset + Count + 1 .. Source'Last);
end Epub.Patches;

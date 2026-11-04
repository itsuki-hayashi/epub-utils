with Ada.Strings.Unbounded;
with Epub.File_Streams;

package Epub.Temporary_Files is
   function Next_Path (Directory : String) return String;
   procedure Reserve
     (Directory : String; Output : in out Epub.File_Streams.Stream;
      Path : out Ada.Strings.Unbounded.Unbounded_String);
end Epub.Temporary_Files;

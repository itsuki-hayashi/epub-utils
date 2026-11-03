with Ada.Streams.Stream_IO;

package body Test_Files is
   package IO renames Ada.Streams.Stream_IO;
   function Read (Path : String) return String is
      File : IO.File_Type;
   begin
      IO.Open (File, IO.In_File, Path);
      declare
         Bytes : String (1 .. Natural (IO.Size (File)));
      begin
         String'Read (IO.Stream (File), Bytes);
         IO.Close (File);
         return Bytes;
      end;
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise;
   end Read;

   procedure Write (Path, Bytes : String) is
      File : IO.File_Type;
   begin
      IO.Create (File, IO.Out_File, Path);
      String'Write (IO.Stream (File), Bytes);
      IO.Close (File);
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise;
   end Write;
end Test_Files;

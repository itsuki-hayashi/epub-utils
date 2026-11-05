with Ada.Streams.Stream_IO;
package body Oracle_IO is
   function Read (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      return Text : String (1 .. Natural (Ada.Streams.Stream_IO.Size (File))) do
         String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
         Ada.Streams.Stream_IO.Close (File);
      end return;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then Ada.Streams.Stream_IO.Close (File); end if;
         raise;
   end Read;
   function Hex (Text : String) return String is
      Hex_Digits : constant String := "0123456789abcdef";
      Cursor : Natural := 0;
   begin
      return Result : String (1 .. Text'Length * 2) do
         for C of Text loop
            Result (Cursor + 1) := Hex_Digits (Character'Pos (C) / 16 + 1);
            Result (Cursor + 2) := Hex_Digits (Character'Pos (C) mod 16 + 1);
            Cursor := Cursor + 2;
         end loop;
      end return;
   end Hex;
end Oracle_IO;

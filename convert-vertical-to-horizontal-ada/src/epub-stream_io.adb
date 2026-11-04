with Ada.Streams;
with Epub.Digests;

package body Epub.Stream_IO is
   use Ada.Streams;
   use type Zip_Streams.ZS_Size_Type;
   function Digest (Input : in out Zip_Streams.Root_Zipstream_Type'Class) return String is
      Hash : Epub.Digests.Context := Epub.Digests.Initial_Context;
      Buffer : Stream_Element_Array (1 .. 65_536);
      Last : Stream_Element_Offset;
   begin
      if Input.Index /= 1 then
         Input.Set_Index (1);
      end if;
      loop
         Input.Read (Buffer, Last);
         exit when Last < Buffer'First;
         Epub.Digests.Update (Hash, Buffer (Buffer'First .. Last));
      end loop;
      return Epub.Digests.Digest (Hash);
   end Digest;
   procedure Copy (Input, Output : in out Zip_Streams.Root_Zipstream_Type'Class) is
      Buffer : Stream_Element_Array (1 .. 65_536);
      Last : Stream_Element_Offset;
   begin
      if Input.Index /= 1 then
         Input.Set_Index (1);
      end if;
      loop
         Input.Read (Buffer, Last);
         exit when Last < Buffer'First;
         Output.Write (Buffer (Buffer'First .. Last));
      end loop;
   end Copy;
end Epub.Stream_IO;

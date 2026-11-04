with Ada.Finalization;
with Ada.Streams;
with Epub.File_Streams;
with Zip_Streams;

package Epub.Input_Streams is
   --  A single owned copy of a small compressed input, or a file-backed stream
   --  above the caller's budget. Both expose the same read-only interface.
   --  The budget bounds compressed bytes; decoded entries remain short-lived.
   type Stream is new Zip_Streams.Root_Zipstream_Type with private;
   procedure Open
     (Item : in out Stream; Path : String;
      Memory_Limit : Zip_Streams.ZS_Size_Type := 0);
   procedure Close (Item : in out Stream);
   function Is_Open (Item : Stream) return Boolean;
   function Is_Memory_Backed (Item : Stream) return Boolean;
   overriding procedure Read
     (Item : in out Stream; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);
   overriding procedure Write (Item : in out Stream; Buffer : Ada.Streams.Stream_Element_Array);
   overriding procedure Set_Index (Item : in out Stream; To : Zip_Streams.ZS_Index_Type);
   overriding function Index (Item : Stream) return Zip_Streams.ZS_Index_Type;
   overriding function Size (Item : Stream) return Zip_Streams.ZS_Size_Type;
   overriding function End_Of_Stream (Item : Stream) return Boolean;
private
   type String_Access is access String;
   type Buffer_Owner is new Ada.Finalization.Limited_Controlled with record
      Data : String_Access;
   end record;
   overriding procedure Finalize (Item : in out Buffer_Owner);
   type Stream is new Zip_Streams.Root_Zipstream_Type with record
      File : Epub.File_Streams.Stream;
      Memory : Buffer_Owner;
      Length : Zip_Streams.ZS_Size_Type := 0;
      Position : Zip_Streams.ZS_Index_Type := 1;
      Opened : Boolean := False;
   end record;
end Epub.Input_Streams;

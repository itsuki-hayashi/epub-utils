with Ada.Finalization;
with Ada.Streams;
with System;
with Zip_Streams;
with Epub.Native_Files;

package Epub.File_Streams is
   type Stream is new Zip_Streams.Root_Zipstream_Type with private;
   procedure Open
     (Item : in out Stream; Path : String; Exclusive : Boolean := False;
      Outcome : access Epub.Native_Files.Open_Result := null);
   procedure Flush (Item : in out Stream);
   procedure Close (Item : in out Stream);
   function Is_Open (Item : Stream) return Boolean;
   overriding procedure Read
     (Item : in out Stream; Buffer : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);
   overriding procedure Write (Item : in out Stream; Buffer : Ada.Streams.Stream_Element_Array);
   overriding procedure Set_Index (Item : in out Stream; To : Zip_Streams.ZS_Index_Type);
   overriding function Index (Item : Stream) return Zip_Streams.ZS_Index_Type;
   overriding function Size (Item : Stream) return Zip_Streams.ZS_Size_Type;
   overriding function End_Of_Stream (Item : Stream) return Boolean;
   File_Error : exception renames Epub.Native_Files.File_Error;
private
   type Handle_Owner is new Ada.Finalization.Limited_Controlled with record
      Handle : aliased System.Address := System.Null_Address;
   end record;
   overriding procedure Finalize (Owner : in out Handle_Owner);
   type Stream is new Zip_Streams.Root_Zipstream_Type with record
      Owner : Handle_Owner;
      Length : Zip_Streams.ZS_Size_Type := 0;
      Position : Zip_Streams.ZS_Index_Type := 1;
      Writable : Boolean := False;
   end record;
end Epub.File_Streams;

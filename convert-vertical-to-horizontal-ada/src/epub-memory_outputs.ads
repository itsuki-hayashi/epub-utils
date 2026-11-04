with Ada.Finalization;
with Ada.Streams;
with Zip_Streams;

package Epub.Memory_Outputs is
   --  Per-entry compression workspace. Grow only when needed, never beyond
   --  Maximum, and overwrite in bulk when compression falls back to storing.
   --  Seeking does not extend the stream or initialize unused capacity.
   type Stream (Maximum : Natural) is new Zip_Streams.Root_Zipstream_Type with private;
   procedure Copy_To
     (Item : Stream; Target : in out Zip_Streams.Root_Zipstream_Type'Class; Count : Natural);
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
   type Stream (Maximum : Natural) is new Zip_Streams.Root_Zipstream_Type with record
      Memory : Buffer_Owner;
      Length : Natural := 0;
      Position : Zip_Streams.ZS_Index_Type := 1;
   end record;
end Epub.Memory_Outputs;

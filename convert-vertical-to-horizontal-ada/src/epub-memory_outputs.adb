with Ada.IO_Exceptions;
with Ada.Unchecked_Deallocation;

package body Epub.Memory_Outputs is
   use Ada.Streams;
   use type Zip_Streams.ZS_Size_Type;
   pragma Compile_Time_Error (Stream_Element'Size /= Character'Size, "Output byte views require octets");
   procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);
   overriding procedure Finalize (Item : in out Buffer_Owner) is
   begin
      Free (Item.Data);
   end Finalize;

   procedure Exchange (Left, Right : in out String_Access) is
      Saved : constant String_Access := Left;
   begin
      Left := Right;
      Right := Saved;
   end Exchange;

   procedure Reserve (Item : in out Stream; Required : Natural) is
      Old_Capacity : constant Natural := (if Item.Memory.Data = null then 0 else Item.Memory.Data.all'Length);
      New_Capacity : Natural;
      Replacement : Buffer_Owner;
   begin
      if Required <= Old_Capacity then
         return;
      elsif Required > Item.Maximum then
         raise Ada.IO_Exceptions.Use_Error with "Compression buffer exceeds its payload bound";
      end if;
      New_Capacity :=
        (if Old_Capacity = 0 then Natural'Min (Item.Maximum, Natural'Max (32_768, Required))
         else Natural'Max (Required, Old_Capacity + Natural'Min (Old_Capacity, Item.Maximum - Old_Capacity)));
      Replacement.Data := new String (1 .. New_Capacity);
      if Item.Length > 0 then
         Replacement.Data.all (1 .. Item.Length) := Item.Memory.Data.all (1 .. Item.Length);
      end if;
      --  The temporary takes ownership of the old allocation and releases it
      --  on scope exit. It also owns the replacement if copying ever fails.
      Exchange (Item.Memory.Data, Replacement.Data);
   end Reserve;

   overriding procedure Write (Item : in out Stream; Buffer : Stream_Element_Array) is
      First : constant Natural := Natural (Item.Position - 1);
      Count : Natural;
   begin
      if Buffer'Length > Item.Maximum - First then
         raise Ada.IO_Exceptions.Use_Error with "Compression buffer exceeds its payload bound";
      end if;
      Count := Buffer'Length;
      if Count > 0 then
         Reserve (Item, First + Count);
         declare
            View : Stream_Element_Array (1 .. Stream_Element_Offset (Item.Memory.Data.all'Length))
              with Import, Address => Item.Memory.Data.all'Address;
         begin
            View (Stream_Element_Offset (First) + 1 .. Stream_Element_Offset (First + Count)) := Buffer;
         end;
         Item.Position := Item.Position + Zip_Streams.ZS_Size_Type (Count);
         Item.Length := Natural'Max (Item.Length, First + Count);
      end if;
   end Write;

   overriding procedure Read
     (Item : in out Stream; Buffer : out Stream_Element_Array; Last : out Stream_Element_Offset) is
   begin
      Last := Buffer'First - 1;
      if Buffer'Length > 0 and then Item.Position <= Zip_Streams.ZS_Size_Type (Item.Length) then
         declare
            Count : constant Stream_Element_Offset := Stream_Element_Offset
              (Zip_Streams.ZS_Size_Type'Min (Buffer'Length, Zip_Streams.ZS_Size_Type (Item.Length) - Item.Position + 1));
            View : constant Stream_Element_Array (1 .. Stream_Element_Offset (Item.Length))
              with Import, Address => Item.Memory.Data.all'Address;
            First : constant Stream_Element_Offset := Stream_Element_Offset (Item.Position);
         begin
            Last := Buffer'First + (Count - 1);
            Buffer (Buffer'First .. Last) := View (First .. First + (Count - 1));
            Item.Position := Item.Position + Zip_Streams.ZS_Size_Type (Count);
         end;
      end if;
   end Read;

   overriding procedure Set_Index (Item : in out Stream; To : Zip_Streams.ZS_Index_Type) is
   begin
      if To > Zip_Streams.ZS_Size_Type (Item.Length) + 1 then
         raise Ada.IO_Exceptions.Use_Error with "Compression buffer seek exceeds initialized bytes";
      end if;
      Item.Position := To;
   end Set_Index;
   overriding function Index (Item : Stream) return Zip_Streams.ZS_Index_Type is (Item.Position);
   overriding function Size (Item : Stream) return Zip_Streams.ZS_Size_Type is (Zip_Streams.ZS_Size_Type (Item.Length));
   overriding function End_Of_Stream (Item : Stream) return Boolean is (Item.Position > Item.Size);

   procedure Copy_To
     (Item : Stream; Target : in out Zip_Streams.Root_Zipstream_Type'Class; Count : Natural) is
   begin
      if Count > Item.Length then
         raise Ada.IO_Exceptions.Use_Error with "Copied compression bytes exceed initialized output";
      elsif Count > 0 then
         declare
            View : constant Stream_Element_Array (1 .. Stream_Element_Offset (Count))
              with Import, Address => Item.Memory.Data.all'Address;
         begin
            Target.Write (View);
         end;
      end if;
   end Copy_To;
end Epub.Memory_Outputs;

with Ada.IO_Exceptions;
with Ada.Unchecked_Deallocation;

package body Epub.Input_Streams is
   use Ada.Streams;
   use type Zip_Streams.ZS_Size_Type;
   pragma Compile_Time_Error (Stream_Element'Size /= Character'Size, "Input byte views require octets");
   procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);
   overriding procedure Finalize (Item : in out Buffer_Owner) is
   begin
      Free (Item.Data);
   end Finalize;

   procedure Check_Open (Item : Stream) is
   begin
      if not Item.Opened then
         raise Epub.File_Streams.File_Error with "Input stream is closed";
      end if;
   end Check_Open;

   procedure Open
     (Item : in out Stream; Path : String;
      Memory_Limit : Zip_Streams.ZS_Size_Type := 0) is
   begin
      if Item.Opened or else Item.File.Is_Open or else Item.Memory.Data /= null then
         raise Epub.File_Streams.File_Error with "Input stream already owns a source";
      end if;
      Item.File.Open (Path);
      Item.Length := Item.File.Size;
      Item.Position := 1;
      if Item.Length <= Memory_Limit and then Item.Length <= Zip_Streams.ZS_Size_Type (Natural'Last) then
         Item.Memory.Data := new String (1 .. Natural (Item.Length));
         declare
            View : Stream_Element_Array (1 .. Stream_Element_Offset (Item.Length))
              with Import, Address => Item.Memory.Data.all'Address;
            Last : Stream_Element_Offset;
         begin
            --  Read directly into the one allocation; no whole-input staging
            --  string, unbounded-string conversion, or catalogue copy.
            Item.File.Read (View, Last);
            if Last /= View'Last then
               raise Epub.File_Streams.File_Error with "Incomplete input RAM snapshot";
            end if;
         end;
         Item.File.Close;
      end if;
      Item.Set_Name (Path);
      Item.Opened := True;
   end Open;

   procedure Close (Item : in out Stream) is
   begin
      Item.Opened := False;
      Free (Item.Memory.Data);
      Item.File.Close;
      Item.Length := 0;
      Item.Position := 1;
   end Close;
   function Is_Open (Item : Stream) return Boolean is (Item.Opened);
   function Is_Memory_Backed (Item : Stream) return Boolean is (Item.Opened and then Item.Memory.Data /= null);

   overriding procedure Read
     (Item : in out Stream; Buffer : out Stream_Element_Array; Last : out Stream_Element_Offset) is
   begin
      Check_Open (Item);
      if Item.Memory.Data = null then
         Item.File.Read (Buffer, Last);
      else
         Last := Buffer'First - 1;
         if Buffer'Length > 0 and then Item.Position <= Item.Length then
            declare
               Count : constant Stream_Element_Offset := Stream_Element_Offset
                 (Zip_Streams.ZS_Size_Type'Min (Buffer'Length, Item.Length - Item.Position + 1));
               View : Stream_Element_Array (1 .. Stream_Element_Offset (Item.Length))
                 with Import, Address => Item.Memory.Data.all'Address;
               First : constant Stream_Element_Offset := Stream_Element_Offset (Item.Position);
            begin
               Last := Buffer'First + (Count - 1);
               Buffer (Buffer'First .. Last) := View (First .. First + (Count - 1));
               Item.Position := Item.Position + Zip_Streams.ZS_Size_Type (Count);
            end;
         end if;
      end if;
   end Read;
   overriding procedure Write (Item : in out Stream; Buffer : Stream_Element_Array) is
      pragma Unreferenced (Item, Buffer);
   begin
      raise Ada.IO_Exceptions.Mode_Error with "Input stream cannot be written";
   end Write;
   overriding procedure Set_Index (Item : in out Stream; To : Zip_Streams.ZS_Index_Type) is
   begin
      Check_Open (Item);
      if To > Item.Length + 1 then
         raise Ada.IO_Exceptions.Use_Error with "Input seek exceeds source bounds";
      elsif Item.Memory.Data = null then
         Item.File.Set_Index (To);
      else
         Item.Position := To;
      end if;
   end Set_Index;
   overriding function Index (Item : Stream) return Zip_Streams.ZS_Index_Type is
     (if Item.Memory.Data = null then Item.File.Index else Item.Position);
   overriding function Size (Item : Stream) return Zip_Streams.ZS_Size_Type is (Item.Length);
   overriding function End_Of_Stream (Item : Stream) return Boolean is (Item.Index > Item.Length);
end Epub.Input_Streams;

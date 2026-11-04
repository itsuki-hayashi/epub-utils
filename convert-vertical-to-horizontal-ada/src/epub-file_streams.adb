with Ada.Exceptions;
with Epub.Diagnostics;
with Interfaces;
with Epub.Performance;

package body Epub.File_Streams is
   use Ada.Streams;
   use type System.Address;
   use type Zip_Streams.ZS_Size_Type;
   use type Interfaces.Unsigned_64;
   procedure Check_Open (Item : Stream) is
   begin
      if not Is_Open (Item) then
         raise File_Error with "Binary stream is closed";
      end if;
   end Check_Open;
   overriding procedure Finalize (Owner : in out Handle_Owner) is
   begin
      if Owner.Handle /= System.Null_Address then
         Epub.Native_Files.Close (Owner.Handle);
      end if;
   exception
      when Error : others =>
         Epub.Diagnostics.Report ("File cleanup failure: " & Ada.Exceptions.Exception_Message (Error));
   end Finalize;
   procedure Open
     (Item : in out Stream; Path : String; Exclusive : Boolean := False;
      Outcome : access Epub.Native_Files.Open_Result := null) is
   begin
      if Is_Open (Item) then
         raise File_Error with "Binary stream is already open";
      end if;
      Item.Owner.Handle := Epub.Native_Files.Open (Path, Exclusive, Outcome);
      if Outcome /= null and then Outcome.all.Collision then
         return;
      end if;
      begin
         declare
            Length : constant Interfaces.Unsigned_64 := Epub.Native_Files.Size (Item.Owner.Handle);
         begin
            if Length >= Interfaces.Unsigned_64 (Zip_Streams.ZS_Size_Type'Last) then
               raise File_Error with "File exceeds the stream index limit";
            end if;
            Item.Length := Zip_Streams.ZS_Size_Type (Length);
         end;
         Item.Position := 1;
         Item.Writable := Exclusive;
         Item.Set_Name (Path);
      exception
         when others =>
            Epub.Native_Files.Close (Item.Owner.Handle);
            raise;
      end;
   end Open;
   procedure Flush (Item : in out Stream) is
   begin
      Check_Open (Item);
      if Item.Writable then
         Epub.Native_Files.Flush (Item.Owner.Handle);
      end if;
   end Flush;
   procedure Close (Item : in out Stream) is
   begin
      if Is_Open (Item) then
         Epub.Native_Files.Close (Item.Owner.Handle);
      end if;
   end Close;
   function Is_Open (Item : Stream) return Boolean is (Item.Owner.Handle /= System.Null_Address);
   overriding procedure Read
     (Item : in out Stream; Buffer : out Stream_Element_Array; Last : out Stream_Element_Offset) is
      Cursor : Stream_Element_Offset := Buffer'First;
   begin
      Check_Open (Item);
      if Item.Writable then
         raise File_Error with "Binary stream is not readable";
      end if;
      Last := Buffer'First - 1;
      while Cursor <= Buffer'Last and then Item.Position <= Item.Length loop
         declare
            Count : constant Natural := Natural (Zip_Streams.ZS_Size_Type'Min
              (1_048_576, Zip_Streams.ZS_Size_Type'Min
                (Zip_Streams.ZS_Size_Type (Buffer'Last - Cursor + 1), Item.Length - Item.Position + 1)));
            Actual : Natural;
         begin
            Epub.Performance.Start (Epub.Performance.Native_IO);
            Actual := Epub.Native_Files.Read (Item.Owner.Handle, Buffer (Cursor)'Address, Count);
            Epub.Performance.Stop (Epub.Performance.Native_IO);
            Epub.Performance.Add (Epub.Performance.Native_Reads);
            Epub.Performance.Add (Epub.Performance.Bytes_Read, Actual);
            if Actual = 0 or else Actual > Count then
               raise File_Error with "Cannot read the complete binary stream";
            end if;
            Last := Cursor + Stream_Element_Offset (Actual) - 1;
            Item.Position := Item.Position + Zip_Streams.ZS_Size_Type (Actual);
            exit when Last = Buffer'Last;
            Cursor := Last + 1;
         end;
      end loop;
   end Read;
   overriding procedure Write (Item : in out Stream; Buffer : Stream_Element_Array) is
      Cursor : Stream_Element_Offset := Buffer'First;
   begin
      Check_Open (Item);
      if not Item.Writable then
         raise File_Error with "Binary stream is not writable";
      end if;
      while Cursor <= Buffer'Last loop
         declare
            Count : constant Natural := Natural (Stream_Element_Offset'Min
              (1_048_576, Buffer'Last - Cursor + 1));
            Actual : Natural;
         begin
            if Item.Position > Zip_Streams.ZS_Size_Type'Last - Zip_Streams.ZS_Size_Type (Count) then
               raise File_Error with "Binary stream index overflow";
            end if;
            Epub.Performance.Start (Epub.Performance.Native_IO);
            Actual := Epub.Native_Files.Write (Item.Owner.Handle, Buffer (Cursor)'Address, Count);
            Epub.Performance.Stop (Epub.Performance.Native_IO);
            Epub.Performance.Add (Epub.Performance.Native_Writes);
            Epub.Performance.Add (Epub.Performance.Bytes_Written, Actual);
            if Actual = 0 or else Actual > Count then
               raise File_Error with "Cannot write the complete binary stream";
            end if;
            Item.Position := Item.Position + Zip_Streams.ZS_Size_Type (Actual);
            Item.Length := Zip_Streams.ZS_Size_Type'Max (Item.Length, Item.Position - 1);
            exit when Stream_Element_Offset (Actual) = Buffer'Last - Cursor + 1;
            Cursor := Cursor + Stream_Element_Offset (Actual);
         end;
      end loop;
   end Write;
   overriding procedure Set_Index (Item : in out Stream; To : Zip_Streams.ZS_Index_Type) is
   begin
      Check_Open (Item);
      Epub.Performance.Start (Epub.Performance.Native_IO);
      Epub.Native_Files.Seek (Item.Owner.Handle, Interfaces.Unsigned_64 (To - 1));
      Epub.Performance.Stop (Epub.Performance.Native_IO);
      Epub.Performance.Add (Epub.Performance.Native_Seeks);
      Item.Position := To;
   end Set_Index;
   overriding function Index (Item : Stream) return Zip_Streams.ZS_Index_Type is (Item.Position);
   overriding function Size (Item : Stream) return Zip_Streams.ZS_Size_Type is (Item.Length);
   overriding function End_Of_Stream (Item : Stream) return Boolean is (Item.Position > Item.Length);
end Epub.File_Streams;

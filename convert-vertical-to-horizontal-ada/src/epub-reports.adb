with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Epub.Books;
with Epub.Files;
with Epub.Resources;

package body Epub.Reports is
   use Ada.Strings.Unbounded;
   function Number (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   function Quote (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("""");
      Hex : constant String := "0123456789abcdef";
   begin
      for Item of Value loop
         case Item is
            when '"' => Append (Result, "\""");
            when '\' => Append (Result, "\\");
            when Character'Val (8) => Append (Result, "\b");
            when Character'Val (9) => Append (Result, "\t");
            when Character'Val (10) => Append (Result, "\n");
            when Character'Val (12) => Append (Result, "\f");
            when Character'Val (13) => Append (Result, "\r");
            when others =>
               if Character'Pos (Item) < 32 then
                  Append (Result, "\u00" & Hex (Character'Pos (Item) / 16 + 1) &
                    Hex (Character'Pos (Item) mod 16 + 1));
               else
                  Append (Result, Item);
               end if;
         end case;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end Quote;

   function Changes_JSON (Names : Epub.Resources.String_Lists.Vector) return String is
      Sorted : Epub.Resources.String_Lists.Vector := Names;
      Result : Unbounded_String := To_Unbounded_String ("[");
   begin
      for Position in 2 .. Sorted.Last_Index loop
         declare
            Value : constant Unbounded_String := Sorted (Position);
            Cursor : Positive := Position;
         begin
            while Cursor > 1 and then To_String (Sorted (Cursor - 1)) > To_String (Value) loop
               Sorted.Replace_Element (Cursor, Sorted (Cursor - 1));
               Cursor := Cursor - 1;
            end loop;
            Sorted.Replace_Element (Cursor, Value);
         end;
      end loop;
      for Position in 1 .. Sorted.Last_Index loop
         if Position > 1 then
            Append (Result, ", ");
         end if;
         Append (Result, Quote (To_String (Sorted (Position))));
      end loop;
      Append (Result, ']');
      return To_String (Result);
   end Changes_JSON;

   function JSON (Results : Epub.Conversion.Result_Lists.Vector) return String is
      Result : Unbounded_String := To_Unbounded_String ("[" & Character'Val (10));
      First : Boolean := True;
      procedure Field (Key, Value : String; Last : Boolean := False) is
      begin
         Append (Result, "    " & Quote (Key) & ": " & Value &
           (if Last then "" else ",") & Character'Val (10));
      end Field;
   begin
      for Item of Results loop
         if not First then
            Append (Result, "," & Character'Val (10));
         end if;
         First := False;
         Append (Result, "  {" & Character'Val (10));
         Field ("Book", Quote (To_String (Item.Book)));
         Field ("ChangedEntries", Changes_JSON (Item.Changed_Entries));
         Field ("EntriesVerified", Number (Item.Entries_Verified));
         Field ("Error", Quote (To_String (Item.Error)));
         Field ("InputBytes", Number (Item.Input_Bytes));
         Field ("InputSHA256", Quote (To_String (Item.Input_SHA256)));
         Field ("Output", Quote (To_String (Item.Output)));
         Field ("OutputBytes", (if Item.Has_Output_Bytes then Number (Item.Output_Bytes) else "null"));
         Field ("OutputSHA256", Quote (To_String (Item.Output_SHA256)));
         Field ("Reason", Quote ((if Item.Has_Reason then Epub.Books.Reason_Name (Item.Reason) else "")));
         Field ("Status", Quote (Epub.Conversion.Status_Name (Item.Status)), Last => True);
         Append (Result, "  }");
      end loop;
      Append (Result, Character'Val (10) & "]" & Character'Val (10));
      return To_String (Result);
   end JSON;

   procedure Write_Report (Path, Text : String) is
   begin
      if not Epub.Files.Is_Directory (Epub.Files.Parent_Path (Path)) then
         raise Epub.Files.File_Error with "Report directory must already exist";
      end if;
      Epub.Files.Write_Verified (Path, Text);
   end Write_Report;
end Epub.Reports;

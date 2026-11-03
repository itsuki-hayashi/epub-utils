with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Epub.CSS;
with Epub.Encoding;

package body Epub.Resources is
   use Ada.Strings.Unbounded;
   function Space (Value : Character) return Boolean is
     (Value = ' ' or else Value in Character'Val (9) .. Character'Val (13));

   function Contains (Items : String_Lists.Vector; Value : String) return Boolean is
   begin
      for Item of Items loop
         if To_String (Item) = Value then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   procedure Include (Items : in out String_Lists.Vector; Value : String) is
   begin
      if not Contains (Items, Value) then
         Items.Append (To_Unbounded_String (Value));
      end if;
   end Include;

   function Tokens (Value : String) return String_Lists.Vector is
      Result : String_Lists.Vector;
      Position : Integer := Value'First;
   begin
      while Position <= Value'Last loop
         if Space (Value (Position)) then
            Position := Position + 1;
         else
            declare
               Start : constant Integer := Position;
            begin
               while Position <= Value'Last and then not Space (Value (Position)) loop
                  Position := Position + 1;
               end loop;
               Include (Result, Value (Start .. Position - 1));
            end;
         end if;
      end loop;
      return Result;
   end Tokens;

   function Resolve (Base_Path, Reference : String) return String is
      Fragment : constant Natural := Ada.Strings.Fixed.Index (Reference, "#");
      Ref : constant String := Reference
        (Reference'First .. (if Fragment = 0 then Reference'Last else Fragment - 1));
      Lower : constant String := Ada.Characters.Handling.To_Lower (Ref);
      Path : Unbounded_String;
      Segments : String_Lists.Vector;
      Result : Unbounded_String;
      Position : Integer;
      Relative : Boolean := False;

      function Hex (Value : Character) return Integer is
        (case Value is
           when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
           when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
           when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
           when others => -1);
   begin
      if Ada.Strings.Fixed.Index (Ref, "?") /= 0 then
         raise Invalid_Resource with "Unsupported query resource: " & Reference;
      end if;
      if Ref'Length >= 8 and then Lower (Ref'First .. Ref'First + 7) = "https://" then
         declare
            Authority_End : Natural := Ada.Strings.Fixed.Index (Ref, "/", Ref'First + 8);
            Host_First : Integer := Ref'First + 8;
            Host_Last : Integer;
         begin
            if Authority_End = 0 then
               Authority_End := Ref'Last + 1;
            end if;
            Host_Last := Authority_End - 1;
            for Cursor in Host_First .. Host_Last loop
               if Ref (Cursor) = '@' then
                  Host_First := Cursor + 1;
               end if;
            end loop;
            for Cursor in Host_First .. Host_Last loop
               if Ref (Cursor) = ':' then
                  if Cursor = Host_Last then
                     raise Invalid_Resource with "Invalid resource port: " & Reference;
                  end if;
                  for Digit in Cursor + 1 .. Host_Last loop
                     if Ref (Digit) not in '0' .. '9' then
                        raise Invalid_Resource with "Invalid resource port: " & Reference;
                     end if;
                  end loop;
                  Host_Last := Cursor - 1;
                  exit;
               end if;
            end loop;
            if Ref (Host_First .. Host_Last) /= "epub.invalid" then
               raise Invalid_Resource with "Unsupported external resource: " & Reference;
            end if;
            Path := To_Unbounded_String (Ref (Authority_End .. Ref'Last));
         end;
      elsif Ref'Length >= 2 and then Ref (Ref'First .. Ref'First + 1) = "//" then
         return Resolve (Base_Path, "https:" & Ref);
      elsif Ada.Strings.Fixed.Index (Ref, ":") /= 0 then
         raise Invalid_Resource with "Unsupported external resource: " & Reference;
      elsif Ref'Length = 0 then
         Path := To_Unbounded_String ("/" & Base_Path);
      elsif Ref (Ref'First) = '/' then
         Path := To_Unbounded_String (Ref);
      else
         Relative := True;
         declare
            Slash : constant Natural := Ada.Strings.Fixed.Index
              (Base_Path, "/", Going => Ada.Strings.Backward);
         begin
            Path := To_Unbounded_String
              (Base_Path (Base_Path'First .. Slash) & Ref);
         end;
      end if;
      if Relative then
         declare
            Raw : constant String := To_String (Path);
         begin
            Position := Raw'First;
            while Position <= Raw'Last loop
               declare
                  Start : constant Integer := Position;
               begin
                  while Position <= Raw'Last and then Raw (Position) /= '/' loop
                     Position := Position + 1;
                  end loop;
                  declare
                     Segment : constant String := Raw (Start .. Position - 1);
                  begin
                     if Segment = ".." then
                        if not Segments.Is_Empty and then
                          To_String (Segments.Element (Segments.Last_Index)) /= ".."
                        then
                           Segments.Delete_Last;
                        else
                           Segments.Append (To_Unbounded_String (".."));
                        end if;
                     elsif Segment /= "." then
                        Segments.Append (To_Unbounded_String (Segment));
                     end if;
                  end;
                  if Position > Raw'Last and then
                    Raw (Start .. Position - 1) in "." | ".."
                  then
                     Segments.Append (Null_Unbounded_String);
                  end if;
                  Position := Position + 1;
               end;
            end loop;
            if Raw'Length > 0 and then Raw (Raw'Last) = '/' then
               Segments.Append (Null_Unbounded_String);
            end if;
         end;
         for Segment_Index in 1 .. Segments.Last_Index loop
            if Segment_Index > 1 then
               Append (Result, '/');
            end if;
            Append (Result, Segments.Element (Segment_Index));
         end loop;
      else
         Result := Path;
         if Length (Result) > 0 and then Element (Result, 1) = '/' then
            Delete (Result, 1, 1);
         end if;
      end if;
      declare
         Raw : constant String := To_String (Result);
         Decoded : Unbounded_String;
      begin
         Position := Raw'First;
         while Position <= Raw'Last loop
            if Raw (Position) = '%' and then Position + 2 <= Raw'Last
              and then Hex (Raw (Position + 1)) >= 0 and then Hex (Raw (Position + 2)) >= 0
            then
               Append (Decoded, Character'Val
                 (16 * Hex (Raw (Position + 1)) + Hex (Raw (Position + 2))));
               Position := Position + 3;
            else
               Append (Decoded, Raw (Position));
               Position := Position + 1;
            end if;
         end loop;
         return Epub.Encoding.From_UTF8 (To_String (Decoded), Epub.Encoding.UTF8);
      end;
   end Resolve;

   function Without_Comments (Value : String) return String is
      Result : Unbounded_String;
      Position : Integer := Value'First;
   begin
      while Position <= Value'Last loop
         if Position < Value'Last and then Value (Position .. Position + 1) = "/*" then
            declare
               Closing : constant Natural := Ada.Strings.Fixed.Index (Value, "*/", Position + 2);
            begin
               exit when Closing = 0;
               Position := Closing + 2;
            end;
         else
            Append (Result, Value (Position));
            Position := Position + 1;
         end if;
      end loop;
      return To_String (Result);
   end Without_Comments;

   function Imports (Stylesheet : String) return String_Lists.Vector is
      Source : constant String := Without_Comments (Stylesheet);
      Lower : constant String := Ada.Characters.Handling.To_Lower (Source);
      Position : Integer := Source'First;
      Result : String_Lists.Vector;
      procedure Skip_Space is
      begin
         while Position <= Source'Last and then Space (Source (Position)) loop
            Position := Position + 1;
         end loop;
      end Skip_Space;
      function Read_Reference return String is
         Quote : Character := Character'Val (0);
         Start : Integer;
      begin
         Skip_Space;
         if Position <= Source'Last and then Source (Position) in '"' | ''' then
            Quote := Source (Position);
            Position := Position + 1;
         end if;
         Start := Position;
         while Position <= Source'Last loop
            exit when (Quote /= Character'Val (0) and then Source (Position) = Quote)
              or else (Quote = Character'Val (0) and then
                (Space (Source (Position)) or else Source (Position) in ')' | ';'));
            if Source (Position) = '\' and then Position < Source'Last then
               Position := Position + 2;
            else
               Position := Position + 1;
            end if;
         end loop;
         declare
            Value : constant String := Source (Start .. Position - 1);
         begin
            if Quote /= Character'Val (0) and then Position <= Source'Last then
               Position := Position + 1;
            end if;
            return Value;
         end;
      end Read_Reference;
   begin
      while Position <= Source'Last loop
         if Source (Position) in '"' | ''' then
            declare
               Ignored : constant String := Read_Reference;
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         elsif Position + 6 <= Source'Last and then
           Lower (Position .. Position + 6) = "@import"
         then
            Position := Position + 7;
            Skip_Space;
            if Position + 3 <= Source'Last and then Lower (Position .. Position + 3) = "url(" then
               Position := Position + 4;
               Result.Append (To_Unbounded_String (Read_Reference));
            elsif Position <= Source'Last and then Source (Position) in '"' | ''' then
               Result.Append (To_Unbounded_String (Read_Reference));
            end if;
         else
            Position := Position + 1;
         end if;
      end loop;
      return Result;
   end Imports;

   function Uses_Vertical
     (Stylesheet : String; Classes, Ids : String_Lists.Vector) return Boolean is
      Source : constant String := Without_Comments (Stylesheet);
      Position : Integer := Source'First;
      function Identifier (Value : Character) return Boolean is
        (Ada.Characters.Handling.Is_Alphanumeric (Value)
         or else Value in '_' | '-' or else Character'Pos (Value) >= 128);
   begin
      while Position <= Source'Last loop
         declare
            Opening : constant Natural := Ada.Strings.Fixed.Index (Source, "{", Position);
            Closing : Natural;
         begin
            exit when Opening = 0;
            Closing := Ada.Strings.Fixed.Index (Source, "}", Opening + 1);
            exit when Closing = 0;
            declare
               Body_Text : constant String := Source (Opening + 1 .. Closing - 1);
               Selector_Start : Integer := Position;
            begin
               declare
                  Cursor : Integer := Position;
                  Quote : Character := Character'Val (0);
               begin
                  while Cursor < Opening loop
                     if Quote /= Character'Val (0) then
                        if Source (Cursor) = '\' and then Cursor + 1 < Opening then
                           Cursor := Cursor + 1;
                        elsif Source (Cursor) = Quote then
                           Quote := Character'Val (0);
                        end if;
                     elsif Source (Cursor) in '"' | ''' then
                        Quote := Source (Cursor);
                     elsif Source (Cursor) = ';' then
                        Selector_Start := Cursor + 1;
                     end if;
                     Cursor := Cursor + 1;
                  end loop;
               end;
               if Epub.CSS.Convert (Body_Text) /= Body_Text then
                  while Selector_Start < Opening loop
                     declare
                        Comma : constant Natural := Ada.Strings.Fixed.Index
                          (Source (Selector_Start .. Opening - 1), ",");
                        Selector_End : constant Integer :=
                          (if Comma = 0 then Opening - 1 else Comma - 1);
                        Cursor : Integer := Selector_Start;
                        Used : Boolean := True;
                     begin
                        while Cursor <= Selector_End loop
                           if Source (Cursor) in '.' | '#' then
                              declare
                                 Is_Class : constant Boolean := Source (Cursor) = '.';
                                 Start : constant Integer := Cursor + 1;
                              begin
                                 Cursor := Start;
                                 while Cursor <= Selector_End and then Identifier (Source (Cursor)) loop
                                    Cursor := Cursor + 1;
                                 end loop;
                                 if Cursor > Start then
                                    Used := Used and then Contains
                                      ((if Is_Class then Classes else Ids), Source (Start .. Cursor - 1));
                                 end if;
                              end;
                           else
                              Cursor := Cursor + 1;
                           end if;
                        end loop;
                        if Used then
                           return True;
                        end if;
                        Selector_Start := Selector_End + 2;
                     end;
                  end loop;
               end if;
            end;
            Position := Closing + 1;
         end;
      end loop;
      return False;
   end Uses_Vertical;
end Epub.Resources;

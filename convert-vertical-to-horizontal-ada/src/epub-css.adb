with Ada.Characters.Handling;
with Ada.Strings.Unbounded;
with Epub.Patches;
with Epub.Writing_Modes;

package body Epub.CSS is
   function Convert (Text : String) return String is
      use Ada.Strings.Unbounded;
      Source : constant String (1 .. Text'Length) := Text;
      Lower : constant String := Ada.Characters.Handling.To_Lower (Source);
      Result : Unbounded_String;
      Cursor : Integer := Source'First;
      Boundary : Boolean := True;

      function At_Token (Position : Integer; Token : String) return Boolean is
        (Position >= Source'First
         and then Position <= Source'Last - Token'Length + 1
         and then Lower (Position .. Position + Token'Length - 1) = Token);

      function Space (Value : Character) return Boolean is
        (Value = ' ' or else Value in Character'Val (9) .. Character'Val (13));

      procedure Skip_Gap (Position : in out Integer) is
      begin
         loop
            if Position <= Source'Last and then Space (Source (Position)) then
               Position := Position + 1;
            elsif At_Token (Position, "/*") then
               Position := Position + 2;
               while Position <= Source'Last
                 and then not At_Token (Position, "*/")
               loop
                  Position := Position + 1;
               end loop;
               Position := Integer'Min (Position + 2, Source'Last + 1);
            else
               exit;
            end if;
         end loop;
      end Skip_Gap;

      function Property_End (Position : Integer) return Integer is
      begin
         if At_Token (Position, "writing-mode") then
            return Position + 12;
         end if;
         for Prefix in 1 .. 4 loop
            declare
               Vendor : constant String :=
                 (case Prefix is
                    when 1 => "-webkit-", when 2 => "-epub-",
                    when 3 => "-moz-", when 4 => "-ms-");
            begin
               if At_Token (Position, Vendor & "writing-mode") then
                  return Position + Vendor'Length + 12;
               end if;
            end;
         end loop;
         return Position;
      end Property_End;

      function Mode_End (Position : Integer) return Integer is
      begin
         for Mode_Index in 1 .. 6 loop
            declare
               Mode : constant String :=
                 (case Mode_Index is
                    when 1 => "vertical-rl", when 2 => "vertical-lr",
                    when 3 => "sideways-rl", when 4 => "sideways-lr",
                    when 5 => "tb-rl", when 6 => "tb-lr");
            begin
               if At_Token (Position, Mode) then
                  return Position + Mode'Length;
               end if;
            end;
         end loop;
         return Position;
      end Mode_End;
   begin
      while Cursor <= Source'Last loop
         if At_Token (Cursor, "/*") then
            declare
               Start : constant Integer := Cursor;
            begin
               Cursor := Cursor + 2;
               while Cursor <= Source'Last
                 and then not At_Token (Cursor, "*/")
               loop
                  Cursor := Cursor + 1;
               end loop;
               Cursor := Integer'Min (Cursor + 2, Source'Last + 1);
               Append (Result, Source (Start .. Cursor - 1));
            end;
         elsif Source (Cursor) = '"' or else Source (Cursor) = ''' then
            declare
               Start : constant Integer := Cursor;
               Quote : constant Character := Source (Cursor);
            begin
               Cursor := Cursor + 1;
               while Cursor <= Source'Last loop
                  if Source (Cursor) = '\' then
                     Cursor := Integer'Min (Cursor + 2, Source'Last + 1);
                  elsif Source (Cursor) = Quote then
                     Cursor := Cursor + 1;
                     exit;
                  else
                     Cursor := Cursor + 1;
                  end if;
               end loop;
               Append (Result, Source (Start .. Cursor - 1));
               Boundary := False;
            end;
         elsif Boundary then
            declare
               Property_Start : Integer := Cursor;
               Position : Integer;
               Value_Start, Value_End, Value_Tail : Integer;
            begin
               Skip_Gap (Property_Start);
               Position := Property_End (Property_Start);
               if Position > Property_Start then
                  Skip_Gap (Position);
                  if Position <= Source'Last and then Source (Position) = ':' then
                     Position := Position + 1;
                     Skip_Gap (Position);
                     Value_Start := Position;
                     Value_End := Mode_End (Value_Start);
                     Value_Tail := Value_End;
                     Skip_Gap (Value_Tail);
                     if Value_Tail <= Source'Last and then Source (Value_Tail) = '!' then
                        Value_Tail := Value_Tail + 1;
                        Skip_Gap (Value_Tail);
                        if At_Token (Value_Tail, "important") then
                           Value_Tail := Value_Tail + 9;
                           Skip_Gap (Value_Tail);
                        else
                           Value_Tail := Source'First - 1;
                        end if;
                     end if;
                     if Value_End > Value_Start
                       and then Value_Tail >= Source'First
                       and then (Value_Tail > Source'Last
                         or else Source (Value_Tail) = ';' or else Source (Value_Tail) = '}')
                     then
                        declare
                           Segment : constant String (1 .. Value_End - Cursor) :=
                             Source (Cursor .. Value_End - 1);
                           Replacement : constant String := Epub.Writing_Modes.Token
                             (Epub.Writing_Modes.Map
                                (Epub.Writing_Modes.Parse_Lower (Lower (Value_Start .. Value_End - 1)),
                                 Microsoft => At_Token (Property_Start, "-ms-")));
                        begin
                           Append (Result, Epub.Patches.Replace
                             (Segment, Value_Start - Cursor,
                              Value_End - Value_Start, Replacement));
                        end;
                        Cursor := Value_End;
                     else
                        Append (Result, Source (Cursor));
                        Cursor := Cursor + 1;
                     end if;
                  else
                     Append (Result, Source (Cursor));
                     Cursor := Cursor + 1;
                  end if;
               else
                  Append (Result, Source (Cursor));
                  Cursor := Cursor + 1;
               end if;
               Boundary := False;
            end;
         else
            Boundary := Source (Cursor) = ';' or else Source (Cursor) = '{';
            Append (Result, Source (Cursor));
            Cursor := Cursor + 1;
         end if;
      end loop;
      return To_String (Result);
   end Convert;
end Epub.CSS;

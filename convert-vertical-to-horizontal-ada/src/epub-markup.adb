with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with Epub.CSS;

package body Epub.Markup is
   use Ada.Strings.Unbounded;
   type Attribute_Span is record
      Name_First : Positive;
      Name_Last : Natural;
      First : Positive;
      Last : Natural;
   end record;
   type Attribute_Array is array (Positive range <>) of Attribute_Span;
   type Attributes_Access is access Attribute_Array;
   type Attribute_Owner is new Ada.Finalization.Limited_Controlled with record
      Data : Attributes_Access;
      Used : Natural := 0;
   end record;
   overriding procedure Finalize (Item : in out Attribute_Owner);
   overriding procedure Finalize (Item : in out Attribute_Owner) is
      procedure Free is new Ada.Unchecked_Deallocation (Attribute_Array, Attributes_Access);
   begin
      Free (Item.Data);
   end Finalize;
   procedure Append (Item : in out Attribute_Owner; Value : Attribute_Span) is
      procedure Free is new Ada.Unchecked_Deallocation (Attribute_Array, Attributes_Access);
   begin
      if Item.Data = null or else Item.Used = Item.Data.all'Length then
         declare
            Capacity : constant Positive :=
              (if Item.Used = 0 then 8 elsif Item.Used > Natural'Last / 2 then Natural'Last else Item.Used * 2);
            Data : constant Attributes_Access := new Attribute_Array (1 .. Capacity);
         begin
            if Item.Used > 0 then Data.all (1 .. Item.Used) := Item.Data.all (1 .. Item.Used); end if;
            Free (Item.Data);
            Item.Data := Data;
         end;
      end if;
      Item.Used := Item.Used + 1;
      Item.Data.all (Item.Used) := Value;
   end Append;

   function Space (Value : Character) return Boolean is
     (Value = ' ' or else Value in Character'Val (9) .. Character'Val (13));

   function Convert_Attribute_Tag
     (Tag, Local_Name : String; Package_Only : Boolean) return String is
      Attributes : Attribute_Owner;
      Position : Integer := Tag'First + 1;
      Primary_Mode : Boolean := False;
      Result : Unbounded_String;
      Copied : Integer := Tag'First;
   begin
      while Position <= Tag'Last and then not Space (Tag (Position))
        and then Tag (Position) /= '>' and then Tag (Position) /= '/'
      loop
         Position := Position + 1;
      end loop;
      while Position <= Tag'Last loop
         while Position <= Tag'Last and then
           (Space (Tag (Position)) or else Tag (Position) in '/' | '>')
         loop
            Position := Position + 1;
         end loop;
         exit when Position > Tag'Last;
         declare
            Name_Start : constant Integer := Position;
            Name_End, Value_Start : Integer;
            Quote : Character;
         begin
            while Position <= Tag'Last and then not Space (Tag (Position))
              and then Tag (Position) not in '=' | '>' | '/'
            loop
               Position := Position + 1;
            end loop;
            Name_End := Position - 1;
            while Position <= Tag'Last and then Space (Tag (Position)) loop
               Position := Position + 1;
            end loop;
            if Position <= Tag'Last and then Tag (Position) = '=' then
               Position := Position + 1;
               while Position <= Tag'Last and then Space (Tag (Position)) loop
                  Position := Position + 1;
               end loop;
               if Position <= Tag'Last and then Tag (Position) in '"' | ''' then
                  Quote := Tag (Position);
                  Position := Position + 1;
                  Value_Start := Position;
                  while Position <= Tag'Last and then Tag (Position) /= Quote loop
                     Position := Position + 1;
                  end loop;
                  Attributes.Append
                    (Attribute_Span'
                       (Name_First => Name_Start, Name_Last => Name_End,
                        First => Value_Start, Last => Position - 1));
                  Position := Position + 1;
               else
                  Position := Position + 1;
               end if;
            else
               Position := Position + 1;
            end if;
         end;
      end loop;
      if Package_Only and then Local_Name = "meta" then
         for Attr_Position in 1 .. Attributes.Used loop
            declare
               Attr : Attribute_Span renames Attributes.Data.all (Attr_Position);
            begin
            if Ada.Characters.Handling.To_Lower (Tag (Attr.Name_First .. Attr.Name_Last)) = "name" and then
              Ada.Characters.Handling.To_Lower (Tag (Attr.First .. Attr.Last)) =
                "primary-writing-mode"
            then
               Primary_Mode := True;
            end if;
            end;
         end loop;
      end if;
      for Attr_Position in 1 .. Attributes.Used loop
         declare
            Attr : Attribute_Span renames Attributes.Data.all (Attr_Position);
            Name : constant String := Ada.Characters.Handling.To_Lower (Tag (Attr.Name_First .. Attr.Name_Last));
            Value : constant String := Tag (Attr.First .. Attr.Last);
            Lower : constant String := Ada.Characters.Handling.To_Lower (Value);
            Replacement : Unbounded_String := To_Unbounded_String (Value);
         begin
            if Package_Only then
               if Local_Name = "spine" and then Name = "page-progression-direction"
                 and then Lower = "rtl"
               then
                  Replacement := To_Unbounded_String ("ltr");
               elsif Primary_Mode and then Name = "content"
                 and then Lower in "vertical-rl" | "vertical-lr" | "tb-rl" | "tb-lr"
               then
                  Replacement := To_Unbounded_String ("horizontal-tb");
               end if;
            elsif Name = "style" then
               Replacement := To_Unbounded_String (Epub.CSS.Convert (Value));
            elsif Name = "writing-mode" then
               if Lower in "vertical-rl" | "vertical-lr" | "sideways-rl" | "sideways-lr" then
                  Replacement := To_Unbounded_String ("horizontal-tb");
               elsif Lower in "tb-rl" | "tb-lr" then
                  Replacement := To_Unbounded_String ("lr-tb");
               end if;
            end if;
            Append (Result, Tag (Copied .. Attr.First - 1));
            Append (Result, To_String (Replacement));
            Copied := Attr.Last + 1;
         end;
      end loop;
      Append (Result, Tag (Copied .. Tag'Last));
      return To_String (Result);
   end Convert_Attribute_Tag;

   function Transform (Text : String; Package_Only : Boolean) return String is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Text);
      Result : Unbounded_String;
      Position : Integer := Text'First;
   begin
      while Position <= Text'Last loop
         if Position + 3 <= Text'Last and then Text (Position .. Position + 3) = "<!--" then
            declare
               Comment_End : constant Natural :=
                 Ada.Strings.Fixed.Index (Text, "-->", Position + 4);
               After : constant Integer :=
                 (if Comment_End = 0 then Text'Last + 1 else Comment_End + 3);
            begin
               Append (Result, Text (Position .. After - 1));
               Position := After;
            end;
         elsif Text (Position) = '<' and then Position < Text'Last
           and then Lower (Position + 1) in 'a' .. 'z'
         then
            declare
               Start : constant Integer := Position;
               Name_Start : constant Integer := Position + 1;
               Name_End : Integer;
               Quote : Character := Character'Val (0);
            begin
               Position := Name_Start;
               while Position <= Text'Last and then
                 not Space (Text (Position)) and then Text (Position) not in '/' | '>'
               loop
                  Position := Position + 1;
               end loop;
               Name_End := Position - 1;
               while Position <= Text'Last loop
                  if Quote /= Character'Val (0) then
                     if Text (Position) = Quote then
                        Quote := Character'Val (0);
                     end if;
                  elsif Text (Position) in '"' | ''' then
                     Quote := Text (Position);
                  elsif Text (Position) = '>' then
                     exit;
                  end if;
                  Position := Position + 1;
               end loop;
               if Position > Text'Last then
                  Append (Result, Text (Start .. Text'Last));
                  exit;
               end if;
               declare
                  Full_Name : constant String := Lower (Name_Start .. Name_End);
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Full_Name, ":");
                  Local_Name : constant String :=
                    Full_Name ((if Colon = 0 then Full_Name'First else Colon + 1) .. Full_Name'Last);
                  Tag_End : constant Integer := Position;
               begin
                  if not Package_Only and then Local_Name = "script" then
                     declare
                        Closing : constant Natural := Ada.Strings.Fixed.Index
                          (Lower, "</" & Full_Name, Tag_End + 1);
                     begin
                        if Closing = 0 then
                           Append (Result, Text (Start .. Text'Last));
                           exit;
                        end if;
                        Append (Result, Text (Start .. Closing - 1));
                        Position := Closing;
                     end;
                  elsif not Package_Only and then Local_Name = "style" then
                     declare
                        Closing : constant Natural := Ada.Strings.Fixed.Index
                          (Lower, "</" & Full_Name, Tag_End + 1);
                     begin
                        Append (Result, Text (Start .. Tag_End));
                        if Closing = 0 then
                           Append (Result, Text (Tag_End + 1 .. Text'Last));
                           exit;
                        end if;
                        Append (Result, Epub.CSS.Convert (Text (Tag_End + 1 .. Closing - 1)));
                        Position := Closing;
                     end;
                  else
                     Append (Result, Convert_Attribute_Tag
                       (Text (Start .. Tag_End), Local_Name, Package_Only));
                     Position := Tag_End + 1;
                  end if;
               end;
            end;
         else
            Append (Result, Text (Position));
            Position := Position + 1;
         end if;
      end loop;
      return To_String (Result);
   end Transform;

   function Convert (Text : String) return String is (Transform (Text, False));
   function Convert_Package (Text : String) return String is (Transform (Text, True));
end Epub.Markup;

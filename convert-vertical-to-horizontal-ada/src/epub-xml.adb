with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Input_Sources.Strings;
with Sax.Contexts;
with Sax.Readers;
with Sax.Symbols;
with Sax.Utils;
with Unicode.CES.UTF8;
with Epub.Performance;

package body Epub.XML is
   procedure Free_Bytes is new Ada.Unchecked_Deallocation (String, Bytes_Access);
   procedure Free_Facts is new Ada.Unchecked_Deallocation (Fact_Array, Facts_Access);
   procedure Free_Pieces is new Ada.Unchecked_Deallocation (Piece_Array, Pieces_Access);
   overriding procedure Finalize (Item : in out Summary) is
   begin
      Free_Bytes (Item.Bytes); Free_Facts (Item.Facts); Free_Pieces (Item.Pieces);
      Item.Used_Bytes := 0; Item.Used_Facts := 0; Item.Used_Pieces := 0;
   end Finalize;
   function Capacity (Old, Needed : Natural) return Positive is
   begin
      return Positive'Max (Needed, (if Old = 0 then 16 elsif Old > Natural'Last / 2 then Natural'Last else 2 * Old));
   end Capacity;
   function Store (Item : in out Summary; Text : String) return Span is
      First : constant Natural := Item.Used_Bytes + 1;
      Needed : constant Natural := Item.Used_Bytes + Text'Length;
   begin
      if Text'Length = 0 then return (0, 0); end if;
      if Item.Bytes = null or else Needed > Item.Bytes.all'Length then
         declare
            Data : constant Bytes_Access := new String
              (1 .. Capacity ((if Item.Bytes = null then 0 else Item.Bytes.all'Length), Needed));
         begin
            if Item.Used_Bytes > 0 then Data.all (1 .. Item.Used_Bytes) := Item.Bytes.all (1 .. Item.Used_Bytes); end if;
            Free_Bytes (Item.Bytes); Item.Bytes := Data;
         end;
      end if;
      Item.Bytes.all (First .. Needed) := Text;
      Epub.Performance.Add (Epub.Performance.XML_Bytes_Copied, Text'Length);
      Item.Used_Bytes := Needed;
      return (First, Text'Length);
   end Store;
   function Read (Item : Summary; Slice : Span) return String is
   begin
      if Slice.Length = 0 then return ""; end if;
      if Slice.First = 0 or else Slice.First > Item.Used_Bytes
        or else Slice.Length > Item.Used_Bytes - Slice.First + 1
      then raise Program_Error with "Invalid XML summary span"; end if;
      return Result : String (1 .. Slice.Length) do
         Result := Item.Bytes.all (Slice.First .. Slice.First + Slice.Length - 1);
      end return;
   end Read;
   function Add (Item : in out Summary; Value : Fact) return Positive is
   begin
      if Item.Facts = null or else Item.Used_Facts = Item.Facts.all'Length then
         declare
            Data : constant Facts_Access := new Fact_Array
              (1 .. Capacity ((if Item.Facts = null then 0 else Item.Facts.all'Length), Item.Used_Facts + 1));
         begin
            if Item.Used_Facts > 0 then Data.all (1 .. Item.Used_Facts) := Item.Facts.all (1 .. Item.Used_Facts); end if;
            Free_Facts (Item.Facts); Item.Facts := Data;
         end;
      end if;
      Item.Used_Facts := Item.Used_Facts + 1;
      Epub.Performance.Add (Epub.Performance.XML_Facts);
      Item.Facts.all (Item.Used_Facts) := Value;
      return Item.Used_Facts;
   end Add;
   procedure Append_Text (Item : in out Summary; Position : Positive; Text : String) is
      Bytes : constant Span := Store (Item, Text);
      Previous : constant Natural := Item.Facts.all (Position).Text_Tail;
   begin
      if Text'Length = 0 then return; end if;
      if Item.Pieces = null or else Item.Used_Pieces = Item.Pieces.all'Length then
         declare
            Data : constant Pieces_Access := new Piece_Array
              (1 .. Capacity ((if Item.Pieces = null then 0 else Item.Pieces.all'Length), Item.Used_Pieces + 1));
         begin
            if Item.Used_Pieces > 0 then Data.all (1 .. Item.Used_Pieces) := Item.Pieces.all (1 .. Item.Used_Pieces); end if;
            Free_Pieces (Item.Pieces); Item.Pieces := Data;
         end;
      end if;
      Item.Used_Pieces := Item.Used_Pieces + 1;
      Item.Pieces.all (Item.Used_Pieces) := (Bytes, 0);
      if Previous = 0 then Item.Facts.all (Position).Text_Head := Item.Used_Pieces;
      else Item.Pieces.all (Previous).Next := Item.Used_Pieces; end if;
      Item.Facts.all (Position).Text_Tail := Item.Used_Pieces;
   end Append_Text;
   procedure Check (Item : Summary; Position : Positive) is
   begin
      if Position > Item.Used_Facts then raise Constraint_Error with "Invalid XML summary index"; end if;
   end Check;
   function Count (Item : Summary) return Natural is (Item.Used_Facts);
   function Kind (Item : Summary; Position : Positive) return Element_Kind is
   begin Check (Item, Position); return Item.Facts.all (Position).Kind; end Kind;
   function Parent_Kind (Item : Summary; Position : Positive) return Element_Kind is
   begin Check (Item, Position); return Item.Facts.all (Position).Parent; end Parent_Kind;
   function Field_Value (Item : Summary; Position : Positive; Field : Field_Kind) return String is
   begin
      Epub.Performance.Start (Epub.Performance.XML_Summary_Consumption);
      Check (Item, Position);
      return Result : constant String := Read (Item, Item.Facts.all (Position).Values (Field)) do
         Epub.Performance.Stop (Epub.Performance.XML_Summary_Consumption);
      end return;
   end Field_Value;
   function Direct_Text (Item : Summary; Position : Positive) return String is
      Length, Current : Natural := 0;
   begin
      Epub.Performance.Start (Epub.Performance.XML_Summary_Consumption);
      Check (Item, Position);
      Current := Item.Facts.all (Position).Text_Head;
      while Current /= 0 loop
         Length := Length + Item.Pieces.all (Current).Bytes.Length;
         Current := Item.Pieces.all (Current).Next;
      end loop;
      return Result : String (1 .. Length) do
         declare
            Cursor : Positive := 1;
         begin
            Current := Item.Facts.all (Position).Text_Head;
            while Current /= 0 loop
               declare
                  Text : constant String := Read (Item, Item.Pieces.all (Current).Bytes);
               begin
                  Result (Cursor .. Cursor + Text'Length - 1) := Text;
                  Cursor := Cursor + Text'Length;
               end;
               Current := Item.Pieces.all (Current).Next;
            end loop;
         end;
         Epub.Performance.Stop (Epub.Performance.XML_Summary_Consumption);
      end return;
   end Direct_Text;
   function Has_Visible_Text (Item : Summary) return Boolean is (Item.Visible);
   function Has_Image (Item : Summary) return Boolean is (Item.Images);
   function Is_Fixed (Item : Summary) return Boolean is (Item.Fixed);
   function Space (Value : Character) return Boolean is
     (Value = ' ' or else Value in Character'Val (9) .. Character'Val (13));
   function Token (Text, Wanted : String; Fold : Boolean := False) return Boolean is
      Cursor : Integer := Text'First;
   begin
      while Cursor <= Text'Last loop
         if Space (Text (Cursor)) then Cursor := Cursor + 1;
         else
            declare
               First : constant Integer := Cursor;
            begin
               while Cursor <= Text'Last and then not Space (Text (Cursor)) loop Cursor := Cursor + 1; end loop;
               if (if Fold then Ada.Characters.Handling.To_Lower (Text (First .. Cursor - 1))
                   else Text (First .. Cursor - 1)) = Wanted
               then return True; end if;
            end;
         end if;
      end loop;
      return False;
   end Token;
   function Element (Name : String) return Element_Kind is
   begin
      if Name = "rootfile" then return Rootfile;
      elsif Name = "meta" then return Meta;
      elsif Name = "manifest" then return Manifest;
      elsif Name = "item" then return Manifest_Item;
      elsif Name = "spine" then return Spine;
      elsif Name = "itemref" then return Spine_Item;
      elsif Name = "body" then return Body_Element;
      elsif Name = "svg" then return SVG;
      elsif Name = "script" then return Script_Element;
      elsif Name = "style" then return Style_Element;
      elsif Name = "title" then return Title;
      elsif Name = "desc" then return Description;
      elsif Name in "img" | "image" then return Image;
      elsif Name = "link" then return Link;
      else return Other_Element; end if;
   end Element;
   type Inspection is (Container_Mode, Package_Mode, Content_Mode);
   type Frame is record
      Kind : Element_Kind := Other_Element;
      Fact : Natural := 0;
      Active, Excluded : Boolean := False;
   end record;
   type Frame_Array is array (Positive range <>) of Frame;
   type Frames_Access is access Frame_Array;
   procedure Free_Frames is new Ada.Unchecked_Deallocation (Frame_Array, Frames_Access);
   type Summary_Access is access all Summary;
   type Context_Access is access all Sax.Contexts.Parse_Context;
   type Collector is new Sax.Readers.Sax_Reader with record
      Result : Summary_Access;
      Context : Context_Access;
      Mode : Inspection := Content_Mode;
      Stack : Frames_Access;
      Depth : Natural := 0;
   end record;
   overriding procedure Start_Element
     (Handler : in out Collector; NS : Sax.Utils.XML_NS; Local_Name : Sax.Symbols.Symbol;
      Atts : Sax.Readers.Sax_Attribute_List);
   overriding procedure End_Element
     (Handler : in out Collector; NS : Sax.Utils.XML_NS; Local_Name : Sax.Symbols.Symbol);
   overriding procedure Characters (Handler : in out Collector; Ch : String);
   overriding procedure Internal_Entity_Decl (Handler : in out Collector; Name, Value : String);
   overriding procedure External_Entity_Decl (Handler : in out Collector; Name, Public_Id, System_Id : String);
   overriding function Resolve_Entity
     (Handler : Collector; Public_Id, System_Id : String) return Input_Sources.Input_Source_Access;
   function Symbol_Text (Handler : Collector'Class; Symbol : Sax.Symbols.Symbol) return String is
     (Sax.Contexts.Value (Handler.Context.all, Sax.Contexts.Borrow (Handler.Context.all, Symbol)));
   overriding procedure Start_Element
     (Handler : in out Collector; NS : Sax.Utils.XML_NS; Local_Name : Sax.Symbols.Symbol;
      Atts : Sax.Readers.Sax_Attribute_List) is
      pragma Unreferenced (NS);
      K : constant Element_Kind := Element (Symbol_Text (Handler, Local_Name));
      Parent : constant Frame := (if Handler.Depth = 0 then (others => <>) else Handler.Stack.all (Handler.Depth));
      Values : Fields;
      Position : Natural := 0;
      Keep : Boolean :=
        (case Handler.Mode is
           when Container_Mode => K = Rootfile,
           when Package_Mode => K in Meta | Manifest_Item | Spine_Item,
           when Content_Mode => True);
   begin
      Epub.Performance.Start (Epub.Performance.XML_Summary_Construction);
      if Keep then
         for Index in 1 .. Sax.Readers.Get_Length (Atts) loop
            declare
               Name : constant String := Sax.Readers.Get_Qname (Atts, Index);
               Field : Field_Kind := Field_Kind'First;
               Known : Boolean := True;
            begin
               if Name = "full-path" then Field := Full_Path;
               elsif Name = "name" then Field := Epub.XML.Name;
               elsif Name = "property" then Field := Property;
               elsif Name = "content" then Field := Content;
               elsif Name = "properties" then Field := Properties;
               elsif Name = "id" then Field := Id;
               elsif Name = "href" then Field := Href;
               elsif Name = "media-type" then Field := Media_Type;
               elsif Name = "idref" then Field := Idref;
               elsif Name = "class" then Field := Class_Value;
               elsif Name = "rel" then Field := Rel;
               else Known := False; end if;
               if Known and then
                 (case Handler.Mode is
                    when Container_Mode => Field = Full_Path,
                    when Package_Mode => Field not in Class_Value | Rel,
                    when Content_Mode => Field in Id | Class_Value or else (K = Link and then Field in Href | Rel))
               then
                  Values (Field) := Store (Handler.Result.all, Symbol_Text (Handler, Sax.Readers.Get_Value (Atts, Index)));
               end if;
            end;
         end loop;
         if Handler.Mode = Content_Mode then
            Keep := Values (Id).Length > 0 or else Values (Class_Value).Length > 0
              or else (K = Link and then Token (Read (Handler.Result.all, Values (Rel)), "stylesheet", True));
         end if;
         if Keep then Position := Add (Handler.Result.all, (K, Parent.Kind, Values, 0, 0)); end if;
      end if;
      if Handler.Stack = null or else Handler.Depth = Handler.Stack.all'Length then
         declare
            Data : constant Frames_Access := new Frame_Array
              (1 .. Capacity ((if Handler.Stack = null then 0 else Handler.Stack.all'Length), Handler.Depth + 1));
         begin
            if Handler.Depth > 0 then Data.all (1 .. Handler.Depth) := Handler.Stack.all (1 .. Handler.Depth); end if;
            Free_Frames (Handler.Stack); Handler.Stack := Data;
         end;
      end if;
      Handler.Depth := Handler.Depth + 1;
      Handler.Stack.all (Handler.Depth) :=
        (K, (if K = Meta then Position else 0),
         Parent.Active or else K = Body_Element or else (K = SVG and then Handler.Depth = 1),
         Parent.Excluded or else K in Script_Element | Style_Element | Title | Description);
      Handler.Result.all.Images := Handler.Result.all.Images or else K = Image;
      Epub.Performance.Stop (Epub.Performance.XML_Summary_Construction);
   end Start_Element;
   overriding procedure End_Element
     (Handler : in out Collector; NS : Sax.Utils.XML_NS; Local_Name : Sax.Symbols.Symbol) is
      pragma Unreferenced (NS, Local_Name);
   begin
      Epub.Performance.Start (Epub.Performance.XML_Summary_Construction);
      if Handler.Depth = 0 then raise Program_Error with "Unbalanced XML summary stack"; end if;
      Handler.Depth := Handler.Depth - 1;
      Epub.Performance.Stop (Epub.Performance.XML_Summary_Construction);
   end End_Element;
   overriding procedure Characters (Handler : in out Collector; Ch : String) is
   begin
      Epub.Performance.Start (Epub.Performance.XML_Summary_Construction);
      if Handler.Depth > 0 then
         declare
            Current : constant Frame := Handler.Stack.all (Handler.Depth);
         begin
            if Current.Fact > 0 then Append_Text (Handler.Result.all, Current.Fact, Ch); end if;
            if Current.Active and then not Current.Excluded then
               for C of Ch loop Handler.Result.all.Visible := Handler.Result.all.Visible or else not Space (C); end loop;
            end if;
         end;
      end if;
      Epub.Performance.Stop (Epub.Performance.XML_Summary_Construction);
   end Characters;
   overriding procedure Internal_Entity_Decl (Handler : in out Collector; Name, Value : String) is
      pragma Unreferenced (Handler, Name, Value);
   begin raise Invalid_XML with "XML entity declarations require manual review"; end Internal_Entity_Decl;
   overriding procedure External_Entity_Decl (Handler : in out Collector; Name, Public_Id, System_Id : String) is
      pragma Unreferenced (Handler, Name, Public_Id, System_Id);
   begin raise Invalid_XML with "External XML entity declarations are unsupported"; end External_Entity_Decl;
   overriding function Resolve_Entity
     (Handler : Collector; Public_Id, System_Id : String) return Input_Sources.Input_Source_Access is
      pragma Unreferenced (Handler, Public_Id, System_Id);
   begin
      raise Invalid_XML with "External XML resources are unsupported";
      return null;
   end Resolve_Entity;
   procedure Release (Reader : in out Sax.Readers.Sax_Reader'Class) is
      Handler : Collector renames Collector (Reader);
   begin Free_Frames (Handler.Stack); Handler.Depth := 0; end Release;
   function Inspection_Text (Text : String) return String is
      Last : constant Natural := Ada.Strings.Fixed.Index (Text, "?>");
   begin
      if Text'Length >= 5 and then Text (Text'First .. Text'First + 4) = "<?xml" and then Last /= 0 then
         declare
            Position : Natural := Ada.Strings.Fixed.Index (Text (Text'First .. Last), "encoding");
            Quote : Character;
            First : Natural;
         begin
            if Position /= 0 then
               while Position < Last and then Text (Position) /= '"' and then Text (Position) /= ''' loop Position := Position + 1; end loop;
               if Position < Last then
                  Quote := Text (Position); First := Position + 1; Position := First;
                  while Position < Last and then Text (Position) /= Quote loop Position := Position + 1; end loop;
                  return Text (Text'First .. First - 1) & "UTF-8" & Text (Position .. Text'Last);
               end if;
            end if;
         end;
      end if;
      return Text;
   end Inspection_Text;
   procedure Inspect (Text : String; Mode : Inspection; Result : aliased in out Summary) is
      Context : aliased Sax.Contexts.Parse_Context;
      Reader : Sax.Readers.Sax_Reader_Access := new Collector;
      Input : Input_Sources.Strings.String_Input;
   begin
      Epub.Performance.Start (Epub.Performance.XML_Parsing);
      Epub.Performance.Add (Epub.Performance.XML_Contexts);
      Collector (Reader.all).Result := Result'Unchecked_Access;
      Collector (Reader.all).Context := Context'Unchecked_Access;
      Collector (Reader.all).Mode := Mode;
      Reader.all.Set_Feature (Sax.Readers.External_General_Entities_Feature, False);
      Reader.all.Set_Feature (Sax.Readers.External_Parameter_Entities_Feature, False);
      Sax.Contexts.Adopt (Context, Reader, Release'Access);
      Input_Sources.Strings.Open (Inspection_Text (Text), Unicode.CES.UTF8.UTF8_Encoding, Input);
      begin
         Sax.Contexts.Parse (Context, Input);
      exception when others => Input.Close; raise; end;
      Input.Close;
      if Mode = Package_Mode then
         for Position in 1 .. Result.Used_Facts loop
            if (Kind (Result, Position) = Meta and then
                ((Field_Value (Result, Position, Property) = "rendition:layout" and then
                  Ada.Strings.Fixed.Trim (Direct_Text (Result, Position), Ada.Strings.Both) = "pre-paginated")
                 or else (Field_Value (Result, Position, Name) = "fixed-layout" and then Field_Value (Result, Position, Content) = "true")))
              or else (Kind (Result, Position) = Spine_Item and then
                       Token (Field_Value (Result, Position, Properties), "rendition:layout-pre-paginated"))
            then Result.Fixed := True; end if;
         end loop;
      end if;
      Epub.Performance.Stop (Epub.Performance.XML_Parsing);
   end Inspect;
   function Inspect_Container (Text : String) return Summary is
   begin return Result : Summary do Inspect (Text, Container_Mode, Result); end return; end Inspect_Container;
   function Inspect_Package (Text : String) return Summary is
   begin return Result : Summary do Inspect (Text, Package_Mode, Result); end return; end Inspect_Package;
   function Inspect_Content (Text : String) return Summary is
   begin return Result : Summary do Inspect (Text, Content_Mode, Result); end return; end Inspect_Content;
end Epub.XML;

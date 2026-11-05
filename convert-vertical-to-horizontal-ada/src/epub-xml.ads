with Ada.Finalization;

--  SAX inspection results own only plain arrays and UTF-8 bytes. No parser,
--  symbol, callback view or compiler-managed element collection escapes.
package Epub.XML is
   type Element_Kind is
     (Other_Element, Rootfile, Meta, Manifest, Manifest_Item, Spine,
      Spine_Item, Body_Element, SVG, Script_Element, Style_Element, Title,
      Description, Image, Link);
   type Field_Kind is
     (Full_Path, Name, Property, Content, Properties, Id, Href, Media_Type,
      Idref, Class_Value, Rel);
   type Summary is new Ada.Finalization.Limited_Controlled with private;
   function Inspect_Container (Text : String) return Summary;
   function Inspect_Package (Text : String) return Summary;
   function Inspect_Content (Text : String) return Summary;
   function Count (Item : Summary) return Natural;
   function Kind (Item : Summary; Position : Positive) return Element_Kind;
   function Parent_Kind (Item : Summary; Position : Positive) return Element_Kind;
   function Field_Value (Item : Summary; Position : Positive; Field : Field_Kind) return String;
   function Direct_Text (Item : Summary; Position : Positive) return String;
   function Has_Visible_Text (Item : Summary) return Boolean;
   function Has_Image (Item : Summary) return Boolean;
   function Is_Fixed (Item : Summary) return Boolean;
   Invalid_XML : exception;
private
   type Span is record
      First, Length : Natural := 0;
   end record;
   type Fields is array (Field_Kind) of Span;
   type Fact is record
      Kind, Parent : Element_Kind := Other_Element;
      Values : Fields;
      Text_Head, Text_Tail : Natural := 0;
   end record;
   type Fact_Array is array (Positive range <>) of Fact;
   type Facts_Access is access Fact_Array;
   type Bytes_Access is access String;
   type Text_Piece is record
      Bytes : Span;
      Next : Natural := 0;
   end record;
   type Piece_Array is array (Positive range <>) of Text_Piece;
   type Pieces_Access is access Piece_Array;
   type Summary is new Ada.Finalization.Limited_Controlled with record
      Bytes : Bytes_Access;
      Used_Bytes : Natural := 0;
      Facts : Facts_Access;
      Used_Facts : Natural := 0;
      Pieces : Pieces_Access;
      Used_Pieces : Natural := 0;
      Visible, Images, Fixed : Boolean := False;
   end record;
   overriding procedure Finalize (Item : in out Summary);
end Epub.XML;

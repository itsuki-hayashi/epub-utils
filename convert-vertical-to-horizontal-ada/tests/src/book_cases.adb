with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with Epub.Archives;
with Epub.Books;
with Epub.Classification;
with Epub.Encoding;
with Epub.XML;
with Test_Files;

package body Book_Cases is
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;
   use type Epub.Classification.Layout;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Book: " & Item.Kind'Image));
   function Fixture (Filename : String := "vertical CSS variants.epub") return Epub.Archives.Catalogue is
     (Epub.Archives.Read (Test_Files.Read
        ("../../convert-vertical-to-horizontal-perl/t/fixtures/input/" & Filename)));
   function Replace (Text, Before, After : String) return String is
      Position : constant Natural := Ada.Strings.Fixed.Index (Text, Before);
   begin
      if Position = 0 then
         raise Program_Error with "Fixture token not found: " & Before;
      end if;
      return Text (Text'First .. Position - 1) & After & Text (Position + Before'Length .. Text'Last);
   end Replace;
   procedure Set (Items : in out Epub.Archives.Catalogue; Path, Content : String) is
      Position : constant Natural := Epub.Archives.Find (Items, Path);
      Item : Epub.Archives.Member := Items (Position);
   begin
      Item.Payload := To_Unbounded_String (Content);
      Items.Replace_Element (Position, Item);
   end Set;
   function Without (Items : Epub.Archives.Catalogue; Path : String) return Epub.Archives.Catalogue is
      Result : Epub.Archives.Catalogue;
   begin
      for Item of Items loop
         if To_String (Item.Name) /= Path then
            Result.Append (Item);
         end if;
      end loop;
      return Result;
   end Without;
   procedure Reject (Items : Epub.Archives.Catalogue; Expected : String) is
      Rejected : Boolean := False;
      Message : Unbounded_String;
      Actual : Epub.Classification.Layout := Epub.Classification.Horizontal;
   begin
      begin
         declare
            Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
         begin
            Actual := Plan.Reason;
         end;
      exception
         when Error : others =>
            Rejected := True;
            Message := To_Unbounded_String (Ada.Exceptions.Exception_Message (Error));
      end;
      Assert (Rejected, "Expected book rejection, got " & Epub.Books.Reason_Name (Actual));
      Assert (Ada.Strings.Fixed.Index (To_String (Message), Expected) /= 0,
              "Expected diagnostic " & Expected & ", got " & To_String (Message));
   end Reject;
   procedure Reject_XML (Text : String) is
      Rejected : Boolean := False;
      Nodes : Natural := 0;
   begin
      begin
         declare
            Document : constant Epub.XML.Summary := Epub.XML.Inspect_Package (Text);
         begin
            Nodes := Document.Count;
         end;
      exception
         when others => Rejected := True;
      end;
      Assert (Rejected, "Unsafe or malformed XML accepted; nodes=" & Nodes'Image);
   end Reject_XML;

   procedure Image_Book (Images, Texts : Natural; Expected : Epub.Classification.Layout) is
      Items : Epub.Archives.Catalogue;
      Manifest, Spine : Unbounded_String;
   begin
      Items.Append (Epub.Archives.Create_Member ("mimetype", "application/epub+zip"));
      Items.Append (Epub.Archives.Create_Member ("META-INF/container.xml",
        "<container><rootfile full-path='OPS/package.opf'/></container>"));
      for Position in 1 .. Images + Texts loop
         declare
            Id : constant String := "p" & Ada.Strings.Fixed.Trim (Position'Image, Ada.Strings.Both);
            Path : constant String := Id & ".xhtml";
         begin
            Append (Manifest, "<item id='" & Id & "' href='" & Path & "' media-type='application/xhtml+xml'/>");
            Append (Spine, "<itemref idref='" & Id & "'/>");
            Items.Append (Epub.Archives.Create_Member ("OPS/" & Path,
              "<html><body>" & (if Position <= Images then "<img src='image.png'/>"
                else "<p style='writing-mode:vertical-rl'>text</p>") & "</body></html>"));
         end;
      end loop;
      Items.Append (Epub.Archives.Create_Member ("OPS/package.opf",
        "<package><metadata/><manifest>" & To_String (Manifest) & "</manifest><spine>" &
        To_String (Spine) & "</spine></package>"));
      declare
         Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
      begin
         Assert (Plan.Reason = Expected, "Image threshold " & Images'Image & "/" & Texts'Image);
      end;
   end Image_Book;

   overriding procedure Run_Test (Item : in out Unit_Case) is
      Items : Epub.Archives.Catalogue := Fixture;
      Package_Text : constant String := Epub.Archives.Contents (Items, "OPS/package.opf");
   begin
      case Item.Kind is
         when Missing_Resource =>
            Reject (Without (Items, "OPS/styles/main.css"), "Missing manifest resource");
         when Duplicate_Manifest =>
            Set (Items, "OPS/package.opf", Replace (Package_Text, "<manifest>",
              "<manifest><item id='page' href='text/page.xhtml' media-type='application/xhtml+xml'/>"));
            Reject (Items, "Duplicate manifest id");
         when Unknown_And_Empty_Spine =>
            Set (Items, "OPS/package.opf", Replace (Package_Text, "idref=""page""", "idref='missing'"));
            Reject (Items, "Unknown spine idref");
            Set (Items, "OPS/package.opf", Replace (Package_Text, "<itemref idref=""page""/>", ""));
            Reject (Items, "Empty or missing spine");
         when Rootfile_Counts =>
            Set (Items, "META-INF/container.xml", "<container/>");
            Reject (Items, "Multiple or missing package rootfiles");
            Set (Items, "META-INF/container.xml",
              "<container><rootfile full-path='OPS/package.opf'/><rootfile full-path='OPS/package.opf'/></container>");
            Reject (Items, "Multiple or missing package rootfiles");
         when Signature_Guards =>
            for Encrypted in Boolean loop
               declare
                  Modified : Epub.Archives.Catalogue := Items;
               begin
                  Modified.Append (Epub.Archives.Create_Member
                    ((if Encrypted then "META-INF/encryption.xml" else "META-INF/signatures.xml"), "<marker/>"));
                  Reject (Modified, "Signed or encrypted");
               end;
            end loop;
            declare
               Horizontal : Epub.Archives.Catalogue := Fixture ("horizontal English [literal].epub");
            begin
               Horizontal.Append (Epub.Archives.Create_Member ("META-INF/signatures.xml", "<marker/>"));
               declare
                  Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Horizontal);
               begin
                  Assert (Plan.Reason = Epub.Classification.Horizontal, "Signed horizontal book remains preserved");
               end;
            end;
         when Fixed_Layout_Order =>
            Set (Items, "OPS/package.opf", Replace (Package_Text, "</metadata>",
              "<meta name='fixed-layout' content='true'/></metadata>"));
            Items := Without (Items, "OPS/styles/main.css");
            Items.Append (Epub.Archives.Create_Member ("META-INF/encryption.xml", "<marker/>"));
            declare
               Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
            begin
               Assert (Plan.Reason = Epub.Classification.Fixed_Layout, "Fixed layout precedes manifest and modification checks");
            end;
         when Import_Cycles =>
            Set (Items, "OPS/styles/main.css", "@import 'cycle.css';body{writing-mode:vertical-rl}");
            Items.Append (Epub.Archives.Create_Member ("OPS/styles/cycle.css",
              "@import 'main.css';p{writing-mode:vertical-lr}"));
            declare
               Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
            begin
               Assert (Plan.Patches.Last_Index = 3, "Cyclic imports terminate and patch once; count=" & Plan.Patches.Last_Index'Image);
            end;
            Set (Items, "OPS/styles/main.css", "@import 'https://elsewhere.invalid/x.css';");
            Reject (Items, "Unsupported external resource");
         when Nonspine_Editing =>
            Set (Items, "OPS/package.opf", Replace (Package_Text, "</manifest>",
              "<item id='extra' href='text/extra.xhtml' media-type='application/xhtml+xml'/></manifest>"));
            Items.Append (Epub.Archives.Create_Member ("OPS/text/extra.xhtml",
              "<html><body><p style='writing-mode:vertical-rl'>extra</p></body></html>"));
            declare
               Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
               Patched : constant Epub.Archives.Catalogue := Epub.Books.Apply (Items, Plan);
            begin
               Assert (Epub.Archives.Contents (Patched, "OPS/text/extra.xhtml") =
                 "<html><body><p style='writing-mode:horizontal-tb'>extra</p></body></html>", "Supported non-spine markup edited");
            end;
         when Package_Encoding =>
            Set (Items, "OPS/package.opf", Character'Val (255) & Character'Val (254) &
              Epub.Encoding.From_UTF8 (Replace (Package_Text, "encoding=""UTF-8""", "encoding='UTF-16LE'"), Epub.Encoding.UTF16_LE));
            declare
               Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
               Patched : constant Epub.Archives.Catalogue := Epub.Books.Apply (Items, Plan);
               Bytes : constant String := Epub.Archives.Contents (Patched, "OPS/package.opf");
               Decoded : constant String := Epub.Encoding.Text (Epub.Encoding.Decode (Bytes));
            begin
               Assert (Bytes (1 .. 2) = Character'Val (255) & Character'Val (254), "UTF16 package BOM retained");
               Assert (Ada.Strings.Fixed.Index (Decoded, "page-progression-direction='ltr'") /= 0, "UTF16 package progression changed");
               Assert (Ada.Strings.Fixed.Index (Decoded, "encoding='UTF-16LE'") /= 0, "Original declaration retained");
            end;
         when Unsupported_Evidence =>
            Set (Items, "OPS/styles/main.css", "body{writing-mode:horizontal-tb}");
            Set (Items, "OPS/package.opf", Replace (Replace (Package_Text, "</metadata>",
              "<meta name='primary-writing-mode' content='vertical&#45;rl'/></metadata>"),
              "page-progression-direction='rtl'", "page-progression-direction='ltr'"));
            Reject (Items, "no supported direction setting");
         when XML_Entity_Policy =>
            Reject_XML ("<root>");
            Reject_XML ("<!DOCTYPE root [<!ENTITY x 'expansion'>]><root>&x;</root>");
            Reject_XML ("<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///must-not-load'>]><root>&x;</root>");
            Reject_XML ("<!DOCTYPE root [<!ENTITY % x SYSTEM 'file:///must-not-load'>]><root/>");
            declare
               Parsed : constant Epub.XML.Summary := Epub.XML.Inspect_Package
                 ("<!DOCTYPE meta SYSTEM 'file:///must-not-load'><meta>allowed &amp; text</meta>");
            begin
               Assert (Parsed.Count = 1, "External DTD reference does not load a resource");
               Assert (Parsed.Direct_Text (1) = "allowed & text", "Predefined XML entities remain supported");
            end;
         when Image_Thresholds =>
            Image_Book (9, 1, Epub.Classification.Vertical_Text);
            Image_Book (10, 2, Epub.Classification.Image_Dominated);
            Image_Book (10, 3, Epub.Classification.Vertical_Text);
            Image_Book (12, 3, Epub.Classification.Image_Dominated);
      end case;
   end Run_Test;
end Book_Cases;

with AUnit.Assertions;
with Epub.CSS;
with Epub.Encoding;
with Epub.Markup;
with Epub.Resources;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Interfaces;
with Epub.Code_Pages;
with Epub.CP932_Tables;

package body Text_Cases is
   use AUnit.Assertions;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind)
      return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;

   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Text: " & Item.Kind'Image));

   procedure Check_CSS is
   begin
      for Prefix_Index in 0 .. 4 loop
         for Mode_Index in 0 .. 5 loop
            declare
               Prefix : constant String :=
                 (case Prefix_Index is
                    when 0 => "", when 1 => "-webkit-", when 2 => "-epub-",
                    when 3 => "-moz-", when 4 => "-ms-");
               Mode : constant String :=
                 (case Mode_Index is
                    when 0 => "vertical-rl", when 1 => "vertical-lr",
                    when 2 => "sideways-rl", when 3 => "sideways-lr",
                    when 4 => "tb-rl", when 5 => "tb-lr");
               Before : constant String :=
                 "p { /* gap */ " & Prefix & "WRITING-MODE /*x*/: " & Mode & " !important; }";
               Expected : constant String :=
                 "p { /* gap */ " & Prefix & "WRITING-MODE /*x*/: " &
                 (if Prefix_Index = 4 or else Mode_Index >= 4 then "lr-tb" else "horizontal-tb") &
                 " !important; }";
               After : constant String := Epub.CSS.Convert (Before);
            begin
               Assert (After = Expected, "CSS prefix/value matrix: " & Before);
               Assert (Epub.CSS.Convert (After) = After, "CSS idempotence");
            end;
         end loop;
      end loop;
      Assert (Epub.CSS.Convert
        ("p{content:'writing-mode:vertical-rl';--example:writing-mode:vertical-rl}") =
         "p{content:'writing-mode:vertical-rl';--example:writing-mode:vertical-rl}",
         "Quoted strings and custom properties");
   end Check_CSS;

   procedure Check_Markup is
      Before : constant String :=
        "<!--<p style='writing-mode:vertical-rl'/>-->" &
        "<script>var x=""writing-mode:vertical-rl"";</script>" &
        "<p title="" style='writing-mode:vertical-rl' >"" style='writing-mode:vertical-lr'>" &
        "writing-mode:vertical-rl;<svg:text writing-mode='tb-rl'>x</svg:text></p>" &
        "<style>p {writing-mode:sideways-lr}</style>";
      Expected : constant String :=
        "<!--<p style='writing-mode:vertical-rl'/>-->" &
        "<script>var x=""writing-mode:vertical-rl"";</script>" &
        "<p title="" style='writing-mode:vertical-rl' >"" style='writing-mode:horizontal-tb'>" &
        "writing-mode:vertical-rl;<svg:text writing-mode='lr-tb'>x</svg:text></p>" &
        "<style>p {writing-mode:horizontal-tb}</style>";
   begin
      Assert (Epub.Markup.Convert (Before) = Expected,
              "Preserve comments, scripts, prose and quoted delimiters");
      Assert (Epub.Markup.Convert (Expected) = Expected, "Markup idempotence");
   end Check_Markup;

   procedure Check_Encoding is
   begin
      for Kind in Epub.Encoding.Encoding_Kind loop
         declare
            Source : constant String :=
              "@charset """ &
              (case Kind is
                 when Epub.Encoding.UTF8 => "UTF-8",
                 when Epub.Encoding.UTF16_LE => "UTF-16LE",
                 when Epub.Encoding.UTF16_BE => "UTF-16BE",
                 when Epub.Encoding.CP932 => "cp932") &
              """;" & Character'Val (13) & Character'Val (10) &
              "p{writing-mode:vertical-rl}/*" &
              Character'Val (16#E6#) & Character'Val (16#97#) & Character'Val (16#A5#) & "*/";
            Prefix : constant String :=
              (case Kind is
                 when Epub.Encoding.UTF16_LE => Character'Val (255) & Character'Val (254),
                 when Epub.Encoding.UTF16_BE => Character'Val (254) & Character'Val (255),
                 when others => "");
            Bytes : constant String := Prefix & Epub.Encoding.From_UTF8 (Source, Kind);
            Item : constant Epub.Encoding.Payload := Epub.Encoding.Decode (Bytes);
            After : constant String := Epub.CSS.Convert (Source);
         begin
            Assert (Epub.Encoding.Text (Item) = Source, "Decoded content");
            Assert (Epub.Encoding.Encode (Item, Source) = Bytes, "Exact unchanged bytes");
            Assert (Epub.Encoding.Encode (Item, After) =
              Prefix & Epub.Encoding.From_UTF8 (After, Kind), "Edited encoding, BOM and CRLF");
         end;
      end loop;
   end Check_Encoding;

   procedure Check_Invalid_Encoding (Bytes : String) is
      Rejected : Boolean := False;
   begin
      begin
         declare
            Item : constant Epub.Encoding.Payload := Epub.Encoding.Decode (Bytes);
         begin
            Assert (Epub.Encoding.Text (Item)'Length = Natural'Last, "Invalid input accepted");
         end;
      exception
         when Epub.Encoding.Invalid_Encoding =>
            Rejected := True;
      end;
      Assert (Rejected, "Invalid encoding must be rejected");
   end Check_Invalid_Encoding;

   procedure Check_CP932 is
      use type Interfaces.Unsigned_16;
      package Scalars renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
      function Bytes (Value : Natural) return String is
        (if Value <= 255 then "" & Character'Val (Value)
         else Character'Val (Value / 256) & Character'Val (Value mod 256));
   begin
      for Value in 0 .. 65535 loop
         if Value <= 255 or else Value / 256 in 16#81# .. 16#9F# | 16#E0# .. 16#FC# then
            declare
               Expected : constant Interfaces.Unsigned_16 := Epub.CP932_Tables.Decoding (Value);
               Rejected : Boolean := False;
            begin
               begin
                  declare
                     Actual : constant String := Epub.Code_Pages.Decode (Bytes (Value));
                  begin
                     Assert (Expected /= Epub.CP932_Tables.Invalid, "CP932 invalid bytes accepted");
                     Assert (Actual = Scalars.Encode
                       (Wide_Wide_String'(1 => Wide_Wide_Character'Val (Expected))),
                       "CP932 decoding agrees with Windows mapping");
                  end;
               exception
                  when Epub.Encoding.Invalid_Encoding => Rejected := True;
               end;
               Assert (Rejected = (Expected = Epub.CP932_Tables.Invalid), "CP932 decoding rejection");
            end;
         end if;
         if Value not in 16#D800# .. 16#DFFF# | 16#FFFE# .. 16#FFFF# then
            declare
               Expected : constant Interfaces.Unsigned_16 := Epub.CP932_Tables.Encoding (Value);
               Rejected : Boolean := False;
               Text : constant String := Scalars.Encode
                 (Wide_Wide_String'(1 => Wide_Wide_Character'Val (Value)));
            begin
               begin
                  declare
                     Actual : constant String := Epub.Encoding.From_UTF8 (Text, Epub.Encoding.CP932);
                  begin
                     Assert (Expected /= Epub.CP932_Tables.Invalid, "CP932 best-fit substitution accepted");
                     Assert (Actual = Bytes (Natural (Expected)), "CP932 canonical encoding for" & Value'Image);
                  end;
               exception
                  when Epub.Encoding.Invalid_Encoding => Rejected := True;
               end;
               Assert (Rejected = (Expected = Epub.CP932_Tables.Invalid), "CP932 encoding rejection");
            end;
         end if;
      end loop;
   end Check_CP932;

   overriding procedure Run_Test (Item : in out Unit_Case) is
      procedure Check_Reference (Reference, Expected : String) is
      begin
         Assert (Epub.Resources.Resolve ("OPS/package.opf", Reference) = Expected,
           "Reference resolution: " & Reference);
      end Check_Reference;

      procedure Reject_Reference (Reference : String) is
         Rejected : Boolean := False;
      begin
         begin
            declare
               Result : constant String := Epub.Resources.Resolve ("OPS/package.opf", Reference);
            begin
               Assert (False, "Invalid reference accepted: " & Result);
            end;
         exception
            when Epub.Resources.Invalid_Resource | Epub.Encoding.Invalid_Encoding =>
               Rejected := True;
         end;
         Assert (Rejected, "Reference must be rejected");
      end Reject_Reference;
   begin
      case Item.Kind is
         when CP932_Compatibility => Check_CP932;
         when Reference_Matrix =>
            Check_Reference ("https://name:secret@epub.invalid:443/a//b", "a//b");
            Check_Reference ("https://epub.invalid:9000/a", "a");
            Check_Reference ("HTTPS://epub.invalid/a", "a");
            Check_Reference ("https://epub.invalid/a/../b", "a/../b");
            Check_Reference ("https://epub.invalid", "");
            Check_Reference ("//epub.invalid/x/../y", "x/../y");
            Check_Reference ("/x/../y", "x/../y");
            Check_Reference ("a//b", "OPS/a//b");
            Check_Reference ("a///b", "OPS/a///b");
            Check_Reference ("a//../b", "OPS/a/b");
            Check_Reference ("../a/./b/../c", "a/c");
            Check_Reference ("../../x", "../x");
            Check_Reference ("../../../x", "../../x");
            Check_Reference ("a/../../b", "b");
            Check_Reference ("a/", "OPS/a/");
            Check_Reference ("a/.", "OPS/a/");
            Check_Reference ("a/..", "OPS/");
            Check_Reference ("#id", "OPS/package.opf");
            Check_Reference ("%x%0%GG%4A%4a", "OPS/%x%0%GGJJ");
         when Rejected_References =>
            Reject_Reference ("?");
            Reject_Reference ("a?query#fragment");
            Reject_Reference ("https://other.invalid/x");
            Reject_Reference ("https://EPUB.INVALID/x");
            Reject_Reference ("https://epub.invalid:/x");
            Reject_Reference ("https://epub.invalid:foo/x");
            Reject_Reference ("http://epub.invalid/x");
            Reject_Reference ("data:text/css,a");
            Reject_Reference ("%FF");
            Reject_Reference ("%C0%AF");
         when Scanner_Boundaries =>
            declare
               Words : constant Epub.Resources.String_Lists.Vector :=
                 Epub.Resources.Tokens (" " & Character'Val (9) & "a a" &
                   Character'Val (10) & "b " & Character'Val (13));
               Empty : Epub.Resources.String_Lists.Vector;
            begin
               Assert (Words.Last_Index = 2, "Whitespace tokens are unique");
               Assert (Epub.Resources.Tokens ("").Is_Empty, "Empty tokens");
               Assert (Epub.Resources.Imports ("/* unterminated").Is_Empty, "Open comment");
               Assert (Epub.Resources.Imports ("@import nonsense;").Is_Empty, "Unsupported import");
               Assert (Epub.Resources.Imports ("@import url('x.css');").Last_Index = 1,
                 "Quoted URL import");
               Assert (Epub.Resources.Imports ("@import 'unterminated").Last_Index = 1,
                 "Unterminated import follows reference scanner");
               Assert (Epub.Resources.Imports ("p{content:'escaped\''}").Is_Empty,
                 "Escaped quote does not create an import");
               Assert (not Epub.Resources.Uses_Vertical ("p{", Empty, Empty), "Open block");
               Assert (not Epub.Resources.Uses_Vertical ("p{}", Empty, Empty), "Empty rule");
               Assert (Epub.Resources.Uses_Vertical
                 (".unused,p{writing-mode:vertical-rl}", Empty, Empty), "Comma selectors");
               Assert (Epub.Resources.Uses_Vertical
                 ("@import 'x;\'y.css';p{writing-mode:vertical-rl}", Empty, Empty),
                 "Quoted and escaped preamble delimiters");
            end;
         when CSS_Matrix =>
            Check_CSS;
         when Markup_Preservation =>
            Check_Markup;
         when Package_Metadata =>
            Assert (Epub.Markup.Convert_Package
              ("<meta content='vertical-rl' name='primary-writing-mode'/>" &
               "<opf:spine page-progression-direction=""rtl""/>") =
               "<meta content='horizontal-tb' name='primary-writing-mode'/>" &
               "<opf:spine page-progression-direction=""ltr""/>", "Package attribute order and namespace");
         when Resource_References =>
            Assert (Epub.Resources.Resolve ("OPS/package.opf", "../Styles/main%20style.css#fragment") =
              "Styles/main style.css", "Relative path and fragment");
            Assert (Epub.Resources.Resolve ("OPS/package.opf", "text/%E6%97%A5.xhtml") =
              "OPS/text/" & Character'Val (16#E6#) & Character'Val (16#97#) &
              Character'Val (16#A5#) & ".xhtml", "Percent-encoded UTF8");
         when CSS_Imports =>
            declare
               Found : constant Epub.Resources.String_Lists.Vector := Epub.Resources.Imports
                 ("/* @import 'unused.css'; */ @import url(extra.css); @import ""more.css"";" &
                  "p {content:""@import 'example.css'"";}");
            begin
               Assert (Found.Last_Index = 2, "Only real CSS imports");
               Assert (Epub.Resources.Contains (Found, "extra.css"), "Bare url import");
               Assert (Epub.Resources.Contains (Found, "more.css"), "Quoted import");
            end;
         when Active_Selectors =>
            declare
               Classes : Epub.Resources.String_Lists.Vector;
               Ids : Epub.Resources.String_Lists.Vector;
               Rule : constant String := ".vrtl #main {writing-mode:vertical-rl}";
            begin
               Assert (not Epub.Resources.Uses_Vertical (Rule, Classes, Ids), "Unused toolkit");
               Epub.Resources.Include (Classes, "vrtl");
               Assert (not Epub.Resources.Uses_Vertical (Rule, Classes, Ids), "Missing id");
               Epub.Resources.Include (Ids, "main");
               Assert (Epub.Resources.Uses_Vertical (Rule, Classes, Ids), "Used class and id");
            end;
         when Encoding_Roundtrips =>
            Check_Encoding;
         when Encoding_Errors =>
            Check_Invalid_Encoding (Character'Val (16#C0#) & Character'Val (16#AF#));
            Check_Invalid_Encoding ("a" & Character'Val (0));
            Check_Invalid_Encoding (Character'Val (255) & Character'Val (254) & "x");
            Check_Invalid_Encoding ("@charset 'UTF-32';x");
      end case;
   end Run_Test;
end Text_Cases;

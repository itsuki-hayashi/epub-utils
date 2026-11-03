with Ada.Strings.Unbounded;
with AUnit.Assertions;
with Epub.Archives;
with Epub.Books;
with Epub.Conversion;
with Epub.Reports;
with Epub.Resources;
with Test_JSON;
with Test_Files;

package body Report_Cases is
   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   package Values renames Test_JSON.Values;
   package Parsers renames Test_JSON.Parsers;
   use type Values.Value_Kind;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Report: " & Item.Kind'Image));

   procedure Check_Manifest is
      Root : constant String := "../../convert-vertical-to-horizontal-perl/t/fixtures/";
      Parser : Parsers.Parser := Parsers.Create (Test_Files.Read (Root & "manifest.json"));
      Manifest : constant Values.JSON_Value := Parser.Parse;
   begin
      Assert (Manifest.Length = 21, "All reference fixtures listed");
      for Position in 1 .. Manifest.Length loop
         declare
            Expected : constant Values.JSON_Value := Manifest.Get (Position);
            Filename : constant String := Expected.Get ("Book").Value;
            Expected_Changes : constant Values.JSON_Value := Expected.Get ("ChangedEntries");
            Archive : constant Epub.Archives.Catalogue := Epub.Archives.Read
              (Test_Files.Read (Root & "input/" & Filename));
            Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Archive);
         begin
            Assert (Epub.Books.Reason_Name (Plan.Reason) = Expected.Get ("Reason").Value,
              "Manifest classification: " & Filename);
            Assert (Plan.Patches.Last_Index = Expected_Changes.Length,
              "Manifest change count: " & Filename);
            for Change_Position in 1 .. Expected_Changes.Length loop
               declare
                  Found : Boolean := False;
                  Expected_Name : constant String := Expected_Changes.Get (Change_Position).Value;
               begin
                  for Change of Plan.Patches loop
                     Found := Found or else To_String (Change.Name) = Expected_Name;
                  end loop;
                  Assert (Found, "Manifest changed resource: " & Expected_Name);
               end;
            end loop;
         end;
      end loop;
   end Check_Manifest;

   procedure Check_Report is
      Results : Epub.Conversion.Result_Lists.Vector;
      Result : Epub.Conversion.Book_Result;
   begin
      Result.Book := To_Unbounded_String ("quoted ""book"".epub");
      Epub.Resources.Include (Result.Changed_Entries, "z.css");
      Epub.Resources.Include (Result.Changed_Entries, "a.css");
      Epub.Resources.Include (Result.Changed_Entries, "b.css");
      Results.Append (Result);
      Result.Has_Reason := True;
      Result.Has_Output_Bytes := True;
      Result.Output_Bytes := 123;
      Result.Status := Epub.Conversion.Converted;
      Results.Append (Result);
      declare
         Parser : Parsers.Parser := Parsers.Create (Epub.Reports.JSON (Results));
         Parsed : constant Values.JSON_Value := Parser.Parse;
         First : constant Values.JSON_Value := Parsed.Get (1);
         Second : constant Values.JSON_Value := Parsed.Get (2);
      begin
         Assert (First.Length = 11, "Report field count");
         Assert (First.Get ("Book").Value = To_String (Result.Book), "Quoted report path");
         Assert (First.Get ("OutputBytes").Kind = Values.Null_Kind, "Unknown output size is null");
         Assert (First.Get ("Reason").Value = "", "Unknown reason is empty");
         Assert (Second.Get ("Reason").Value = "Horizontal", "Known classification");
         Assert (Long_Long_Integer'(Second.Get ("OutputBytes").Value) = 123, "Known output size");
         Assert (First.Get ("ChangedEntries").Get (1).Value = "a.css", "Changes sorted");
         Assert (To_String (Result.Changed_Entries (1)) = "z.css", "Sorting leaves source untouched");
      end;
      declare
         Empty : Epub.Conversion.Result_Lists.Vector;
         Parser : Parsers.Parser := Parsers.Create (Epub.Reports.JSON (Empty));
      begin
         Assert (Parser.Parse.Length = 0, "Empty report parses");
      end;
   end Check_Report;

   overriding procedure Run_Test (Item : in out Unit_Case) is
   begin
      case Item.Kind is
         when Fixture_Manifest => Check_Manifest;
         when Report_Schema => Check_Report;
         when JSON_Escapes =>
            declare
               Source : constant String := Character'Val (16#F0#) & Character'Val (16#9F#) &
                 Character'Val (16#98#) & Character'Val (16#80#);
            begin
               Assert (Epub.Reports.Quote (Source) = '"' & Source & '"',
                 "UTF-8 supplementary character preservation");
            end;
            --  JSON 6.0.0's unescaper rejects DEL and some UTF-8 bytes. Check
            --  their required byte representation here; CLI integration also
            --  parses Unicode reports with PowerShell's independent parser.
            Assert (Epub.Reports.Quote ([1 => Character'Val (127)]) =
              '"' & Character'Val (127) & '"', "DEL is a valid raw JSON character");
            Assert (Epub.Reports.Quote ([1 => Character'Val (0)]) = """\u0000""", "NUL escape");
            Assert (Epub.Reports.Quote ([1 => Character'Val (11)]) = """\u000b""", "Vertical tab escape");
            Assert (Epub.Reports.Quote ([1 => Character'Val (31)]) = """\u001f""", "Unit separator escape");
            for Code in 0 .. 127 loop
               if Code in 32 .. 126 | 8 .. 10 | 12 .. 13 then
                  declare
                     Source : constant String := [1 => Character'Val (Code)];
                     Parser : Parsers.Parser := Parsers.Create (Epub.Reports.Quote (Source));
                  begin
                     Assert (Parser.Parse.Value = Source, "JSON character round trip" & Code'Image);
                  end;
               end if;
            end loop;
      end case;
   end Run_Test;
end Report_Cases;

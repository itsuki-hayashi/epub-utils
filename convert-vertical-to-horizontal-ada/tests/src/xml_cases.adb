with AUnit.Assertions;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Epub.CPUs;
with Epub.Resources;
with Epub.XML;
with Input_Sources.Strings;
with Sax.Contexts;
with Sax.Readers;
with Sax.Symbols;
with Sax.Utils;
with Unicode.CES.UTF8;

package body XML_Cases is
   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Epub.XML.Element_Kind;
   use type Sax.Readers.Sax_Reader_Access;
   use type Sax.Symbols.Symbol;
   use type Sax.Utils.XML_NS;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("XML: " & Item.Kind'Image));
   protected type Barrier (Expected : Positive) is
      procedure Arrive;
      entry Wait_All;
   private
      Count : Natural := 0;
   end Barrier;
   protected body Barrier is
      procedure Arrive is begin Count := Count + 1; end Arrive;
      entry Wait_All when Count = Expected is begin null; end Wait_All;
   end Barrier;
   type Context_Access is access all Sax.Contexts.Parse_Context;
   type Handle_Access is access all Sax.Contexts.Symbol_Handle;
   type Barrier_Access is access all Barrier;
   type Capture is new Sax.Readers.Sax_Reader with record
      Context : Context_Access;
      Saved : Handle_Access;
      Saved_Namespace, Saved_Value : Handle_Access;
      Gate : Barrier_Access;
      Reenter, Reentry_Rejected : Boolean := False;
      Foreign_Symbol : Sax.Symbols.Symbol := Sax.Symbols.No_Symbol;
      Foreign_Rejected : Boolean := False;
   end record;
   overriding procedure Start_Element
     (Handler : in out Capture; NS : Sax.Utils.XML_NS; Local_Name : Sax.Symbols.Symbol;
      Atts : Sax.Readers.Sax_Attribute_List);
   overriding procedure Start_Element
     (Handler : in out Capture; NS : Sax.Utils.XML_NS; Local_Name : Sax.Symbols.Symbol;
      Atts : Sax.Readers.Sax_Attribute_List) is
   begin
      Handler.Saved.all := Sax.Contexts.Borrow (Handler.Context.all, Local_Name);
      if Handler.Foreign_Symbol /= Sax.Symbols.No_Symbol then
         begin
            declare
               Ignored : constant Sax.Contexts.Symbol_Handle :=
                 Sax.Contexts.Borrow (Handler.Context.all, Handler.Foreign_Symbol);
               pragma Unreferenced (Ignored);
            begin null; end;
         exception when Program_Error => Handler.Foreign_Rejected := True; end;
      end if;
      if Handler.Gate /= null then
         Handler.Gate.all.Arrive;
         Handler.Gate.all.Wait_All;
      end if;
      if Handler.Saved_Namespace /= null and then NS /= Sax.Utils.No_XML_NS then
         Handler.Saved_Namespace.all := Sax.Contexts.Borrow (Handler.Context.all, Sax.Utils.Get_URI (NS));
      end if;
      if Handler.Saved_Value /= null then
         for Position in 1 .. Sax.Readers.Get_Length (Atts) loop
            if Sax.Readers.Get_Qname (Atts, Position) = "id" then
               Handler.Saved_Value.all := Sax.Contexts.Borrow (Handler.Context.all, Sax.Readers.Get_Value (Atts, Position));
            end if;
         end loop;
      end if;
      if Handler.Reenter then
         declare
            Input : Input_Sources.Strings.String_Input;
         begin
            Input_Sources.Strings.Open ("<nested/>", Unicode.CES.UTF8.UTF8_Encoding, Input);
            begin
               Handler.Context.all.Parse (Input);
            exception when Program_Error => Handler.Reentry_Rejected := True; end;
            Input.Close;
         end;
      end if;
   end Start_Element;
   procedure Parse (Context : in out Sax.Contexts.Parse_Context; Text : String) is
      Input : Input_Sources.Strings.String_Input;
   begin
      Input_Sources.Strings.Open (Text, Unicode.CES.UTF8.UTF8_Encoding, Input);
      begin
         Context.Parse (Input);
         Assert (Input.Eof, "Parser consumes the complete input");
      exception when others => Input.Close; raise; end;
      Input.Close;
      Assert (Input.Eof, "Closed input retains no readable buffer");
   end Parse;
   procedure Lifetimes is
      Context, Foreign : aliased Sax.Contexts.Parse_Context;
      Saved : aliased Sax.Contexts.Symbol_Handle;
      Reader : Sax.Readers.Sax_Reader_Access := new Capture;
      type Capture_Access is access all Capture;
      Observer : constant Capture_Access := Capture_Access (Reader);
      Rejected, Wrong_Task, Wrong_Table_Task : Boolean := False;
      Other_Table : aliased Sax.Symbols.Symbol_Table_Record;
   begin
      Capture (Reader.all).Context := Context'Unchecked_Access;
      Capture (Reader.all).Saved := Saved'Unchecked_Access;
      Capture (Reader.all).Reenter := True;
      Capture (Reader.all).Foreign_Symbol := Sax.Symbols.Find (Other_Table'Access, "foreign");
      Context.Adopt (Reader);
      Assert (Reader = null, "Context adopts and owns its parser");
      Parse (Context, "<first/>");
      Assert (Context.Value (Saved) = "first" and then Observer.all.Reentry_Rejected,
              "Symbol remains valid until reset; recursive parse is rejected");
      Assert (Observer.all.Foreign_Rejected, "Callback cannot capture a raw symbol from another table");
      begin
         declare
            Ignored : constant String := Foreign.Value (Saved);
            pragma Unreferenced (Ignored);
         begin null; end;
      exception when Program_Error => Rejected := True; end;
      Assert (Rejected, "Foreign context rejects an otherwise valid symbol");
      declare
         task Stranger;
         task body Stranger is
         begin
            begin Context.Reset;
            exception when Program_Error => Wrong_Task := True; end;
            begin
               declare
                  Ignored : constant Sax.Symbols.Symbol := Sax.Symbols.Find (Other_Table'Unchecked_Access, "");
                  pragma Unreferenced (Ignored);
               begin null; end;
            exception when Program_Error => Wrong_Table_Task := True; end;
         end Stranger;
      begin null; end;
      Assert (Wrong_Task and then Context.Value (Saved) = "first", "Wrong task cannot reset or mutate the owner context");
      Assert (Wrong_Table_Task, "Even empty-symbol lookup checks table ownership");
      Context.Reset;
      Rejected := False;
      begin
         declare
            Ignored : constant String := Context.Value (Saved);
            pragma Unreferenced (Ignored);
         begin null; end;
      exception when Program_Error => Rejected := True; end;
      Assert (Rejected, "Reset invalidates borrowed handles before memory access");
      Parse (Context, "<second/>");
      Assert (Context.Value (Saved) = "second", "Reset parser remains usable");
      begin Parse (Context, "<broken>");
      exception when others => null; end;
      Context.Reset;
      Parse (Context, "<recovered/>");
      Assert (Context.Value (Saved) = "recovered", "A malformed document does not poison subsequent parsing");
      Context.Close;
      Context.Close;
      Rejected := False;
      begin
         declare
            Ignored : constant String := Context.Value (Saved);
            pragma Unreferenced (Ignored);
         begin null; end;
      exception when Program_Error => Rejected := True; end;
      Assert (Rejected, "Closed context rejects handle access");
      Sax.Symbols.Free (Other_Table);
      declare
         Table : Sax.Symbols.Symbol_Table_Access := new Sax.Symbols.Symbol_Table_Record;
         Stale : constant Sax.Symbols.Symbol := Sax.Symbols.Find (Table, "stale");
      begin
         Sax.Symbols.Destroy (Table);
         for Iteration in 1 .. 100 loop
            Table := new Sax.Symbols.Symbol_Table_Record;
            Assert (not Sax.Symbols.Owned_By (Table, Stale), "Reused storage cannot revive a stale raw symbol");
            Sax.Symbols.Destroy (Table);
         end loop;
      end;
   end Lifetimes;
   procedure Concurrent is
      Topology : constant Epub.CPUs.Topology := Epub.CPUs.Discover;
      Workers : constant Positive := Positive'Max (1, Natural'Min (16, Topology.Cores.Last_Index));
      Gate : aliased Barrier (Workers);
      protected Results is
         procedure Finish (Valid : Boolean);
         function Passed return Boolean;
      private
         Done : Natural := 0;
         Good : Boolean := True;
      end Results;
      protected body Results is
         procedure Finish (Valid : Boolean) is begin Good := Good and Valid; Done := Done + 1; end Finish;
         function Passed return Boolean is (Good and then Done = Workers);
      end Results;
      task type Parser is
         entry Begin_Parsing (Number : Positive);
      end Parser;
      task body Parser is
         Ordinal : Positive := 1;
      begin
         accept Begin_Parsing (Number : Positive) do Ordinal := Number; end Begin_Parsing;
         declare
         Context : aliased Sax.Contexts.Parse_Context;
         Saved, Namespace_Value, Attribute_Value : aliased Sax.Contexts.Symbol_Handle;
         Reader : Sax.Readers.Sax_Reader_Access := new Capture;
         Root : constant String := "worker" & Ada.Strings.Fixed.Trim (Ordinal'Image, Ada.Strings.Both);
      begin
         Capture (Reader.all).Context := Context'Unchecked_Access;
         Capture (Reader.all).Saved := Saved'Unchecked_Access;
         Capture (Reader.all).Saved_Namespace := Namespace_Value'Unchecked_Access;
         Capture (Reader.all).Saved_Value := Attribute_Value'Unchecked_Access;
         Capture (Reader.all).Gate := Gate'Unchecked_Access;
         Context.Adopt (Reader);
         Parse (Context, "<p:shared xmlns:p='urn:" & Root & "' id='" & Root & "'/>");
         declare
            Valid : Boolean := Context.Value (Saved) = "shared" and then
              Context.Value (Namespace_Value) = "urn:" & Root and then Context.Value (Attribute_Value) = Root;
         begin
            for Iteration in 1 .. 40 loop
               declare
                  Info : constant Epub.XML.Summary := Epub.XML.Inspect_Content
                    ("<html><body><p id='" & Root & "' class='same same'>" & Root & "</p></body></html>");
               begin
                  Valid := Valid and then Info.Has_Visible_Text and then Info.Count = 1
                    and then Info.Field_Value (1, Epub.XML.Id) = Root;
               end;
            end loop;
            Results.Finish (Valid);
         end;
         exception when others => Results.Finish (False); end;
      end Parser;
      procedure Start is
         Tasks : array (Positive range 1 .. Workers) of Parser;
      begin
         for Index in Tasks'Range loop Tasks (Index).Begin_Parsing (Index); end loop;
      end Start;
   begin
      Start;
      Assert (Results.Passed, "Every parser overlaps inside a callback and retains its own symbols and facts");
   end Concurrent;
   overriding procedure Run_Test (Item : in out Unit_Case) is
   begin
      case Item.Kind is
         when Summary_Semantics =>
            declare
               Package_Info : constant Epub.XML.Summary := Epub.XML.Inspect_Package
                 ("<p:package xmlns:p='urn:p'><metadata><meta property='rendition:layout'>pre-<b>ignored</b>paginated</meta></metadata>"
                  & "<manifest><item id='a' href='path.xhtml'/></manifest><spine><itemref idref='a'/></spine></p:package>");
               Content_Info : constant Epub.XML.Summary := Epub.XML.Inspect_Content
                 ("<html><head><title>ignored</title></head><body><script>ignored</script>"
                  & "<p class='a a b' id='one'>a<![CDATA[b]]>&amp;c</p><link rel='alternate STYLESHEET' href='main.css'/></body></html>");
               Invisible : constant Epub.XML.Summary := Epub.XML.Inspect_Content
                 ("<svg><title>ignored</title><desc>ignored</desc><image/></svg>");
            begin
               Assert (Package_Info.Is_Fixed and then Package_Info.Direct_Text (1) = "pre-paginated",
                       "Direct metadata text excludes child text and joins callback fragments");
               Assert (Package_Info.Parent_Kind (2) = Epub.XML.Manifest
                       and then Package_Info.Field_Value (2, Epub.XML.Href) = "path.xhtml"
                       and then Package_Info.Field_Value (2, Epub.XML.Href)'First = 1, "Parent kinds and one-based value results");
               Assert (Content_Info.Has_Visible_Text and then Content_Info.Count = 2, "Content facts retain relevant nodes in order");
               Assert (Invisible.Has_Image and then not Invisible.Has_Visible_Text, "Accessible image titles do not become visible text");
            end;
         when Context_Lifetimes => Lifetimes;
         when Concurrent_Isolation => Concurrent;
         when Large_Inputs =>
            declare
               Text : constant String (1 .. 65_537) := [others => 'x'];
               Info : constant Epub.XML.Summary := Epub.XML.Inspect_Package
                 ("<package><meta property='other' name='large'>" & Text & "</meta></package>");
               Source : Unbounded_String;
            begin
               Assert (Info.Direct_Text (1) = Text, "Text spans survive parser refills and arena growth");
               for Depth in 1 .. 1_000 loop Append (Source, "<body>"); end loop;
               Append (Source, "text");
               for Depth in 1 .. 1_000 loop Append (Source, "</body>"); end loop;
               declare
                  Deep : constant Epub.XML.Summary := Epub.XML.Inspect_Content (To_String (Source));
               begin Assert (Deep.Has_Visible_Text and then Deep.Count = 0, "Deep input needs no full XML tree"); end;
            end;
         when Token_Queries =>
            declare
               Count : Natural := 0;
               procedure Visit (Value : String) is
               begin Assert (Value in "a" | "b", "Token bytes preserved"); Count := Count + 1; end Visit;
               procedure Query is new Epub.Resources.Query_Tokens (Visit);
            begin
               Query (" a a" & Character'Val (9) & "b ");
               Assert (Count = 3, "Scoped token visits avoid temporary controlled lists");
            end;
      end case;
   end Run_Test;
end XML_Cases;

with Epub.Performance;
with Ada.Characters.Handling;
with Epub.Encoding;
with Epub.Markup;
with Epub.Resources;
with Epub.CSS;
with Epub.XML;
with Epub.Name_Indexes;

package body Epub.Books is
   use Ada.Strings.Unbounded;
   use type Epub.Classification.Layout;
   type Manifest_Item is record
      Id, Path, Media : Unbounded_String;
   end record;
   package Manifest_Lists is new Epub.Lists (Manifest_Item);
   function Is_Markup (Media : String) return Boolean is
     (Media in "application/xhtml+xml" | "image/svg+xml" | "text/html");
   function Vertical_Mode (Value : String) return Boolean is
     (Ada.Characters.Handling.To_Lower (Value) in
        "vertical-rl" | "vertical-lr" | "tb-rl" | "tb-lr");
   use type Epub.XML.Element_Kind;
   function Get (Document : Epub.XML.Summary; Position : Positive; Field : Epub.XML.Field_Kind)
      return String renames Epub.XML.Field_Value;

   function Analyze_Book (Items : Epub.Archives.Catalogue) return Book_Plan is
      Result : Book_Plan;
      Container : constant Epub.XML.Summary := Epub.XML.Inspect_Container
        (Epub.Encoding.Text (Epub.Encoding.Decode (Epub.Archives.Contents (Items, "META-INF/container.xml"))));
      Package_Path : Unbounded_String;
      Root_Count : Natural := 0;
      Manifest : Manifest_Lists.Vector;
      Manifest_Ids : Epub.Name_Indexes.Index;
      Classes, Ids, Styles, Visited_Documents, Visited_Styles : Epub.Resources.String_Lists.Vector;
      Images, Texts : Epub.Classification.Page_Count := 0;
      Inline_Vertical, Primary_Vertical, Active_Vertical : Boolean := False;
      Spine_Count : Natural := 0;

      procedure Patch (Path : String; Is_Package : Boolean := False; Is_CSS : Boolean := False) is
         Payload : constant Epub.Encoding.Payload := Epub.Encoding.Decode (Epub.Archives.Contents (Items, Path));
         Before : constant String := Epub.Encoding.Text (Payload);
         After : constant String :=
           (if Is_Package then Epub.Markup.Convert_Package (Before)
            elsif Is_CSS then Epub.CSS.Convert (Before)
            else Epub.Markup.Convert (Before));
      begin
         if After /= Before then
            for Existing of Result.Patches loop
               if To_String (Existing.Name) = Path then
                  return;
               end if;
            end loop;
            Result.Patches.Append
              (Resource_Patch'(Name => To_Unbounded_String (Path),
                Payload => To_Unbounded_String (Epub.Encoding.Encode (Payload, After))));
         end if;
      end Patch;
   begin
      Epub.Performance.Start (Epub.Performance.Analysis);
      for Position in 1 .. Container.Count loop
         if Container.Kind (Position) = Epub.XML.Rootfile then
            Root_Count := Root_Count + 1;
            Package_Path := To_Unbounded_String
              (Epub.Resources.Resolve ("container.xml", Get (Container, Position, Epub.XML.Full_Path)));
         end if;
      end loop;
      if Root_Count /= 1 then
         raise Invalid_Book with "Multiple or missing package rootfiles require manual review";
      end if;
      declare
         Package_Payload : constant Epub.Encoding.Payload :=
           Epub.Encoding.Decode (Epub.Archives.Contents (Items, To_String (Package_Path)));
         Package_Doc : constant Epub.XML.Summary := Epub.XML.Inspect_Package (Epub.Encoding.Text (Package_Payload));
      begin
         if Epub.XML.Is_Fixed (Package_Doc) then
            Result.Reason := Epub.Classification.Fixed_Layout;
            Epub.Performance.Stop (Epub.Performance.Analysis);
            return Result;
         end if;
         for Position in 1 .. Package_Doc.Count loop
            if Package_Doc.Kind (Position) = Epub.XML.Meta and then Get (Package_Doc, Position, Epub.XML.Name) = "primary-writing-mode"
              and then Vertical_Mode (Get (Package_Doc, Position, Epub.XML.Content))
            then
               Primary_Vertical := True;
            elsif Package_Doc.Kind (Position) = Epub.XML.Manifest_Item
              and then Package_Doc.Parent_Kind (Position) = Epub.XML.Manifest
            then
               declare
                  Path : constant String := Epub.Resources.Resolve (To_String (Package_Path), Get (Package_Doc, Position, Epub.XML.Href));
                  Id : constant String := Get (Package_Doc, Position, Epub.XML.Id);
               begin
                  if Epub.Archives.Find (Items, Path) = 0 then
                     raise Invalid_Book with "Missing manifest resource: " & Path;
                  end if;
                  if Manifest_Ids.Find (Id) /= 0 then
                     raise Invalid_Book with "Duplicate manifest id: " & Id;
                  end if;
                  Manifest.Append (Manifest_Item'
                    (Id => To_Unbounded_String (Id), Path => To_Unbounded_String (Path),
                     Media => To_Unbounded_String (Get (Package_Doc, Position, Epub.XML.Media_Type))));
                  Manifest_Ids.Insert_First (Id, Manifest.Last_Index);
               end;
            end if;
         end loop;
         for Position in 1 .. Package_Doc.Count loop
            if Package_Doc.Kind (Position) = Epub.XML.Spine_Item
              and then Package_Doc.Parent_Kind (Position) = Epub.XML.Spine
            then
               Spine_Count := Spine_Count + 1;
               declare
                  Found : constant Natural := Manifest_Ids.Find (Get (Package_Doc, Position, Epub.XML.Idref));
               begin
                  if Found = 0 then
                     raise Invalid_Book with "Unknown spine idref: " & Get (Package_Doc, Position, Epub.XML.Idref);
                  end if;
                  declare
                     Resource : constant Manifest_Item := Manifest (Found);
                     Path : constant String := To_String (Resource.Path);
                  begin
                     if Is_Markup (To_String (Resource.Media))
                       and then not Epub.Resources.Contains (Visited_Documents, Path)
                     then
                        Epub.Resources.Include (Visited_Documents, Path);
                        declare
                           Payload : constant Epub.Encoding.Payload := Epub.Encoding.Decode (Epub.Archives.Contents (Items, Path));
                           Text : constant String := Epub.Encoding.Text (Payload);
                           Document : constant Epub.XML.Summary := Epub.XML.Inspect_Content (Text);
                           procedure Include_Class (Value : String) is
                           begin Epub.Resources.Include (Classes, Value); end Include_Class;
                           procedure Classes_From is new Epub.Resources.Query_Tokens (Include_Class);
                        begin
                           for Node_Position in 1 .. Document.Count loop
                              Classes_From (Get (Document, Node_Position, Epub.XML.Class_Value));
                              Epub.Resources.Include (Ids, Get (Document, Node_Position, Epub.XML.Id));
                              if Document.Kind (Node_Position) = Epub.XML.Link then
                                 -- Inspect_Content retains a link only when rel
                                 -- contains stylesheet, or it has class/id data.
                                 declare
                                    Stylesheet : Boolean := False;
                                    procedure Check_Rel (Value : String) is
                                    begin
                                       Stylesheet := Stylesheet or else Ada.Characters.Handling.To_Lower (Value) = "stylesheet";
                                    end Check_Rel;
                                    procedure Rel_From is new Epub.Resources.Query_Tokens (Check_Rel);
                                 begin
                                    Rel_From (Get (Document, Node_Position, Epub.XML.Rel));
                                    if Stylesheet then
                                       Epub.Resources.Include (Styles,
                                         Epub.Resources.Resolve (Path, Get (Document, Node_Position, Epub.XML.Href)));
                                    end if;
                                 end;
                              end if;
                           end loop;
                           if Document.Has_Visible_Text then
                              Texts := Texts + 1;
                           elsif Document.Has_Image then
                              Images := Images + 1;
                           end if;
                           Inline_Vertical := Inline_Vertical or else Epub.Markup.Convert (Text) /= Text;
                        end;
                     end if;
                  end;
               end;
            end if;
         end loop;
         if Spine_Count = 0 then
            raise Invalid_Book with "Empty or missing spine";
         end if;
         Result.Reason := Epub.Classification.Classify (False, Images, Texts, False);
         if Result.Reason in Epub.Classification.Image_Only | Epub.Classification.Image_Dominated then
            Epub.Performance.Stop (Epub.Performance.Analysis);
            return Result;
         end if;
         declare
            Position : Positive := 1;
         begin
            while Position <= Styles.Last_Index loop
               declare
                  Path : constant String := To_String (Styles (Position));
               begin
                  if not Epub.Resources.Contains (Visited_Styles, Path) then
                     Epub.Resources.Include (Visited_Styles, Path);
                     declare
                        Payload : constant Epub.Encoding.Payload := Epub.Encoding.Decode (Epub.Archives.Contents (Items, Path));
                        Text : constant String := Epub.Encoding.Text (Payload);
                     begin
                        for Import_Path of Epub.Resources.Imports (Text) loop
                           Epub.Resources.Include (Styles, Epub.Resources.Resolve (Path, To_String (Import_Path)));
                        end loop;
                        Active_Vertical := Active_Vertical or else Epub.Resources.Uses_Vertical (Text, Classes, Ids);
                     end;
                  end if;
               end;
               Position := Position + 1;
            end loop;
         end;
         Result.Reason := Epub.Classification.Classify
           (False, Images, Texts, Primary_Vertical or else Inline_Vertical or else Active_Vertical);
         if Result.Reason /= Epub.Classification.Vertical_Text then
            Epub.Performance.Stop (Epub.Performance.Analysis);
            return Result;
         end if;
         if Epub.Archives.Find (Items, "META-INF/signatures.xml") /= 0
           or else Epub.Archives.Find (Items, "META-INF/encryption.xml") /= 0
         then
            raise Invalid_Book with "Signed or encrypted EPUB requires manual review before modifying resources";
         end if;
         for Resource of Manifest loop
            if To_String (Resource.Media) = "text/css" then
               Patch (To_String (Resource.Path), Is_CSS => True);
            elsif Is_Markup (To_String (Resource.Media)) then
               Patch (To_String (Resource.Path));
            end if;
         end loop;
         for Path of Visited_Styles loop
            Patch (To_String (Path), Is_CSS => True);
         end loop;
         Patch (To_String (Package_Path), Is_Package => True);
         if Result.Patches.Is_Empty then
            raise Invalid_Book with "Vertical evidence found but no supported direction setting could be changed";
         end if;
      end;
      Epub.Performance.Stop (Epub.Performance.Analysis);
      return Result;
   end Analyze_Book;

   function Apply (Items : Epub.Archives.Catalogue; Plan : Book_Plan)
      return Epub.Archives.Catalogue is
      Result : Epub.Archives.Catalogue := Items;
   begin
      Epub.Performance.Start (Epub.Performance.Patch_Planning);
      for Patch of Plan.Patches loop
         declare
            Position : constant Natural := Epub.Archives.Find (Result, To_String (Patch.Name));
            Item : Epub.Archives.Member := Result (Position);
         begin
            Item.Payload := Patch.Payload;
            Item.Payload_Loaded := True;
            Result.Replace_Element (Position, Item);
         end;
      end loop;
      Epub.Performance.Stop (Epub.Performance.Patch_Planning);
      return Result;
   end Apply;

   function Reason_Name (Reason : Epub.Classification.Layout) return String is
     (case Reason is
        when Epub.Classification.Fixed_Layout => "FixedLayout",
        when Epub.Classification.Image_Only => "ImageOnly",
        when Epub.Classification.Image_Dominated => "ImageDominated",
        when Epub.Classification.Horizontal => "Horizontal",
        when Epub.Classification.Vertical_Text => "VerticalText");
end Epub.Books;

with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Epub.Encoding;
with Epub.Markup;
with Epub.Resources;
with Epub.CSS;
with Epub.XML;

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
   function Get (Item : Epub.XML.Node; Name : String) return String renames Epub.XML.Get_Attribute;

   function Is_Fixed (Document : Epub.XML.Document) return Boolean is
   begin
      for Item of Document loop
         if To_String (Item.Name) = "meta" then
            if (Get (Item, "property") = "rendition:layout"
                and then Ada.Strings.Fixed.Trim (To_String (Item.Content), Ada.Strings.Both) = "pre-paginated")
              or else (Get (Item, "name") = "fixed-layout" and then Get (Item, "content") = "true")
            then
               return True;
            end if;
         elsif To_String (Item.Name) = "itemref" then
            if Epub.Resources.Contains
              (Epub.Resources.Tokens (Get (Item, "properties")), "rendition:layout-pre-paginated")
            then
               return True;
            end if;
         end if;
      end loop;
      return False;
   end Is_Fixed;

   function Has_Visible_Text (Document : Epub.XML.Document) return Boolean is
   begin
      for Position in 1 .. Document.Last_Index loop
         declare
            Item : constant Epub.XML.Node := Document (Position);
            Has_Text : Boolean := False;
            In_Content : Boolean := False;
            Excluded : Boolean := False;
            Ancestor : Natural := Position;
         begin
            for Value of To_String (Item.Content) loop
               Has_Text := Has_Text or else
                 (Value /= ' ' and then Value not in Character'Val (9) .. Character'Val (13));
            end loop;
            if Has_Text then
               while Ancestor /= 0 loop
                  declare
                     Parent : constant Epub.XML.Node := Document (Ancestor);
                     Name : constant String := To_String (Parent.Name);
                  begin
                     In_Content := In_Content or else Name = "body"
                       or else (Name = "svg" and then Parent.Parent = 0);
                     Excluded := Excluded or else Name in "script" | "style" | "title" | "desc";
                     Ancestor := Parent.Parent;
                  end;
               end loop;
               if In_Content and then not Excluded then
                  return True;
               end if;
            end if;
         end;
      end loop;
      return False;
   end Has_Visible_Text;

   function Analyze_Book (Items : Epub.Archives.Catalogue) return Book_Plan is
      Result : Book_Plan;
      Container : constant Epub.XML.Document := Epub.XML.Parse
        (Epub.Encoding.Text (Epub.Encoding.Decode (Epub.Archives.Contents (Items, "META-INF/container.xml"))));
      Package_Path : Unbounded_String;
      Root_Count : Natural := 0;
      Manifest : Manifest_Lists.Vector;
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
      for Item of Container loop
         if To_String (Item.Name) = "rootfile" then
            Root_Count := Root_Count + 1;
            Package_Path := To_Unbounded_String
              (Epub.Resources.Resolve ("container.xml", Get (Item, "full-path")));
         end if;
      end loop;
      if Root_Count /= 1 then
         raise Invalid_Book with "Multiple or missing package rootfiles require manual review";
      end if;
      declare
         Package_Payload : constant Epub.Encoding.Payload :=
           Epub.Encoding.Decode (Epub.Archives.Contents (Items, To_String (Package_Path)));
         Package_Doc : constant Epub.XML.Document := Epub.XML.Parse (Epub.Encoding.Text (Package_Payload));
      begin
         if Is_Fixed (Package_Doc) then
            Result.Reason := Epub.Classification.Fixed_Layout;
            return Result;
         end if;
         for Item of Package_Doc loop
            if To_String (Item.Name) = "meta" and then Get (Item, "name") = "primary-writing-mode"
              and then Vertical_Mode (Get (Item, "content"))
            then
               Primary_Vertical := True;
            elsif To_String (Item.Name) = "item" and then Item.Parent /= 0
              and then To_String (Package_Doc (Item.Parent).Name) = "manifest"
            then
               declare
                  Path : constant String := Epub.Resources.Resolve (To_String (Package_Path), Get (Item, "href"));
                  Id : constant String := Get (Item, "id");
               begin
                  if Epub.Archives.Find (Items, Path) = 0 then
                     raise Invalid_Book with "Missing manifest resource: " & Path;
                  end if;
                  for Existing of Manifest loop
                     if To_String (Existing.Id) = Id then
                        raise Invalid_Book with "Duplicate manifest id: " & Id;
                     end if;
                  end loop;
                  Manifest.Append (Manifest_Item'
                    (Id => To_Unbounded_String (Id), Path => To_Unbounded_String (Path),
                     Media => To_Unbounded_String (Get (Item, "media-type"))));
               end;
            end if;
         end loop;
         for Reference of Package_Doc loop
            if To_String (Reference.Name) = "itemref" and then Reference.Parent /= 0
              and then To_String (Package_Doc (Reference.Parent).Name) = "spine"
            then
               Spine_Count := Spine_Count + 1;
               declare
                  Found : Natural := 0;
               begin
                  for Position in 1 .. Manifest.Last_Index loop
                     if To_String (Manifest (Position).Id) = Get (Reference, "idref") then
                        Found := Position;
                     end if;
                  end loop;
                  if Found = 0 then
                     raise Invalid_Book with "Unknown spine idref: " & Get (Reference, "idref");
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
                           Document : constant Epub.XML.Document := Epub.XML.Parse (Text);
                           Has_Image : Boolean := False;
                        begin
                           for Item of Document loop
                              for Class of Epub.Resources.Tokens (Get (Item, "class")) loop
                                 Epub.Resources.Include (Classes, To_String (Class));
                              end loop;
                              Epub.Resources.Include (Ids, Get (Item, "id"));
                              if To_String (Item.Name) = "link" and then Epub.Resources.Contains
                                (Epub.Resources.Tokens (Ada.Characters.Handling.To_Lower (Get (Item, "rel"))), "stylesheet")
                              then
                                 Epub.Resources.Include (Styles, Epub.Resources.Resolve (Path, Get (Item, "href")));
                              end if;
                              Has_Image := Has_Image or else To_String (Item.Name) in "img" | "image";
                           end loop;
                           if Has_Visible_Text (Document) then
                              Texts := Texts + 1;
                           elsif Has_Image then
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
      return Result;
   end Analyze_Book;

   function Apply (Items : Epub.Archives.Catalogue; Plan : Book_Plan)
      return Epub.Archives.Catalogue is
      Result : Epub.Archives.Catalogue := Items;
   begin
      for Patch of Plan.Patches loop
         declare
            Position : constant Natural := Epub.Archives.Find (Result, To_String (Patch.Name));
            Item : Epub.Archives.Member := Result (Position);
         begin
            Item.Payload := Patch.Payload;
            Result.Replace_Element (Position, Item);
         end;
      end loop;
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

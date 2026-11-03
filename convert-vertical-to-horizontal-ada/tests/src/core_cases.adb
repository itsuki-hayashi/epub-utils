with AUnit.Assertions;
with Epub.Classification;
with Epub.CSS;
with Epub.Markup;
with Epub.Lists;
with Epub.Patches;
with Epub.Publication;
with Epub.Writing_Modes;

package body Core_Cases is
   use AUnit.Assertions;
   use type Epub.Classification.Layout;
   use type Epub.Publication.State;
   use type Epub.Writing_Modes.Mode;
   type Unit_Case_Access is access all Unit_Case;
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access is
      Result : constant Unit_Case_Access := new Unit_Case;
   begin
      Result.all.Kind := Kind;
      return AUnit.Simple_Test_Cases.Test_Case_Access (Result);
   end Create;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String is
     (AUnit.Format ("Core: " & Item.Kind'Image));

   procedure Classification_Tests is
   begin
      for Images in Epub.Classification.Page_Count range 0 .. 50 loop
         for Texts in Epub.Classification.Page_Count range 0 .. 50 loop
            for Fixed in Boolean loop
               for Vertical in Boolean loop
                  declare
                     Expected : constant Epub.Classification.Layout :=
                       (if Fixed then Epub.Classification.Fixed_Layout
                        elsif Texts = 0 then Epub.Classification.Image_Only
                        elsif Images >= 10 and then 5 * Images >= 4 * (Images + Texts)
                        then Epub.Classification.Image_Dominated
                        elsif Vertical then Epub.Classification.Vertical_Text
                        else Epub.Classification.Horizontal);
                  begin
                     Assert (Epub.Classification.Classify (Fixed, Images, Texts, Vertical) = Expected,
                             "Classification precedence and integer threshold");
                  end;
               end loop;
            end loop;
         end loop;
      end loop;
      Assert (Epub.Classification.Classify
        (False, Epub.Classification.Page_Count'Last, Epub.Classification.Page_Count'Last, True) =
          Epub.Classification.Vertical_Text, "Large counts do not overflow");
   end Classification_Tests;

   procedure Patch_Tests is
      Alphabet : constant String := "abcdefgh";
      Replacement : constant String := "WXYZ";
   begin
      for Source_Length in 0 .. Alphabet'Length loop
         for Offset in 0 .. Source_Length loop
            for Count in 0 .. Source_Length - Offset loop
               for Insert_Length in 0 .. Replacement'Length loop
                  declare
                     Before : constant String (1 .. Source_Length) := Alphabet (1 .. Source_Length);
                     Insert : constant String (1 .. Insert_Length) := Replacement (1 .. Insert_Length);
                     After : constant String := Epub.Patches.Replace (Before, Offset, Count, Insert);
                  begin
                     Assert (After'First = 1, "Canonical result bounds including empty output");
                     Assert (After'Length = Source_Length - Count + Insert_Length, "Replacement length");
                     Assert (After (1 .. Offset) = Before (1 .. Offset), "Preserved prefix");
                     Assert (After (Offset + 1 .. Offset + Insert_Length) = Insert, "Replacement content");
                     Assert (After (Offset + Insert_Length + 1 .. After'Last) =
                       Before (Offset + Count + 1 .. Before'Last), "Preserved suffix");
                  end;
               end loop;
            end loop;
         end loop;
      end loop;
   end Patch_Tests;

   procedure Mode_Tests is
   begin
      for Value in Epub.Writing_Modes.Mode loop
         for Microsoft in Boolean loop
            declare
               Actual : constant Epub.Writing_Modes.Mode := Epub.Writing_Modes.Map (Value, Microsoft);
               Expected : constant Epub.Writing_Modes.Mode :=
                 (if Value not in Epub.Writing_Modes.Vertical_Mode then Value
                  elsif Microsoft or else Value in Epub.Writing_Modes.TB_RL | Epub.Writing_Modes.TB_LR
                  then Epub.Writing_Modes.LR_TB else Epub.Writing_Modes.Horizontal_TB);
            begin
               Assert (Actual = Expected, "Mode mapping");
               Assert (Epub.Writing_Modes.Map (Actual, Microsoft) = Actual, "Mode idempotence");
               Assert (Epub.Writing_Modes.Parse_Lower (Epub.Writing_Modes.Token (Value)) = Value, "Mode token round trip");
            end;
         end loop;
      end loop;
      Assert (Epub.Writing_Modes.Parse_Lower ("unsupported") = Epub.Writing_Modes.Other, "Unknown mode preserved");
   end Mode_Tests;

   procedure Publication_Tests is
      Current : Epub.Publication.State := Epub.Publication.Unverified;
   begin
      for Value in Epub.Publication.State loop
         for Collision in Boolean loop
            Assert (Epub.Publication.Eligible (Value, Collision) =
              (Value = Epub.Publication.Verified and then not Collision), "Publication eligibility");
         end loop;
      end loop;
      Epub.Publication.Mark_Verified (Current);
      Assert (Current = Epub.Publication.Verified, "Verification transition");
      Epub.Publication.Mark_Published (Current);
      Assert (Current = Epub.Publication.Published, "Publication transition");
   end Publication_Tests;

   procedure Generated_Tests is
      type Random_State is mod 2 ** 32;
      Seed : Random_State := 16#00C0_FFEE#;
      Alphabet : constant String := " {}:;/*'""\!#.@-writingmodevertical0123456789";
      function Next (Limit : Positive) return Natural is
      begin
         Seed := Seed * 1_664_525 + 1_013_904_223;
         return Natural (Seed mod Random_State (Limit));
      end Next;
   begin
      for Ordinal in 1 .. 1000 loop
         declare
            Text : String (1 .. Next (256));
         begin
            for Position in Text'Range loop
               Text (Position) := Alphabet (Next (Alphabet'Length) + 1);
            end loop;
            declare
               Before : constant String := Text &
                 (if Ordinal mod 2 = 0 then "p{writing-mode:vertical-rl}" else "");
               After : constant String := Epub.CSS.Convert (Before);
            begin
               Assert (Epub.CSS.Convert (After) = After, "Generated CSS idempotence");
               Assert (After'Length <= Before'Length * 3 + 13, "Generated CSS bounded growth");
               Assert (Epub.Markup.Convert ("<script>" & Before & "</script>") =
                 "<script>" & Before & "</script>", "Generated script preservation");
            end;
         end;
      end loop;
   end Generated_Tests;

   procedure List_Tests is
      package Strings is new Epub.Lists (String);
      Original, Copy : Strings.Vector;
      Rejected : Boolean;
   begin
      Copy := Original;
      Assert (Copy.Is_Empty, "Copying empty list");
      for Position in 1 .. 40 loop
         Original.Append (Position'Image);
      end loop;
      Copy := Original;
      Copy.Replace_Element (1, "a much longer replacement");
      Copy.Delete_Last;
      Assert (Original.Element (1) = " 1", "Replacement does not alias original");
      Assert (Original.Last_Index = 40 and then Copy.Last_Index = 39, "Deletion does not alias original");
      Assert (Copy.Last_Element = " 39", "Last remaining element");
      Assert (Copy.First = 1 and then Copy.Next (1) = 2, "Iteration cursors");
      for Position in 1 .. 39 loop
         Copy.Delete_Last;
      end loop;
      Copy.Append ("");
      Assert (Copy.Last_Element = "", "Indefinite empty string");
      Copy.Delete_Last;
      Rejected := False;
      begin
         Copy.Delete_Last;
      exception
         when Constraint_Error => Rejected := True;
      end;
      Assert (Rejected, "Deleting an empty list must fail");
      Rejected := False;
      begin
         Copy.Replace_Element (1, "missing");
      exception
         when Constraint_Error => Rejected := True;
      end;
      Assert (Rejected, "Replacing an absent element must fail");
      Rejected := False;
      begin
         declare
            Missing : constant String := Copy.Element (1);
         begin
            Assert (False, "Missing element accepted: " & Missing);
         end;
      exception
         when Constraint_Error => Rejected := True;
      end;
      Assert (Rejected, "Reading an absent element must fail");
   end List_Tests;

   overriding procedure Run_Test (Item : in out Unit_Case) is
   begin
      case Item.Kind is
         when Classification_Boundaries => Classification_Tests;
         when Patch_Preservation => Patch_Tests;
         when Mode_Mapping => Mode_Tests;
         when Publication_Decisions => Publication_Tests;
         when Generated_Scanners => Generated_Tests;
         when List_Ownership => List_Tests;
      end case;
   end Run_Test;
end Core_Cases;

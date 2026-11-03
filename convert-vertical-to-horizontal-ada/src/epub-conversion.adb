with Ada.Characters.Handling;
with Ada.Exceptions;
with Epub.Archives;
with Epub.Books;
with Epub.Files;
with GNAT.SHA256;

package body Epub.Conversion is
   use Ada.Strings.Unbounded;
   use type Epub.Classification.Layout;
   function Hash (Bytes : String) return Unbounded_String is
     (To_Unbounded_String (Ada.Characters.Handling.To_Upper (GNAT.SHA256.Digest (Bytes))));

   function Process_Book (Input, Destination : String; Settings : Options) return Book_Result is
      Result : Book_Result;
   begin
      Result.Book := To_Unbounded_String (Epub.Files.Basename (Input));
      Result.Output := To_Unbounded_String (Destination);
      declare
         Source : constant String := Epub.Files.Read (Input);
      begin
         Result.Input_Bytes := Source'Length;
         declare
            Items : constant Epub.Archives.Catalogue := Epub.Archives.Read (Source);
            Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
         begin
            Result.Reason := Plan.Reason;
            Result.Has_Reason := True;
            for Patch of Plan.Patches loop
               Result.Changed_Entries.Append (Patch.Name);
            end loop;
            if Settings.Analyze_Only then
               Result.Status := Analyzed;
            else
               if Epub.Files.Exists (Destination) then
                  raise Epub.Files.File_Error with "Refusing to overwrite: " & Destination;
               end if;
               if Settings.Dry_Run then
                  Result.Status := What_If;
               else
                  Epub.Files.Ensure_Directory (Epub.Files.Parent_Path (Destination));
                  Result.Input_SHA256 := Hash (Source);
                  if Plan.Reason = Epub.Classification.Vertical_Text then
                     declare
                        Patched : constant Epub.Archives.Catalogue := Epub.Books.Apply (Items, Plan);
                        Bytes : constant String := Epub.Archives.Rebuild (Patched);
                        procedure Check_Archive (Saved : String) is
                        begin
                           Epub.Archives.Verify (Saved, Patched);
                        end Check_Archive;
                        procedure Save is new Epub.Files.Write_Checked (Check_Archive);
                     begin
                        Result.Output_SHA256 := Hash (Bytes);
                        Result.Output_Bytes := Bytes'Length;
                        Result.Has_Output_Bytes := True;
                        Save (Destination, Bytes);
                     end;
                     Result.Status := Converted;
                  else
                     Result.Output_SHA256 := Result.Input_SHA256;
                     Result.Output_Bytes := Source'Length;
                     Result.Has_Output_Bytes := True;
                     Epub.Files.Write_Verified (Destination, Source);
                     Result.Status := Preserved;
                  end if;
                  Result.Entries_Verified := Items.Last_Index;
               end if;
            end if;
         end;
      end;
      return Result;
   exception
      when Error : others =>
         Result.Status := Failed;
         declare
            Message : constant String := Ada.Exceptions.Exception_Message (Error);
         begin
            Result.Error := To_Unbounded_String
              ((if Message'Length = 0 then Ada.Exceptions.Exception_Name (Error) else Message));
         end;
         return Result;
   end Process_Book;

   function Status_Name (Status : Processing_Status) return String is
     (case Status is
        when Analyzed => "Analyzed", when What_If => "WhatIf",
        when Preserved => "Preserved", when Converted => "Converted", when Failed => "Error");
end Epub.Conversion;

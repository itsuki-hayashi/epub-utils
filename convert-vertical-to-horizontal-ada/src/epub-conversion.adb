with Ada.Exceptions;
with Epub.Archives;
with Epub.Books;
with Epub.Files;
with Epub.Files.Write_Stream_Checked;
with Epub.Hash_Streams;
with Interfaces;
with Zip_Streams;
with Epub.Performance;

package body Epub.Conversion is
   use Ada.Strings.Unbounded;
   use type Epub.Classification.Layout;
   use type Zip_Streams.ZS_Size_Type;
   function Process_Book (Input, Destination : String; Settings : Options) return Book_Result is
      Result : Book_Result;
   begin
      Result.Book := To_Unbounded_String (Epub.Files.Basename (Input));
      Result.Output := To_Unbounded_String (Destination);
      Epub.Performance.Start (Epub.Performance.Input_Read);
      declare
         Items : constant Epub.Archives.Catalogue := Epub.Archives.Read_File (Input);
      begin
         Result.Input_Bytes := Natural (Epub.Archives.Source_Size (Items));
         Epub.Performance.Stop (Epub.Performance.Input_Read);
         declare
            Plan : constant Epub.Books.Book_Plan := Epub.Books.Analyze_Book (Items);
            Output_Size : Interfaces.Unsigned_64;
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
                  Epub.Performance.Start (Epub.Performance.Hashing);
                  Result.Input_SHA256 := To_Unbounded_String (Epub.Archives.Source_Digest (Items));
                  Epub.Performance.Stop (Epub.Performance.Hashing);
                  if Plan.Reason = Epub.Classification.Vertical_Text then
                     declare
                        Patched : constant Epub.Archives.Catalogue := Epub.Books.Apply (Items, Plan);
                        procedure Build
                          (Output : in out Zip_Streams.Root_Zipstream_Type'Class;
                           Expected_SHA256 : out Unbounded_String) is
                           Hashed : Epub.Hash_Streams.Stream (Output'Access);
                        begin
                           Epub.Archives.Rebuild (Patched, Hashed);
                           if Output.Size > Zip_Streams.ZS_Size_Type (Natural'Last) then
                              raise Epub.Files.File_Error with "Output exceeds the report byte-count limit";
                           end if;
                           Expected_SHA256 := To_Unbounded_String (Hashed.Digest);
                        end Build;
                        procedure Check_Archive (Saved : in out Zip_Streams.Root_Zipstream_Type'Class) is
                        begin
                           Epub.Archives.Verify (Saved, Patched);
                        end Check_Archive;
                        procedure Save is new Epub.Files.Write_Stream_Checked (Build, Check_Archive);
                     begin
                        Save (Destination, Output_Size, Result.Output_SHA256);
                     end;
                     Result.Status := Converted;
                  else
                     declare
                        procedure Build
                          (Output : in out Zip_Streams.Root_Zipstream_Type'Class;
                           Expected_SHA256 : out Unbounded_String) is
                        begin
                           Epub.Archives.Copy_Source (Items, Output);
                           Expected_SHA256 := Result.Input_SHA256;
                        end Build;
                        procedure No_Additional_Check (Saved : in out Zip_Streams.Root_Zipstream_Type'Class) is
                           pragma Unreferenced (Saved);
                        begin
                           null;
                        end No_Additional_Check;
                        procedure Save is new Epub.Files.Write_Stream_Checked (Build, No_Additional_Check);
                     begin
                        Save (Destination, Output_Size, Result.Output_SHA256);
                     end;
                     Result.Status := Preserved;
                  end if;
                  Result.Output_Bytes := Natural (Output_Size);
                  Result.Has_Output_Bytes := True;
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

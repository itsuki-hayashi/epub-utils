with Ada.Exceptions;
with Epub.File_Streams;
with Epub.Performance;
with Epub.Publication;
with Epub.Stream_IO;
with Epub.Temporary_Files;

procedure Epub.Files.Write_Stream_Checked
  (Destination : String; Output_Bytes : out Interfaces.Unsigned_64;
   Output_SHA256 : out Ada.Strings.Unbounded.Unbounded_String) is
   use Ada.Strings.Unbounded;
   use type Epub.Publication.State;
   use type Zip_Streams.ZS_Size_Type;
   Temporary : Unbounded_String;
   Reserved : Boolean := False;
   State : Epub.Publication.State := Epub.Publication.Unverified;
   Output, Input : Epub.File_Streams.Stream;
begin
   if Exists (Destination) then
      raise File_Error with "Refusing to overwrite: " & Destination;
   end if;
   Epub.Temporary_Files.Reserve (Parent_Path (Destination), Output, Temporary);
   Reserved := True;
   Epub.Performance.Start (Epub.Performance.Output_Write);
   Build (Output, Output_SHA256);
   Output_Bytes := Interfaces.Unsigned_64 (Output.Size);
   Output.Flush;
   Output.Close;
   Epub.Performance.Stop (Epub.Performance.Output_Write);
   Input.Open (To_String (Temporary));
   Epub.Performance.Start (Epub.Performance.Hashing);
   if Epub.Stream_IO.Digest (Input) /= To_String (Output_SHA256) then
      raise File_Error with "Temporary output verification failed";
   end if;
   Epub.Performance.Stop (Epub.Performance.Hashing);
   Input.Set_Index (1);
   Verify (Input);
   pragma Assert (Input.Size = Zip_Streams.ZS_Size_Type (Output_Bytes));
   Input.Close;
   Epub.Publication.Mark_Verified (State);
   if not Epub.Publication.Eligible (State, Exists (Destination)) then
      raise File_Error with "Refusing to publish unverified output or overwrite: " & Destination;
   end if;
   Epub.Performance.Start (Epub.Performance.Publication);
   Publish (To_String (Temporary), Destination);
   Epub.Performance.Stop (Epub.Performance.Publication);
   Epub.Publication.Mark_Published (State);
   pragma Assert (State = Epub.Publication.Published);
   Reserved := False;
exception
   when Error : others =>
      --  Close before removal, including failed flush/write/verification paths.
      --  Keep every cleanup failure in the reported diagnostic.
      declare
         Failures : Unbounded_String;
      begin
         begin
            Output.Close;
         exception
            when Cleanup : others => Append (Failures, "; close failed: " & Ada.Exceptions.Exception_Message (Cleanup));
         end;
         begin
            Input.Close;
         exception
            when Cleanup : others => Append (Failures, "; close failed: " & Ada.Exceptions.Exception_Message (Cleanup));
         end;
         if Reserved then
            begin
               Remove (To_String (Temporary));
            exception
               when Cleanup : others => Append (Failures, "; cleanup failed: " & Ada.Exceptions.Exception_Message (Cleanup));
            end;
         end if;
         if Length (Failures) > 0 then
            raise File_Error with Ada.Exceptions.Exception_Message (Error) & To_String (Failures);
         end if;
      end;
      raise;
end Epub.Files.Write_Stream_Checked;

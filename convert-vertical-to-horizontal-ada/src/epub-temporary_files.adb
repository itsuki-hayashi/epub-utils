with Ada.Strings.Fixed;
with Epub.Files;
with GNAT.OS_Lib;
with Interfaces;
with Epub.Native_Files;
with Ada.Exceptions;

package body Epub.Temporary_Files is
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;
   protected Names is
      procedure Next (Value : out Interfaces.Unsigned_64);
   private
      Sequence : Interfaces.Unsigned_64 := 0;
   end Names;
   protected body Names is
      procedure Next (Value : out Interfaces.Unsigned_64) is
      begin
         if Sequence = Interfaces.Unsigned_64'Last then
            raise Storage_Error with "Temporary filename sequence exhausted";
         end if;
         Sequence := Sequence + 1;
         Value := Sequence;
      end Next;
   end Names;
   function Next_Path (Directory : String) return String is
      Sequence : Interfaces.Unsigned_64;
   begin
      Names.Next (Sequence);
      return Epub.Files.Join (Directory, ".epub-horizontal-" & Ada.Strings.Fixed.Trim
        (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)'Image, Ada.Strings.Both)
        & "-" & Ada.Strings.Fixed.Trim (Sequence'Image, Ada.Strings.Both) & ".tmp");
   end Next_Path;
   procedure Reserve
     (Directory : String; Output : in out Epub.File_Streams.Stream;
      Path : out Unbounded_String) is
   begin
      loop
         Path := To_Unbounded_String (Next_Path (Directory));
         declare
            Outcome : aliased Epub.Native_Files.Open_Result;
         begin
            begin
               Output.Open (To_String (Path), Exclusive => True, Outcome => Outcome'Access);
               if not Outcome.Collision then return; end if;
            exception
               when Error : others =>
                  if Outcome.Created then
                     begin
                        Epub.Files.Remove (To_String (Path));
                     exception
                        when Cleanup : others =>
                           raise Epub.File_Streams.File_Error with Ada.Exceptions.Exception_Message (Error)
                             & "; cleanup failed: " & Ada.Exceptions.Exception_Message (Cleanup);
                     end;
                  end if;
                  raise;
            end;
         end;
      end loop;
   end Reserve;
end Epub.Temporary_Files;

with Epub.Destinations.Native;
with Epub.Name_Indexes;

package body Epub.Destinations is
   use Ada.Strings.Unbounded;
   package Key_Lists is new Epub.Lists (Key);
   function Describe (Path : String) return Key is (Native.Identify (Path));
   function Groups (Paths : Epub.Resources.String_Lists.Vector) return Group_Lists.Vector is
      Keys : Key_Lists.Vector;
      Anchors, Directories, Assigned : Epub.Name_Indexes.Index;
      Global : Boolean := False;
      Group_Count : Natural := 0;
      Result : Group_Lists.Vector;
   begin
      for Path of Paths loop
         declare
            Value : constant Key := Describe (To_String (Path));
         begin
            Keys.Append (Value);
            case Value.Scope is
               when Whole_Run => Global := True;
               when Whole_Anchor => Anchors.Insert_First (To_String (Value.Anchor), 1);
               when Whole_Directory => Directories.Insert_First (To_String (Value.Directory), 1);
               when Exact_Name => null;
            end case;
         end;
      end loop;
      for Value of Keys loop
         declare
            Name : constant String :=
              (if Global then "global"
               elsif Anchors.Find (To_String (Value.Anchor)) /= 0 then "anchor:" & To_String (Value.Anchor)
               elsif Directories.Find (To_String (Value.Directory)) /= 0 then "directory:" & To_String (Value.Directory)
               else "name:" & To_String (Value.Directory) & Character'Val (0) & To_String (Value.Target));
            Existing : Natural := Assigned.Find (Name);
         begin
            if Existing = 0 then
               Group_Count := Group_Count + 1;
               Existing := Group_Count;
               Assigned.Insert_First (Name, Existing);
            end if;
            Result.Append (Existing);
         end;
      end loop;
      return Result;
   end Groups;
end Epub.Destinations;

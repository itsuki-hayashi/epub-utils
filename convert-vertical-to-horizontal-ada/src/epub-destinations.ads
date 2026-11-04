with Ada.Strings.Unbounded;
with Epub.Resources;
with Epub.Lists;

package Epub.Destinations is
   type Collision_Scope is (Exact_Name, Whole_Directory, Whole_Anchor, Whole_Run);
   type Key is record
      Anchor, Directory, Target : Ada.Strings.Unbounded.Unbounded_String;
      Scope : Collision_Scope := Exact_Name;
   end record;
   package Group_Lists is new Epub.Lists (Positive);
   --  Keys only delay publication; they never reject otherwise valid filenames.
   function Describe (Path : String) return Key;
   function Groups (Paths : Epub.Resources.String_Lists.Vector) return Group_Lists.Vector;
end Epub.Destinations;

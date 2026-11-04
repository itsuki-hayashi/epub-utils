with Ada.Finalization;
with Ada.Strings.Unbounded;

--  Case-sensitive first-occurrence indexes. Copies own their slot arrays;
--  no key or element reference escapes the index.
package Epub.Name_Indexes is
   type Index is new Ada.Finalization.Controlled with private;
   function Find (Item : Index; Name : String) return Natural;
   procedure Insert_First (Item : in out Index; Name : String; Value : Positive);
   procedure Delete (Item : in out Index; Name : String);
   procedure Clear (Item : in out Index);
   procedure Swap (Left, Right : in out Index);
private
   type Slot_State is (Empty, Occupied, Deleted);
   type Slot is record
      State : Slot_State := Empty;
      Name : Ada.Strings.Unbounded.Unbounded_String;
      Value : Natural := 0;
   end record;
   type Slot_Array is array (Natural range <>) of Slot;
   type Slots_Access is access Slot_Array;
   type Index is new Ada.Finalization.Controlled with record
      Slots : Slots_Access;
      Used, Filled : Natural := 0;
   end record;
   overriding procedure Adjust (Item : in out Index);
   overriding procedure Finalize (Item : in out Index);
end Epub.Name_Indexes;

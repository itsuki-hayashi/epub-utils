with Ada.Unchecked_Deallocation;
with Interfaces;
with Epub.Allocation_Stats;

package body Epub.Name_Indexes is
   function To_String (Value : Ada.Strings.Unbounded.Unbounded_String) return String
     renames Ada.Strings.Unbounded.To_String;
   use type Interfaces.Unsigned_32;
   procedure Free is new Ada.Unchecked_Deallocation (Slot_Array, Slots_Access);

   function Bucket (Name : String; Capacity : Positive) return Natural is
      Hash : Interfaces.Unsigned_32 := 2_166_136_261;
   begin
      for Value of Name loop
         Hash := (Hash xor Interfaces.Unsigned_32 (Character'Pos (Value))) * 16_777_619;
      end loop;
      return Natural (Hash mod Interfaces.Unsigned_32 (Capacity));
   end Bucket;

   overriding procedure Adjust (Item : in out Index) is
      Original : constant Slots_Access := Item.Slots;
   begin
      Item.Slots := null;
      if Original /= null then
         Item.Slots := new Slot_Array'(Original.all);
         Epub.Allocation_Stats.Record_Allocation (Epub.Allocation_Stats.Count (Item.Slots.all'Size / 8));
      end if;
   end Adjust;

   procedure Clear (Item : in out Index) is
   begin
      Free (Item.Slots);
      Item.Used := 0;
      Item.Filled := 0;
   end Clear;

   overriding procedure Finalize (Item : in out Index) is
   begin
      Clear (Item);
   end Finalize;

   procedure Swap (Left, Right : in out Index) is
      Slots : constant Slots_Access := Left.Slots;
      Used : constant Natural := Left.Used;
      Filled : constant Natural := Left.Filled;
   begin
      Left.Slots := Right.Slots;
      Left.Used := Right.Used;
      Left.Filled := Right.Filled;
      Right.Slots := Slots;
      Right.Used := Used;
      Right.Filled := Filled;
   end Swap;

   function Find (Item : Index; Name : String) return Natural is
      Position : Natural;
   begin
      if Item.Slots = null then
         return 0;
      end if;
      Position := Bucket (Name, Item.Slots'Length);
      loop
         case Item.Slots.all (Position).State is
            when Empty => return 0;
            when Occupied =>
               if To_String (Item.Slots.all (Position).Name) = Name then
                  return Item.Slots.all (Position).Value;
               end if;
            when Deleted => null;
         end case;
         Position := (Position + 1) mod Item.Slots'Length;
      end loop;
   end Find;

   procedure Insert_First (Item : in out Index; Name : String; Value : Positive) is
      Position : Natural;
   begin
      if Find (Item, Name) /= 0 then
         return;
      end if;
      if Item.Slots = null or else Item.Filled >= Item.Slots'Length / 2 then
         declare
            Capacity : constant Positive :=
              (if Item.Slots = null then 16
               elsif Item.Used < Item.Slots'Length / 4 then Item.Slots'Length
               else Item.Slots'Length * 2);
            Fresh : Index;
         begin
            Fresh.Slots := new Slot_Array (0 .. Capacity - 1);
            Epub.Allocation_Stats.Record_Allocation (Epub.Allocation_Stats.Count (Fresh.Slots.all'Size / 8));
            if Item.Slots /= null then
               for Member_Slot of Item.Slots.all loop
                  if Member_Slot.State = Occupied then
                     Insert_First (Fresh, To_String (Member_Slot.Name), Member_Slot.Value);
                  end if;
               end loop;
            end if;
            Swap (Item, Fresh);
         end;
      end if;
      Position := Bucket (Name, Item.Slots'Length);
      while Item.Slots.all (Position).State = Occupied loop
         Position := (Position + 1) mod Item.Slots'Length;
      end loop;
      --  Allocate the key before marking the slot occupied.
      Item.Slots.all (Position).Name := Ada.Strings.Unbounded.To_Unbounded_String (Name);
      if Item.Slots.all (Position).State = Empty then
         Item.Filled := Item.Filled + 1;
      end if;
      Item.Slots.all (Position).Value := Value;
      Item.Slots.all (Position).State := Occupied;
      Item.Used := Item.Used + 1;
   end Insert_First;

   procedure Delete (Item : in out Index; Name : String) is
      Position : Natural;
   begin
      if Item.Slots = null then
         return;
      end if;
      Position := Bucket (Name, Item.Slots'Length);
      while Item.Slots.all (Position).State /= Empty loop
         if Item.Slots.all (Position).State = Occupied and then To_String (Item.Slots.all (Position).Name) = Name then
            Item.Slots.all (Position) := (Deleted, Ada.Strings.Unbounded.Null_Unbounded_String, 0);
            Item.Used := Item.Used - 1;
            return;
         end if;
         Position := (Position + 1) mod Item.Slots'Length;
      end loop;
   end Delete;
end Epub.Name_Indexes;

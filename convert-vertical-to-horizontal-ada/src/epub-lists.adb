with Ada.Unchecked_Deallocation;
with Epub.Allocation_Stats;

package body Epub.Lists is
   procedure Free is new Ada.Unchecked_Deallocation (Element_Array, Array_Access);
   procedure Free_Element is new Ada.Unchecked_Deallocation (Element_Type, Element_Access);

   overriding procedure Adjust (Container : in out Vector) is
      Original : constant Array_Access := Container.Data;
   begin
      Container.Data := null;
      if Original /= null then
         Container.Data := new Element_Array (Original.all'Range);
         Epub.Allocation_Stats.Record_Allocation
           (Epub.Allocation_Stats.Count (Container.Data.all'Size / 8));
         for Position in 1 .. Container.Used loop
            Container.Data.all (Position) := new Element_Type'(Original.all (Position).all);
            Epub.Allocation_Stats.Record_Allocation
              (Epub.Allocation_Stats.Count (Container.Data.all (Position).all'Size / 8));
         end loop;
      end if;
   exception
      when others =>
         Finalize (Container);
         raise;
   end Adjust;

   overriding procedure Finalize (Container : in out Vector) is
   begin
      if Container.Data /= null then
         for Position in Container.Data.all'Range loop
            Free_Element (Container.Data.all (Position));
         end loop;
      end if;
      Free (Container.Data);
      Container.Used := 0;
   end Finalize;

   function Element (Container : Vector; Position : Natural) return Element_Type is
   begin
      if not Has_Element (Container, Position) then
         raise Constraint_Error with "Invalid list index";
      end if;
      return Container.Data.all (Position).all;
   end Element;

   procedure Query_Element (Container : Vector; Position : Natural) is
   begin
      if not Has_Element (Container, Position) then
         raise Constraint_Error with "Invalid list index";
      end if;
      Process (Container.Data.all (Position).all);
   end Query_Element;

   function First (Container : Vector) return Natural is
      pragma Unreferenced (Container);
   begin
      return 1;
   end First;

   function Next (Container : Vector; Position : Natural) return Natural is
      pragma Unreferenced (Container);
   begin
      return Position + 1;
   end Next;

   function Has_Element (Container : Vector; Position : Natural) return Boolean is
     (Position in 1 .. Container.Used);
   function Is_Empty (Container : Vector) return Boolean is (Container.Used = 0);
   function Last_Index (Container : Vector) return Natural is (Container.Used);
   function Last_Element (Container : Vector) return Element_Type is
     (Element (Container, Container.Used));

   procedure Append (Container : in out Vector; Item : Element_Type) is
   begin
      if Container.Data = null or else Container.Used = Container.Data.all'Length then
         declare
            Capacity : constant Positive :=
              (if Container.Data = null then 8 else Container.Data.all'Length * 2);
            New_Data : constant Array_Access := new Element_Array (1 .. Capacity);
         begin
            Epub.Allocation_Stats.Record_Allocation (Epub.Allocation_Stats.Count (New_Data.all'Size / 8));
            if Container.Data /= null then
               New_Data.all (1 .. Container.Used) :=
                 Container.Data.all (1 .. Container.Used);
            end if;
            Free (Container.Data);
            Container.Data := New_Data;
         end;
      end if;
      Container.Data.all (Container.Used + 1) := new Element_Type'(Item);
      Epub.Allocation_Stats.Record_Allocation (Epub.Allocation_Stats.Count (Item'Size / 8));
      Container.Used := Container.Used + 1;
   end Append;

   procedure Delete_Last (Container : in out Vector) is
   begin
      if Container.Used = 0 then
         raise Constraint_Error with "Empty list";
      end if;
      Free_Element (Container.Data.all (Container.Used));
      Container.Used := Container.Used - 1;
   end Delete_Last;

   procedure Replace_Element
     (Container : in out Vector; Position : Positive; Item : Element_Type) is
   begin
      if not Has_Element (Container, Position) then
         raise Constraint_Error with "Invalid list index";
      end if;
      declare
         Replacement : constant Element_Access := new Element_Type'(Item);
      begin
         Epub.Allocation_Stats.Record_Allocation (Epub.Allocation_Stats.Count (Item'Size / 8));
         Free_Element (Container.Data.all (Position));
         Container.Data.all (Position) := Replacement;
      end;
   end Replace_Element;
end Epub.Lists;

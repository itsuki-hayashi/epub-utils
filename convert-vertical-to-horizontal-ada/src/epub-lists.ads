with Ada.Finalization;

generic
   type Element_Type (<>) is private;
package Epub.Lists is
   pragma Preelaborate;
   type Vector is new Ada.Finalization.Controlled with private
     with Constant_Indexing => Element,
       Iterable => (First => First, Next => Next,
                    Has_Element => Has_Element, Element => Element);
   function Element (Container : Vector; Position : Natural) return Element_Type;
   generic
      --  Process must not mutate Container; its argument is valid for this call.
      with procedure Process (Item : Element_Type);
   procedure Query_Element (Container : Vector; Position : Natural);
   function First (Container : Vector) return Natural;
   function Next (Container : Vector; Position : Natural) return Natural;
   function Has_Element (Container : Vector; Position : Natural) return Boolean;
   function Is_Empty (Container : Vector) return Boolean;
   function Last_Index (Container : Vector) return Natural;
   function Last_Element (Container : Vector) return Element_Type;
   procedure Append (Container : in out Vector; Item : Element_Type);
   procedure Delete_Last (Container : in out Vector);
   procedure Replace_Element
     (Container : in out Vector; Position : Positive; Item : Element_Type);
private
   type Element_Access is access Element_Type;
   type Element_Array is array (Positive range <>) of Element_Access;
   type Array_Access is access Element_Array;
   type Vector is new Ada.Finalization.Controlled with record
      Data : Array_Access := null;
      Used : Natural := 0;
   end record;
   overriding procedure Adjust (Container : in out Vector);
   overriding procedure Finalize (Container : in out Vector);
end Epub.Lists;

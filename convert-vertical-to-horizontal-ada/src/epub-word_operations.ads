with Interfaces;

package Epub.Word_Operations is
   generic
      type Index_Type is range <>;
      type Byte_Array is array (Index_Type range <>) of Interfaces.Unsigned_8;
   function Matching_Prefix
     (Data : Byte_Array; Left, Right : Index_Type; Limit : Natural) return Natural
   with Pre => Limit = 0 or else
     (Left in Data'Range and then Right in Data'Range and then
      Limit - 1 <= Natural (Data'Last - Left) and then Limit - 1 <= Natural (Data'Last - Right)),
     Post => Matching_Prefix'Result <= Limit;
end Epub.Word_Operations;

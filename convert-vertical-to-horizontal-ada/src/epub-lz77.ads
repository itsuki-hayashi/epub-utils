with Interfaces;

--  Application-owned match finders. Production selects the level-9 lazy
--  matcher; Rich remains available for baseline comparison in codec tests.
--  No dependency sources are patched or replaced in caches.
package Epub.LZ77 is
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (Natural range <>) of Byte;
   subtype Distance_Type is Positive;
   type Match_Prefix is array (Positive range 1 .. 14) of Byte;
   type Match_Strategy is (Rich, Info_Zip_9, Info_Zip_9_Knuth);
   subtype Chain_Limit is Positive range 1 .. 4096;
   generic
      with function Read_Byte return Byte;
      with function More_Bytes return Boolean;
      with procedure Write_Literal (Value : Byte);
      with procedure Write_DL_Code (Distance : Distance_Type; Length : Integer; Prefix : Match_Prefix);
      Strategy : Match_Strategy := Info_Zip_9;
      Bulk_Input : Boolean := False;
      with procedure Read_Span (Buffer : out Byte_Array; Count : out Natural) is null;
   procedure Encode (Maximum_Chain : Chain_Limit := 4096);
end Epub.LZ77;

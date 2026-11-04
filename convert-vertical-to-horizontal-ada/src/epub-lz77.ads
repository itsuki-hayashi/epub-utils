with Interfaces;

--  Application-owned match finders. Production selects the level-9 lazy
--  matcher; Rich remains available for baseline comparison in codec tests.
--  No dependency sources are patched or replaced in caches.
package Epub.LZ77 is
   subtype Byte is Interfaces.Unsigned_8;
   subtype Distance_Type is Positive;
   type Match_Prefix is array (Positive range 1 .. 14) of Byte;
   type Match_Strategy is (Rich, Info_Zip_9);
   generic
      with function Read_Byte return Byte;
      with function More_Bytes return Boolean;
      with procedure Write_Literal (Value : Byte);
      with procedure Write_DL_Code (Distance : Distance_Type; Length : Integer; Prefix : Match_Prefix);
      Strategy : Match_Strategy := Info_Zip_9;
   procedure Encode;
end Epub.LZ77;

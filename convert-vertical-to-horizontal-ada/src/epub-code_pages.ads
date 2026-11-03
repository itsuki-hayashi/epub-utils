--  Strict Windows code page 932 conversion, implemented per platform.
package Epub.Code_Pages is
   function Decode (Bytes : String) return String;
   function Encode (Value : String) return String;
end Epub.Code_Pages;

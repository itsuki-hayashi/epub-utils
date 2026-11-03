with Ada.Strings.Unbounded;

package Epub.Encoding is
   type Encoding_Kind is (UTF8, UTF16_LE, UTF16_BE, CP932);
   type Payload is private;
   function Decode (Bytes : String) return Payload;
   function Text (Item : Payload) return String;
   function Encode (Item : Payload; New_Text : String) return String;
   function From_UTF8 (Value : String; Kind : Encoding_Kind) return String;
   Invalid_Encoding : exception;
private
   type Payload is record
      Original, Decoded, Prefix : Ada.Strings.Unbounded.Unbounded_String;
      Kind : Encoding_Kind := UTF8;
   end record;
end Epub.Encoding;

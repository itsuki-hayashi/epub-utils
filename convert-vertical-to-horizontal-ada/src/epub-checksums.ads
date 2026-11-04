with Interfaces;
with Zip;

--  IEEE CRC-32 used by ZIP, not the CRC-32C polynomial of the SSE4.2 CRC instruction.
package Epub.Checksums is
   procedure Init (CRC : out Interfaces.Unsigned_32);
   procedure Update (CRC : in out Interfaces.Unsigned_32; Bytes : Zip.Byte_Buffer);
   function Final (CRC : Interfaces.Unsigned_32) return Interfaces.Unsigned_32;
   function CRC32 (Bytes : String) return Interfaces.Unsigned_32;
end Epub.Checksums;

private package Epub.Checksums.Hardware is
   function Available return Boolean;
   procedure Update (CRC : in out Interfaces.Unsigned_32; Bytes : Zip.Byte_Buffer)
     with Pre => Bytes'Length >= 64 and then Bytes'Length mod 16 = 0;
   pragma Machine_Attribute (Update, "target", "pclmul,sse2");
end Epub.Checksums.Hardware;

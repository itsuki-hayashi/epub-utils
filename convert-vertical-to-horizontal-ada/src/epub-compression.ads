--  Owned stream orchestration adapted from MIT-licensed Zip-Ada 62.0.0.
--  Original notice and component attributions: CODEC_ORIGINS.md.
with Interfaces;
with Zip;
with Zip_Streams;

package Epub.Compression is
   --  Fast_Trial bounds match-chain search for unchanged archive resources.
   --  Callers may select it only when a validated original compressed stream
   --  remains available as a smaller-output fallback.
   procedure Compress
     (Input, Output : in out Zip_Streams.Root_Zipstream_Type'Class;
      Input_Size : Zip.Zip_64_Data_Size_Type; Store_Only : Boolean;
      CRC : out Interfaces.Unsigned_32; Output_Size : out Zip.Zip_64_Data_Size_Type;
      Method : out Interfaces.Unsigned_16; Fast_Trial : Boolean := False);
private
   use Zip;
   type Integer_M32 is range -(2 ** 63) .. 2 ** 63 - 1;
   subtype Natural_M32 is Integer_M32 range 0 .. Integer_M32'Last;
   subtype Positive_M32 is Integer_M32 range 1 .. Integer_M32'Last;
   type IO_Buffers_Type is record
      InBuf, OutBuf : p_Byte_Buffer;
      InBufIdx : Positive := 1;
      OutBufIdx : Positive := 1;
      MaxInBufIdx : Natural := 0;
      InputEoF : Boolean := False;
   end record;
   procedure Allocate_Buffers
     (B : in out IO_Buffers_Type; Input_Size : Zip_64_Data_Size_Type);
   procedure Deallocate_Buffers (B : in out IO_Buffers_Type);
   procedure Read_Block
     (B : in out IO_Buffers_Type; Input : in out Zip_Streams.Root_Zipstream_Type'Class;
      CRC : in out Interfaces.Unsigned_32);
   procedure Write_Block
     (B : in out IO_Buffers_Type; Input_Size : Zip_64_Data_Size_Type;
      Output : in out Zip_Streams.Root_Zipstream_Type'Class;
      Output_Size : in out Zip_64_Data_Size_Type);
   Compression_Inefficient : exception;
end Epub.Compression;

with Epub.Checksums;
--  Owned stream orchestration adapted from MIT-licensed Zip-Ada 62.0.0.
--  Original notice and component attributions: CODEC_ORIGINS.md.
with Ada.Unchecked_Deallocation;
with Epub.Compression.Deflate;

package body Epub.Compression is
   use type Interfaces.Unsigned_64;
   use type Zip_Streams.ZS_Size_Type;
   procedure Allocate_Buffers
     (B : in out IO_Buffers_Type; Input_Size : Zip_64_Data_Size_Type) is
      Amount : constant Zip_64_Data_Size_Type :=
        Zip_64_Data_Size_Type'Min (32_768, Zip_64_Data_Size_Type'Max (8, Input_Size));
   begin
      B.InBuf := new Byte_Buffer (1 .. Integer (Amount));
      B.OutBuf := new Byte_Buffer (1 .. 32_768);
   end Allocate_Buffers;
   procedure Deallocate_Buffers (B : in out IO_Buffers_Type) is
      procedure Free is new Ada.Unchecked_Deallocation (Byte_Buffer, p_Byte_Buffer);
   begin
      Free (B.InBuf);
      Free (B.OutBuf);
   end Deallocate_Buffers;
   procedure Read_Block
     (B : in out IO_Buffers_Type; Input : in out Zip_Streams.Root_Zipstream_Type'Class;
      CRC : in out Interfaces.Unsigned_32) is
   begin
      Zip.Block_Read (Input, B.InBuf.all, B.MaxInBufIdx);
      B.InputEoF := B.MaxInBufIdx = 0;
      B.InBufIdx := 1;
      Epub.Checksums.Update (CRC, B.InBuf.all (1 .. B.MaxInBufIdx));
   end Read_Block;
   procedure Write_Block
     (B : in out IO_Buffers_Type; Input_Size : Zip_64_Data_Size_Type;
      Output : in out Zip_Streams.Root_Zipstream_Type'Class;
      Output_Size : in out Zip_64_Data_Size_Type) is
      Amount : constant Natural := B.OutBufIdx - 1;
   begin
      Output_Size := Output_Size + Zip_64_Data_Size_Type (Amount);
      if Output_Size >= Input_Size then
         raise Compression_Inefficient;
      end if;
      Zip.Block_Write (Output, B.OutBuf.all (1 .. Amount));
      B.OutBufIdx := 1;
   end Write_Block;

   procedure Compress
     (Input, Output : in out Zip_Streams.Root_Zipstream_Type'Class;
      Input_Size : Zip_64_Data_Size_Type; Store_Only : Boolean;
      CRC : out Interfaces.Unsigned_32; Output_Size : out Zip_64_Data_Size_Type;
      Method : out Interfaces.Unsigned_16) is
      Source_Start : constant Zip_Streams.ZS_Index_Type := Input.Index;
      Output_Start : constant Zip_Streams.ZS_Index_Type := Output.Index;
      Effective : Boolean := False;
   begin
      Epub.Checksums.Init (CRC);
      Output_Size := 0;
      if not Store_Only and then Input_Size > 0 then
         Deflate (Input, Output, Input_Size, CRC, Output_Size, Effective);
      end if;
      if Effective then
         Method := 8;
      else
         if Input.Index /= Source_Start then
            Input.Set_Index (Source_Start);
         end if;
         if Output.Index /= Output_Start then
            Output.Set_Index (Output_Start);
         end if;
         Epub.Checksums.Init (CRC);
         Output_Size := 0;
         declare
            Buffer : Byte_Buffer (1 .. 32_768);
            Count : Natural;
         begin
            loop
               Zip.Block_Read (Input, Buffer, Count);
               exit when Count = 0;
               Epub.Checksums.Update (CRC, Buffer (1 .. Count));
               Zip.Block_Write (Output, Buffer (1 .. Count));
               Output_Size := Output_Size + Zip_64_Data_Size_Type (Count);
            end loop;
         end;
         Method := 0;
      end if;
      CRC := Epub.Checksums.Final (CRC);
   end Compress;
end Epub.Compression;

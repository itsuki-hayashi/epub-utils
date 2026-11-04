with Zip.Headers;
with Zip_Streams;

--  An owned adapter to Zip-Ada's private lower-level decompression API. The
--  caller supplies a stream containing only the compressed payload and sizes
--  already validated against the archive catalogue and any data descriptor.
package UnZip.Epub_Decompression is
   function Decode
     (Source_Stream : in out Zip_Streams.Root_Zipstream_Type'Class;
      Metadata : Zip.Headers.Local_File_Header) return String;
   --  Retained for uncommon ZIP methods and independent decoder tests.
   function Decode_Compatibility
     (Source_Stream : in out Zip_Streams.Root_Zipstream_Type'Class;
      Metadata : Zip.Headers.Local_File_Header) return String;
   Invalid_Payload : exception;
end UnZip.Epub_Decompression;

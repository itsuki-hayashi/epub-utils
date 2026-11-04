with Zip.Headers;
with Zip_Streams;

--  Owned RFC 1951 decoder for the two common EPUB ZIP methods. Other ZIP
--  methods remain supported through the existing compatibility adapter.
package Epub.Inflate is
   function Decode
     (Input : in out Zip_Streams.Root_Zipstream_Type'Class;
      Metadata : Zip.Headers.Local_File_Header) return String;
   Invalid_Stream : exception;
end Epub.Inflate;

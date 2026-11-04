with Zip_Streams;

package Epub.Stream_IO is
   function Digest (Input : in out Zip_Streams.Root_Zipstream_Type'Class) return String;
   procedure Copy
     (Input, Output : in out Zip_Streams.Root_Zipstream_Type'Class);
end Epub.Stream_IO;

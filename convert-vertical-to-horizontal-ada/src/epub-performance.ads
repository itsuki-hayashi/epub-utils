--  Release bodies are null and inlined; profiling never changes report JSON.
package Epub.Performance is
   type Phase is (Input_Read, Archive_Read, Analysis, Patch_Planning,
                  Compression, Hashing, Verification, Output_Write, Publication,
                  Decompression, Text_Decoding, XML_Parsing, Match_Finding,
                  Huffman_Building, Entropy_Encoding, Native_IO,
                  XML_Summary_Construction, XML_Summary_Consumption);
   type Counter is (Member_Decodes, Repeated_Member_Decodes, Text_Decodes,
                    Match_Searches, Match_Candidates, Matcher_Input_Bytes,
                    Compression_Allocations, Native_Reads, Native_Writes,
                    Native_Seeks, Bytes_Read, Bytes_Written,
                    XML_Contexts, XML_Facts, XML_Bytes_Copied);
   procedure Begin_Book with Inline_Always;
   function New_Book return Natural with Inline_Always;
   procedure Begin_Job (Book : Natural) with Inline_Always;
   procedure End_Task with Inline_Always;
   procedure Add (Kind : Counter; Amount : Natural := 1) with Inline_Always;
   procedure Resource_Decode (Ordinal : Positive) with Inline_Always;
   procedure Start (Kind : Phase) with Inline_Always;
   procedure Stop (Kind : Phase) with Inline_Always;
   procedure Dump;
end Epub.Performance;

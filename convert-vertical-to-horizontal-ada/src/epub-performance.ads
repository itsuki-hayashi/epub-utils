--  Release bodies are null and inlined; profiling never changes report JSON.
package Epub.Performance is
   type Phase is (Input_Read, Archive_Read, Analysis, Patch_Planning,
                  Compression, Hashing, Verification, Output_Write, Publication);
   procedure Start (Kind : Phase) with Inline_Always;
   procedure Stop (Kind : Phase) with Inline_Always;
   procedure Dump;
end Epub.Performance;

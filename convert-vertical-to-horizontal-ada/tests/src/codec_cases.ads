with AUnit;
with AUnit.Simple_Test_Cases;

package Codec_Cases is
   type Case_Kind is (Huffman_Differential, Word_Matches, CRC_Compatibility, Match_Tokens,
                     Huffman_Exhaustive, SHA_Differential);
   function Create (Kind : Case_Kind) return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Huffman_Differential;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Codec_Cases;

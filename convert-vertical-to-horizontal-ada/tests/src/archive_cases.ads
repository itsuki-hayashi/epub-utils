with AUnit;
with AUnit.Simple_Test_Cases;

package Archive_Cases is
   type Case_Kind is (Metadata_Roundtrip, Zip64_Roundtrip, Unicode_And_Empty,
                      Corrupt_Payload, Fixture_Roundtrips, Book_Payload_Parity,
                      Header_Consistency, ZIP64_Field_Bounds, Archive_Region_Bounds,
                      Case_Sensitive_Names, Data_Descriptors, Duplicate_ZIP64_Fields,
                      Entry_Overlap, Mimetype_Flags);
   function Create (Kind : Case_Kind)
      return AUnit.Simple_Test_Cases.Test_Case_Access;
private
   type Unit_Case is new AUnit.Simple_Test_Cases.Test_Case with record
      Kind : Case_Kind := Metadata_Roundtrip;
   end record;
   overriding function Name (Item : Unit_Case) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Unit_Case);
end Archive_Cases;

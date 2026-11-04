with Ada.Command_Line;
with AUnit;
with AUnit.Reporter.Text;
with AUnit.Run;
with AUnit.Test_Suites;
with Text_Cases;
with Archive_Cases;
with Core_Cases;
with Book_Cases;
with Report_Cases;
with Codec_Cases;
with Stream_Cases;
with Inflate_Cases;

procedure Linux_Runner is
   use type AUnit.Status;
   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite := AUnit.Test_Suites.New_Suite;
   begin
      for Kind in Text_Cases.Case_Kind loop
         Result.all.Add_Test (Text_Cases.Create (Kind));
      end loop;
      for Kind in Archive_Cases.Case_Kind loop
         Result.all.Add_Test (Archive_Cases.Create (Kind));
      end loop;
      for Kind in Core_Cases.Case_Kind loop
         Result.all.Add_Test (Core_Cases.Create (Kind));
      end loop;
      for Kind in Codec_Cases.Case_Kind loop
         Result.all.Add_Test (Codec_Cases.Create (Kind));
      end loop;
      for Kind in Stream_Cases.Case_Kind loop
         Result.all.Add_Test (Stream_Cases.Create (Kind));
      end loop;
      for Kind in Inflate_Cases.Case_Kind loop
         Result.all.Add_Test (Inflate_Cases.Create (Kind));
      end loop;
      for Kind in Book_Cases.Case_Kind loop
         Result.all.Add_Test (Book_Cases.Create (Kind));
      end loop;
      for Kind in Report_Cases.Case_Kind loop
         Result.all.Add_Test (Report_Cases.Create (Kind));
      end loop;
      return Result;
   end Suite;
   function Run is new AUnit.Run.Test_Runner_With_Status (Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
begin
   if Run (Reporter) /= AUnit.Success then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Linux_Runner;

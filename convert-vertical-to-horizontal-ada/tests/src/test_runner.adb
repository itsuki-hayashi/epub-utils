with Ada.Command_Line;
with AUnit;
with AUnit.Reporter.Text;
with AUnit.Run;
with AUnit.Test_Suites;
with Text_Cases;
with Archive_Cases;
with Windows_Cases;
with Core_Cases;
with Book_Cases;
with Fault_Cases;
with Native_Faults;
with Report_Cases;

procedure Test_Runner is
   use type AUnit.Status;
   use type Native_Faults.Operation;
   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite := AUnit.Test_Suites.New_Suite;
   begin
      for Kind in Text_Cases.Case_Kind loop
         Result.all.Add_Test (Text_Cases.Create (Kind));
      end loop;
      for Kind in Archive_Cases.Case_Kind loop
         Result.all.Add_Test (Archive_Cases.Create (Kind));
      end loop;
      for Kind in Windows_Cases.Case_Kind loop
         Result.all.Add_Test (Windows_Cases.Create (Kind));
      end loop;
      for Kind in Core_Cases.Case_Kind loop
         Result.all.Add_Test (Core_Cases.Create (Kind));
      end loop;
      for Kind in Book_Cases.Case_Kind loop
         Result.all.Add_Test (Book_Cases.Create (Kind));
      end loop;
      for Kind in Report_Cases.Case_Kind loop
         Result.all.Add_Test (Report_Cases.Create (Kind));
      end loop;
      for Kind in Native_Faults.Operation loop
         if Kind /= Native_Faults.None then
            Result.all.Add_Test (Fault_Cases.Create (Kind));
         end if;
      end loop;
      Result.all.Add_Test (Fault_Cases.Create (Native_Faults.Current_Directory, Skip => 1));
      Result.all.Add_Test (Fault_Cases.Create (Native_Faults.Full_Path, Skip => 1));
      return Result;
   end Suite;
   function Run is new AUnit.Run.Test_Runner_With_Status (Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
begin
   if Run (Reporter) /= AUnit.Success then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Runner;

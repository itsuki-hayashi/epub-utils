with Interfaces.C;

package body Native_Faults is
   procedure Set_Failure (Kind : Interfaces.C.int; Skip : Interfaces.C.unsigned)
     with Import, Convention => C, External_Name => "epub_test_fail_next";
   procedure Set_Write_Then_Close
     with Import, Convention => C, External_Name => "epub_test_fail_write_then_close";
   procedure Arm_Write_Then_Close is
   begin
      Set_Write_Then_Close;
   end Arm_Write_Then_Close;
   procedure Arm (Kind : Operation; Skip : Natural := 0) is
   begin
      Set_Failure (Operation'Pos (Kind), Interfaces.C.unsigned (Skip));
   end Arm;
end Native_Faults;

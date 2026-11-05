package Native_Faults is
   type Operation is (None, Open_File, Read_File, Zero_Read, Write_File, Zero_Write,
                      Flush_File, Close_File, Move_File, Delete_File, File_Size,
                      File_Attributes, Create_Directory, Find_First, Find_Next,
                      Close_Search, Current_Directory, Full_Path, Arguments,
                      Free_Arguments, Console_Codepage);
   procedure Arm (Kind : Operation; Skip : Natural := 0);
   procedure Arm_Write_Then_Close;
   procedure Arm_Output_Close (Skip : Natural);
end Native_Faults;

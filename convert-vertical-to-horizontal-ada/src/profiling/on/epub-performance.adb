with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Text_IO;

package body Epub.Performance is
   use type Ada.Real_Time.Time;
   Beginnings : array (Phase) of Ada.Real_Time.Time := [others => Ada.Real_Time.Time_First];
   Totals : array (Phase) of Duration := [others => 0.0];
   Calls : array (Phase) of Natural := [others => 0];
   procedure Start (Kind : Phase) is
   begin
      Beginnings (Kind) := Ada.Real_Time.Clock;
   end Start;
   procedure Stop (Kind : Phase) is
   begin
      Totals (Kind) := Totals (Kind) + Ada.Real_Time.To_Duration
        (Ada.Real_Time.Clock - Beginnings (Kind));
      Calls (Kind) := Calls (Kind) + 1;
   end Stop;
   procedure Dump is
      File : Ada.Text_IO.File_Type;
   begin
      if Ada.Environment_Variables.Exists ("EPUB_PROFILE_PATH") then
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File,
           Ada.Environment_Variables.Value ("EPUB_PROFILE_PATH"));
         Ada.Text_IO.Put_Line (File, "phase,inclusive_seconds,calls");
         for Kind in Phase loop
            Ada.Text_IO.Put_Line (File, Kind'Image & "," & Totals (Kind)'Image & "," & Calls (Kind)'Image);
         end loop;
         Ada.Text_IO.Close (File);
      end if;
   end Dump;
end Epub.Performance;

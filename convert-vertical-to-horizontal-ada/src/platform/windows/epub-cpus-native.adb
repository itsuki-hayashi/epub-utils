with Ada.Unchecked_Conversion;
with Interfaces;
with Interfaces.C;
with System;

package body Epub.CPUs.Native is
   use Interfaces;
   use type Interfaces.C.int;
   use type System.Address;
   function Current_Process return System.Address
     with Import, Convention => Stdcall, External_Name => "GetCurrentProcess";
   function Current_Thread return System.Address
     with Import, Convention => Stdcall, External_Name => "GetCurrentThread";
   function Module (Name : System.Address) return System.Address
     with Import, Convention => Stdcall, External_Name => "GetModuleHandleA";
   function Symbol (Handle, Name : System.Address) return System.Address
     with Import, Convention => Stdcall, External_Name => "GetProcAddress";
   function Affinity (Handle, Process_Mask, System_Mask : System.Address) return Interfaces.C.int
     with Import, Convention => Stdcall, External_Name => "GetProcessAffinityMask";
   type Query_Sets is access function
     (Data : System.Address; Length : Unsigned_32; Used : System.Address;
      Handle : System.Address; Flags : Unsigned_32) return Interfaces.C.int with Convention => Stdcall;
   type Query_Defaults is access function
     (Handle, Data : System.Address; Length : Unsigned_32; Used : System.Address)
      return Interfaces.C.int with Convention => Stdcall;
   type Query_Relationships is access function
     (Kind : Unsigned_32; Data, Length : System.Address) return Interfaces.C.int with Convention => Stdcall;
   type Reserved_Words is array (1 .. 3) of Unsigned_16 with Convention => C;
   type Group_Affinity is record
      Mask : Unsigned_64 := 0;
      Group : Unsigned_16 := 0;
      Reserved : Reserved_Words := [others => 0];
   end record with Convention => C;
   type Query_Group is access function (Handle, Data : System.Address) return Interfaces.C.int
     with Convention => Stdcall;
   type Set_Group is access function (Handle, Data, Previous : System.Address) return Interfaces.C.int
     with Convention => Stdcall;
   type Query_Groups is access function (Handle, Count, Groups : System.Address) return Interfaces.C.int
     with Convention => Stdcall;
   function To_Query is new Ada.Unchecked_Conversion (System.Address, Query_Sets);
   function To_Defaults is new Ada.Unchecked_Conversion (System.Address, Query_Defaults);
   function To_Relationships is new Ada.Unchecked_Conversion (System.Address, Query_Relationships);
   function To_Group is new Ada.Unchecked_Conversion (System.Address, Query_Group);
   function To_Set is new Ada.Unchecked_Conversion (System.Address, Set_Group);
   function To_Groups is new Ada.Unchecked_Conversion (System.Address, Query_Groups);
   function Lookup (Name : String) return System.Address is
      Library_Name : constant String := "kernel32.dll" & Character'Val (0);
      Entry_Name : constant String := Name & Character'Val (0);
   begin
      return Symbol (Module (Library_Name'Address), Entry_Name'Address);
   end Lookup;
   type Bytes is array (Natural range <>) of Unsigned_8;
   function Word (Data : Bytes; Offset, Width : Natural) return Unsigned_32 is
      Value : Unsigned_32 := 0;
   begin
      if Width > 4 or else Offset > Data'Last or else Width > Data'Last - Offset + 1 then
         raise Constraint_Error with "Truncated CPU topology record";
      end if;
      for Part in reverse Offset .. Offset + Width - 1 loop
         Value := Shift_Left (Value, 8) or Unsigned_32 (Data (Part));
      end loop;
      return Value;
   end Word;

   function Probe return Processor_Lists.Vector is
      Result : Processor_Lists.Vector;
      Query : constant Query_Sets := To_Query (Lookup ("GetSystemCpuSetInformation"));
      Defaults : constant Query_Defaults := To_Defaults (Lookup ("GetProcessDefaultCpuSets"));
      Get_Group : constant Query_Group := To_Group (Lookup ("GetThreadGroupAffinity"));
      Get_Groups : constant Query_Groups := To_Groups (Lookup ("GetProcessGroupAffinity"));
      Groups : aliased array (1 .. 64) of Unsigned_16 := [others => 0];
      Group_Count : aliased Unsigned_16 := Groups'Length;
      Process_Mask, System_Mask : aliased Unsigned_64 := 0;
      This_Group : aliased Group_Affinity;
      Restrict_Group : Boolean := False;
      Needed : aliased Unsigned_32 := 0;
      Ignore : Interfaces.C.int;
      Default_Count : aliased Unsigned_32 := 0;
      function Allowed (Group, Logical : Natural) return Boolean is
         Found : Boolean := False;
      begin
         for Index in 1 .. Natural (Group_Count) loop
            Found := Found or else Group = Natural (Groups (Index));
         end loop;
         return Found and then (not Restrict_Group or else
           (Group = Natural (This_Group.Group) and then Logical < 64 and then
            (Process_Mask and Shift_Left (Unsigned_64'(1), Logical)) /= 0));
      end Allowed;
   begin
      if Get_Groups = null or else
        Get_Groups (Current_Process, Group_Count'Address, Groups'Address) = 0 or else
        Group_Count = 0 or else Group_Count > Groups'Length
      then
         return Result;
      end if;
      if Get_Group /= null then
         Ignore := Get_Group (Current_Thread, This_Group'Address);
      end if;
      if Affinity (Current_Process, Process_Mask'Address, System_Mask'Address) /= 0 then
         Restrict_Group := Process_Mask /= 0 and then Process_Mask /= System_Mask;
      end if;
      if Query /= null then
         Ignore := Query (System.Null_Address, 0, Needed'Address, Current_Process, 0);
      end if;
      if Query /= null and then Needed >= 24 then
         declare
            Data : aliased Bytes (0 .. Natural (Needed) - 1);
            type Identifiers is array (Natural range <>) of Unsigned_32;
            Offset : Natural := 0;
         begin
            if Defaults /= null then
               Ignore := Defaults (Current_Process, System.Null_Address, 0, Default_Count'Address);
            end if;
            declare
               IDs : aliased Identifiers (1 .. Natural (Default_Count));
            begin
               if IDs'Length > 0 and then
                 Defaults (Current_Process, IDs'Address, Default_Count, Default_Count'Address) = 0
               then
                  return Result;
               end if;
               if Query (Data'Address, Needed, Needed'Address, Current_Process, 0) = 0 then
                  return Result;
               end if;
               while Offset < Data'Length loop
                  declare
                     Length : constant Natural := Natural (Word (Data, Offset, 4));
                  begin
                     if Length < 8 or else Length > Data'Length - Offset then
                        return Processor_Lists.Vector'(Result);
                     end if;
                     if Word (Data, Offset + 4, 4) = 0 and then Length >= 24 then
                        declare
                           CPU : Processor :=
                             (Group => Natural (Word (Data, Offset + 12, 2)),
                              Logical => Natural (Data (Offset + 14)), Core => Natural (Data (Offset + 15)),
                              Efficiency => Natural (Data (Offset + 18)),
                              Allowed => True, Physical_Known => True, Class_Known => True);
                           ID_Allowed : Boolean := IDs'Length = 0;
                        begin
                           for ID of IDs loop
                              ID_Allowed := ID_Allowed or else ID = Word (Data, Offset + 8, 4);
                           end loop;
                           CPU.Allowed := ID_Allowed and then
                             ((Data (Offset + 19) and 2) = 0 or else (Data (Offset + 19) and 4) /= 0)
                             and then Allowed (CPU.Group, CPU.Logical);
                           Result.Append (CPU);
                        end;
                     end if;
                     Offset := Offset + Length;
                  end;
               end loop;
            end;
         end;
      else
         declare
            Relationships : constant Query_Relationships :=
              To_Relationships (Lookup ("GetLogicalProcessorInformationEx"));
         begin
            if Relationships = null then
               return Result;
            end if;
            Ignore := Relationships (0, System.Null_Address, Needed'Address);
            declare
               Data : aliased Bytes (0 .. Natural (Needed) - 1);
               Offset, Core : Natural := 0;
            begin
               if Relationships (0, Data'Address, Needed'Address) = 0 then
                  return Result;
               end if;
               while Offset < Data'Length loop
                  declare
                     Length : constant Natural := Natural (Word (Data, Offset + 4, 4));
                  begin
                     if Length < 48 or else Length > Data'Length - Offset then
                        return Result;
                     end if;
                     if Word (Data, Offset, 4) = 0 and then Word (Data, Offset + 30, 2) = 1 then
                        for Bit in 0 .. 63 loop
                           if (Data (Offset + 32 + Bit / 8) and Shift_Left (Unsigned_8'(1), Bit mod 8)) /= 0 then
                              declare
                                 Group : constant Natural := Natural (Word (Data, Offset + 40, 2));
                                 Is_Allowed : constant Boolean := Allowed (Group, Bit);
                              begin
                                 Result.Append ((Group, Bit, Core, 0, Is_Allowed, True, False));
                              end;
                           end if;
                        end loop;
                        Core := Core + 1;
                     end if;
                     Offset := Offset + Length;
                  end;
               end loop;
            end;
         end;
      end if;
      return Result;
   exception
      when Constraint_Error =>
         declare
            Empty : Processor_Lists.Vector;
         begin
            return Empty;
         end;
   end Probe;

   procedure Bind (Core : Processor) is
      Set : constant Set_Group := To_Set (Lookup ("SetThreadGroupAffinity"));
      Get : constant Query_Group := To_Group (Lookup ("GetThreadGroupAffinity"));
   begin
      if Core.Logical >= 64 or else Core.Group > Natural (Unsigned_16'Last) or else Set = null or else Get = null
      then
         raise Affinity_Error with "Cannot pin worker to its physical core";
      end if;
      declare
         Target : aliased constant Group_Affinity :=
           (Mask => Shift_Left (Unsigned_64'(1), Core.Logical),
            Group => Unsigned_16 (Core.Group), Reserved => [others => 0]);
         Actual : aliased Group_Affinity;
      begin
         if Set (Current_Thread, Target'Address, System.Null_Address) = 0 then
            raise Affinity_Error with "Cannot pin worker to its physical core";
         end if;
         if Get (Current_Thread, Actual'Address) = 0 or else Actual.Mask /= Target.Mask
           or else Actual.Group /= Target.Group
         then
            raise Affinity_Error with "Worker affinity readback differs from selected core";
         end if;
      end;
   end Bind;
end Epub.CPUs.Native;

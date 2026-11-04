with Epub.Encoding;
with Epub.Files;
with Epub.Windows;
with System.Storage_Elements;

package body Epub.Native_Files is
   package Win renames Epub.Windows;
   use type Win.BOOL;
   use type System.Address;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;
   Invalid_Handle : constant System.Address :=
     System.Storage_Elements.To_Address (System.Storage_Elements.Integer_Address'Last);

   procedure Check (Result : Win.BOOL; Context : String) is
   begin
      if Result = 0 then
         raise File_Error with Context & " (Windows error" & Win.GetLastError'Image & ")";
      end if;
   end Check;

   function Open (Path : String; Exclusive : Boolean) return System.Address is
      function Native_Path return String is
         Absolute : constant String := Epub.Files.Absolute_Path (Path);
         function Wide (Value : String) return String is
           (Epub.Encoding.From_UTF8 (Value, Epub.Encoding.UTF16_LE) &
              Character'Val (0) & Character'Val (0));
      begin
         if Absolute'Length >= 4 and then Absolute (1 .. 4) = "\\?\" then
            return Wide (Absolute);
         elsif Absolute'Length >= 2 and then Absolute (1 .. 2) = "\\" then
            return Wide ("\\?\UNC\" & Absolute (3 .. Absolute'Last));
         else
            return Wide ("\\?\" & Absolute);
         end if;
      end Native_Path;
   begin
      for Value of Path loop
         if Value = Character'Val (0) then
            raise File_Error with "NUL in filesystem path";
         end if;
      end loop;
      declare
         Native : constant String := Native_Path;
         Handle : constant System.Address := Win.CreateFileW
           (Native'Address, (if Exclusive then 16#4000_0000# else 16#8000_0000#),
            (if Exclusive then 0 else 1), System.Null_Address,
            (if Exclusive then 1 else 3), 16#80#, System.Null_Address);
      begin
         if Handle = Invalid_Handle then
            raise File_Error with "Cannot open binary stream (Windows error" & Win.GetLastError'Image & ")";
         end if;
         return Handle;
      end;
   end Open;

   procedure Close (Handle : in out System.Address) is
      Result : constant Win.BOOL := Win.CloseHandle (Handle);
   begin
      Handle := System.Null_Address;
      Check (Result, "Cannot close binary stream");
   end Close;

   function Size (Handle : System.Address) return Interfaces.Unsigned_64 is
      Result : aliased Interfaces.Integer_64;
   begin
      Check (Win.GetFileSizeEx (Handle, Result'Address), "Cannot obtain binary stream size");
      if Result < 0 then
         raise File_Error with "Negative binary stream size";
      end if;
      return Interfaces.Unsigned_64 (Result);
   end Size;

   function Read (Handle, Buffer : System.Address; Count : Natural) return Natural is
      Actual : aliased Win.DWORD;
   begin
      Check (Win.ReadFile (Handle, Buffer, Win.DWORD (Count), Actual'Address, System.Null_Address),
             "Cannot read binary stream");
      return Natural (Actual);
   end Read;

   function Write (Handle, Buffer : System.Address; Count : Natural) return Natural is
      Actual : aliased Win.DWORD;
   begin
      Check (Win.WriteFile (Handle, Buffer, Win.DWORD (Count), Actual'Address, System.Null_Address),
             "Cannot write binary stream");
      return Natural (Actual);
   end Write;

   procedure Seek (Handle : System.Address; Offset : Interfaces.Unsigned_64) is
   begin
      if Offset > Interfaces.Unsigned_64 (Interfaces.Integer_64'Last) then
         raise File_Error with "Binary stream seek overflow";
      end if;
      Check (Win.SetFilePointerEx (Handle, Interfaces.Integer_64 (Offset), System.Null_Address, 0),
             "Cannot seek binary stream");
   end Seek;

   procedure Flush (Handle : System.Address) is
   begin
      Check (Win.FlushFileBuffers (Handle), "Cannot flush binary stream");
   end Flush;
end Epub.Native_Files;

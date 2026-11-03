with Interfaces;
with Interfaces.C;
with System;

package Epub.Windows is
   subtype DWORD is Interfaces.Unsigned_32;
   subtype BOOL is Interfaces.C.int;
   type Wide_Buffer is array (Natural range <>) of Interfaces.Unsigned_16
     with Convention => C;
   type Find_Data is record
      Attributes : DWORD;
      Creation_Low, Creation_High, Access_Low, Access_High, Write_Low, Write_High : DWORD;
      Size_High, Size_Low, Reserved_0, Reserved_1 : DWORD;
      Filename : Wide_Buffer (0 .. 259);
      Alternate_Name : Wide_Buffer (0 .. 13);
   end record with Convention => C;
   function GetLastError return DWORD
     with Import, Convention => Stdcall, External_Name => "GetLastError";
   function GetFileAttributesW (Path : System.Address) return DWORD
     with Import, Convention => Stdcall, External_Name => "GetFileAttributesW";
   function CreateDirectoryW (Path, Security : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "CreateDirectoryW";
   function DeleteFileW (Path : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "DeleteFileW";
   function MoveFileW (Source, Destination : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "MoveFileW";
   function CreateFileW
     (Path : System.Address; Access_Mode, Share_Mode : DWORD;
      Security : System.Address; Creation, Flags : DWORD; Template : System.Address)
      return System.Address
     with Import, Convention => Stdcall, External_Name => "CreateFileW";
   function CloseHandle (Handle : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "CloseHandle";
   function GetFileSizeEx (Handle, Size : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "GetFileSizeEx";
   function ReadFile
     (Handle, Buffer : System.Address; Count : DWORD; Read_Count, Overlapped : System.Address)
      return BOOL
     with Import, Convention => Stdcall, External_Name => "ReadFile";
   function WriteFile
     (Handle, Buffer : System.Address; Count : DWORD; Write_Count, Overlapped : System.Address)
      return BOOL
     with Import, Convention => Stdcall, External_Name => "WriteFile";
   function FlushFileBuffers (Handle : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "FlushFileBuffers";
   function GetFullPathNameW
     (Path : System.Address; Capacity : DWORD; Buffer, File_Part : System.Address) return DWORD
     with Import, Convention => Stdcall, External_Name => "GetFullPathNameW";
   function GetCurrentDirectoryW (Capacity : DWORD; Buffer : System.Address) return DWORD
     with Import, Convention => Stdcall, External_Name => "GetCurrentDirectoryW";
   function FindFirstFileW (Pattern, Data : System.Address) return System.Address
     with Import, Convention => Stdcall, External_Name => "FindFirstFileW";
   function FindNextFileW (Handle, Data : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "FindNextFileW";
   function FindClose (Handle : System.Address) return BOOL
     with Import, Convention => Stdcall, External_Name => "FindClose";
   function GetCommandLineW return System.Address
     with Import, Convention => Stdcall, External_Name => "GetCommandLineW";
   function CommandLineToArgvW (Command, Count : System.Address) return System.Address
     with Import, Convention => Stdcall, External_Name => "CommandLineToArgvW";
   function LocalFree (Pointer : System.Address) return System.Address
     with Import, Convention => Stdcall, External_Name => "LocalFree";
   function GetCurrentProcessId return DWORD
     with Import, Convention => Stdcall, External_Name => "GetCurrentProcessId";
   function SetConsoleOutputCP (Code_Page : DWORD) return BOOL
     with Import, Convention => Stdcall, External_Name => "SetConsoleOutputCP";
end Epub.Windows;

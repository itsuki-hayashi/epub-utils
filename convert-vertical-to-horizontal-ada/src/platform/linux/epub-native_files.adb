with Interfaces.C;
with System.Storage_Elements;

package body Epub.Native_Files is
   use type Interfaces.C.int;
   use type Interfaces.C.long_long;
   use type Interfaces.Unsigned_64;
   use type System.Storage_Elements.Integer_Address;
   function C_Open (Path : String; Exclusive : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_open";
   function C_Close (FD : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_close";
   function C_Size (FD : Interfaces.C.int) return Interfaces.C.long_long
     with Import, Convention => C, External_Name => "epub_size";
   function C_Read (FD : Interfaces.C.int; Buffer : System.Address; Count : Interfaces.C.size_t)
     return Interfaces.C.long_long
     with Import, Convention => C, External_Name => "epub_read";
   function C_Write (FD : Interfaces.C.int; Buffer : System.Address; Count : Interfaces.C.size_t)
     return Interfaces.C.long_long
     with Import, Convention => C, External_Name => "epub_write";
   function C_Seek (FD : Interfaces.C.int; Offset : Interfaces.C.long_long) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_seek";
   function C_Flush (FD : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "epub_flush";
   function FD (Handle : System.Address) return Interfaces.C.int is
     (Interfaces.C.int (System.Storage_Elements.To_Integer (Handle) - 1));

   procedure Check (Result : Interfaces.C.long_long; Context : String) is
   begin
      if Result < 0 then
         raise File_Error with Context & " (errno" & Interfaces.C.long_long'Image (-Result) & ")";
      end if;
   end Check;

   function Open (Path : String; Exclusive : Boolean) return System.Address is
   begin
      for Value of Path loop
         if Value = Character'Val (0) then
            raise File_Error with "NUL in filesystem path";
         end if;
      end loop;
      declare
         Descriptor : constant Interfaces.C.int :=
           C_Open (Path & Character'Val (0), Boolean'Pos (Exclusive));
      begin
         Check (Interfaces.C.long_long (Descriptor), "Cannot open binary stream");
         return System.Storage_Elements.To_Address
           (System.Storage_Elements.Integer_Address (Descriptor) + 1);
      end;
   end Open;

   procedure Close (Handle : in out System.Address) is
      Result : constant Interfaces.C.int := C_Close (FD (Handle));
   begin
      Handle := System.Null_Address;
      Check (Interfaces.C.long_long (Result), "Cannot close binary stream");
   end Close;

   function Size (Handle : System.Address) return Interfaces.Unsigned_64 is
      Result : constant Interfaces.C.long_long := C_Size (FD (Handle));
   begin
      Check (Result, "Cannot obtain binary stream size");
      return Interfaces.Unsigned_64 (Result);
   end Size;

   function Read (Handle, Buffer : System.Address; Count : Natural) return Natural is
      Result : constant Interfaces.C.long_long := C_Read (FD (Handle), Buffer, Interfaces.C.size_t (Count));
   begin
      Check (Result, "Cannot read binary stream");
      return Natural (Result);
   end Read;

   function Write (Handle, Buffer : System.Address; Count : Natural) return Natural is
      Result : constant Interfaces.C.long_long := C_Write (FD (Handle), Buffer, Interfaces.C.size_t (Count));
   begin
      Check (Result, "Cannot write binary stream");
      return Natural (Result);
   end Write;

   procedure Seek (Handle : System.Address; Offset : Interfaces.Unsigned_64) is
   begin
      if Offset > Interfaces.Unsigned_64 (Interfaces.C.long_long'Last) then
         raise File_Error with "Binary stream seek overflow";
      end if;
      Check (Interfaces.C.long_long (C_Seek (FD (Handle), Interfaces.C.long_long (Offset))),
             "Cannot seek binary stream");
   end Seek;

   procedure Flush (Handle : System.Address) is
   begin
      Check (Interfaces.C.long_long (C_Flush (FD (Handle))), "Cannot flush binary stream");
   end Flush;
end Epub.Native_Files;

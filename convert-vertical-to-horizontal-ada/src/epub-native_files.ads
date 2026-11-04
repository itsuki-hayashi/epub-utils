with Interfaces;
with System;

--  Thin platform boundary. Handles and byte addresses stay inside owned I/O.
package Epub.Native_Files is
   type Open_Result is record
      Created, Collision : Boolean := False;
   end record;
   function Open
     (Path : String; Exclusive : Boolean; Outcome : access Open_Result := null) return System.Address;
   procedure Close (Handle : aliased in out System.Address);
   function Size (Handle : System.Address) return Interfaces.Unsigned_64;
   function Read (Handle, Buffer : System.Address; Count : Natural) return Natural;
   function Write (Handle, Buffer : System.Address; Count : Natural) return Natural;
   procedure Seek (Handle : System.Address; Offset : Interfaces.Unsigned_64);
   procedure Flush (Handle : System.Address);
   File_Error : exception;
end Epub.Native_Files;

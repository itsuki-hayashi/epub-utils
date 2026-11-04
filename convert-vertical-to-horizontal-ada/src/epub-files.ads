with Epub.Resources;

package Epub.Files is
   function Arguments return Epub.Resources.String_Lists.Vector;
   function Current_Directory return String;
   function Absolute_Path (Path : String) return String;
   function Join (Directory, Name : String) return String;
   function Parent_Path (Path : String) return String;
   function Basename (Path : String) return String;
   function Exists (Path : String) return Boolean;
   function Is_Directory (Path : String) return Boolean;
   procedure Ensure_Directory (Path : String);
   function Read (Path : String) return String;
   procedure Write_Exclusive (Path, Bytes : String);
   procedure Remove (Path : String);
   procedure Publish (Temporary_Path, Destination : String);
   --  A supplied digest must have been computed from Bytes by the caller.
   --  The persisted bytes are always hashed independently before publication.
   procedure Write_Verified (Destination, Bytes : String; Expected_SHA256 : String := "");
   generic
      with procedure Verify_Bytes (Bytes : String);
   procedure Write_Checked (Destination, Bytes : String; Expected_SHA256 : String := "");
   function EPUB_Files (Path : String; Recursive : Boolean)
      return Epub.Resources.String_Lists.Vector;
   procedure Configure_Console;
   File_Error : exception;
end Epub.Files;

with Ada.Streams;
with GNAT.SHA256;
with Interfaces;

package Epub.Digests is
   type Context is private;
   function Hardware_Available return Boolean;
   function Initial_Context (Software_Only : Boolean := False) return Context;
   procedure Update (Item : in out Context; Bytes : String);
   procedure Update (Item : in out Context; Bytes : Ada.Streams.Stream_Element_Array);
   function Digest (Item : Context) return String;
   function Digest (Bytes : String) return String;
private
   type State_Array is array (Natural range 0 .. 7) of Interfaces.Unsigned_32;
   type Context is record
      Hardware : Boolean := False;
      Software : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
      State : State_Array :=
        [16#6A09E667#, 16#BB67AE85#, 16#3C6EF372#, 16#A54FF53A#,
         16#510E527F#, 16#9B05688C#, 16#1F83D9AB#, 16#5BE0CD19#];
      Block : String (1 .. 64) := [others => Character'Val (0)];
      Used : Natural range 0 .. 63 := 0;
      Bytes : Interfaces.Unsigned_64 := 0;
   end record;
end Epub.Digests;

with Ada.Finalization;
with Ada.Task_Identification;
with Interfaces;
with Input_Sources;
with Sax.Readers;
with Sax.Symbols;

--  Supported concurrent profile: one context belongs to one Ada task. The
--  raw SAX callbacks borrow symbols only while this context is parsing.
package Sax.Contexts is
   type Parse_Context is new Ada.Finalization.Limited_Controlled with private;
   type Release_Handler is access procedure (Reader : in out Sax.Readers.Sax_Reader'Class);
   procedure Adopt
     (Item : in out Parse_Context; Reader : in out Sax.Readers.Sax_Reader_Access;
      Release_Extension : Release_Handler := null);
   --  Adopt transfers reader ownership. All tables/buffers are owned by Item.
   procedure Parse (Item : in out Parse_Context; Input : in out Input_Sources.Input_Source'Class);
   procedure Reset (Item : in out Parse_Context);
   procedure Close (Item : in out Parse_Context);
   type Symbol_Handle is private;
   function Borrow (Item : Parse_Context; Symbol : Sax.Symbols.Symbol) return Symbol_Handle;
   function Value (Item : Parse_Context; Symbol : Symbol_Handle) return String;
private
   type Symbol_Handle is record
      Owner : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Null_Task_Id;
      Context, Generation : Interfaces.Unsigned_64 := 0;
      Symbol : Sax.Symbols.Symbol := Sax.Symbols.No_Symbol;
   end record;
   type Parse_Context is new Ada.Finalization.Limited_Controlled with record
      Owner : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Null_Task_Id;
      Identity, Generation : Interfaces.Unsigned_64 := 0;
      Reader : Sax.Readers.Sax_Reader_Access;
      Table : Sax.Symbols.Symbol_Table_Access;
      Release_Extension : Release_Handler;
      Busy, Closed : Boolean := False;
   end record;
   overriding procedure Initialize (Item : in out Parse_Context);
   overriding procedure Finalize (Item : in out Parse_Context);
end Sax.Contexts;

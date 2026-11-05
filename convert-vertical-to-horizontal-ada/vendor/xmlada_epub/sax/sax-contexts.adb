with Ada.Unchecked_Deallocation;
with Sax.Utils;

package body Sax.Contexts is
   use type Ada.Task_Identification.Task_Id;
   use type Interfaces.Unsigned_64;
   use type Sax.Readers.Sax_Reader_Access;
   use type Sax.Symbols.Symbol_Table_Access;
   use type Sax.Symbols.Symbol;
   Next_Identity : Interfaces.Unsigned_64 := 0;
   pragma Thread_Local_Storage (Next_Identity);
   procedure Dispose is new Ada.Unchecked_Deallocation
     (Sax.Readers.Sax_Reader'Class, Sax.Readers.Sax_Reader_Access);
   procedure Check (Item : Parse_Context) is
   begin
      if Item.Owner /= Ada.Task_Identification.Current_Task then
         raise Program_Error with "XML context used outside its owning task";
      end if;
      if Item.Closed then raise Program_Error with "XML context is closed"; end if;
   end Check;
   overriding procedure Initialize (Item : in out Parse_Context) is
   begin
      if Next_Identity = Interfaces.Unsigned_64'Last then
         raise Storage_Error with "XML context identity exhausted";
      end if;
      Next_Identity := Next_Identity + 1;
      Item.Owner := Ada.Task_Identification.Current_Task;
      Item.Identity := Next_Identity;
      Item.Generation := 1;
   end Initialize;
   procedure Adopt
     (Item : in out Parse_Context; Reader : in out Sax.Readers.Sax_Reader_Access;
      Release_Extension : Release_Handler := null) is
   begin
      Check (Item);
      if Item.Busy or else Item.Reader /= null or else Reader = null then
         raise Program_Error with "XML context requires one fresh reader";
      end if;
      if Sax.Utils.Symbol_Table_Pointers.Get (Sax.Readers.Get_Symbol_Table (Reader.all)) /= null then
         raise Program_Error with "XML reader already has an owner";
      end if;
      Item.Reader := Reader;
      Reader := null;
      Item.Release_Extension := Release_Extension;
      Item.Table := new Sax.Symbols.Symbol_Table_Record;
      Sax.Readers.Set_Symbol_Table (Item.Reader.all, (Data => Item.Table));
   end Adopt;
   procedure Parse (Item : in out Parse_Context; Input : in out Input_Sources.Input_Source'Class) is
   begin
      Check (Item);
      if Item.Busy or else Item.Reader = null then
         raise Program_Error with "XML context is busy or has no reader";
      end if;
      Item.Busy := True;
      begin
         Sax.Readers.Parse (Item.Reader.all, Input);
      exception
         when others => Item.Busy := False; raise;
      end;
      Item.Busy := False;
   end Parse;
   procedure Reset (Item : in out Parse_Context) is
      Replacement : Sax.Symbols.Symbol_Table_Access := null;
   begin
      Check (Item);
      if Item.Busy then raise Program_Error with "Cannot reset an active XML context"; end if;
      if Item.Generation = Interfaces.Unsigned_64'Last then
         raise Storage_Error with "XML context generation exhausted";
      end if;
      if Item.Reader /= null then
         Replacement := new Sax.Symbols.Symbol_Table_Record;
      end if;
      Item.Generation := Item.Generation + 1;
      if Item.Reader /= null then
         if Item.Release_Extension /= null then Item.Release_Extension (Item.Reader.all); end if;
         Sax.Readers.Release_Parser (Item.Reader.all);
         Sax.Readers.Set_Symbol_Table (Item.Reader.all, Sax.Utils.No_Symbol_Table);
         Sax.Symbols.Destroy (Item.Table);
         Item.Table := Replacement;
         Replacement := null;
         Sax.Readers.Set_Symbol_Table (Item.Reader.all, (Data => Item.Table));
      end if;
   exception
      when others => Sax.Symbols.Destroy (Replacement); raise;
   end Reset;
   procedure Close (Item : in out Parse_Context) is
   begin
      if Item.Owner /= Ada.Task_Identification.Current_Task then
         raise Program_Error with "XML context closed outside its owning task";
      end if;
      if Item.Closed then return; end if;
      if Item.Busy then raise Program_Error with "Cannot close an active XML context"; end if;
      Item.Closed := True;
      if Item.Reader /= null then
         if Item.Release_Extension /= null then Item.Release_Extension (Item.Reader.all); end if;
         Sax.Readers.Release_Parser (Item.Reader.all);
         Dispose (Item.Reader);
      end if;
      Sax.Symbols.Destroy (Item.Table);
   end Close;
   function Borrow (Item : Parse_Context; Symbol : Sax.Symbols.Symbol) return Symbol_Handle is
   begin
      Check (Item);
      if not Item.Busy then raise Program_Error with "XML symbols can only be borrowed in a callback"; end if;
      if Item.Table = null or else not Sax.Symbols.Owned_By (Item.Table, Symbol) then
         raise Program_Error with "Foreign XML callback symbol";
      end if;
      return (Item.Owner, Item.Identity, Item.Generation, Symbol);
   end Borrow;
   function Value (Item : Parse_Context; Symbol : Symbol_Handle) return String is
   begin
      Check (Item);
      if Symbol.Owner /= Item.Owner or else Symbol.Context /= Item.Identity or else Symbol.Generation /= Item.Generation then
         raise Program_Error with "Stale or foreign XML symbol";
      end if;
      if Symbol.Symbol = Sax.Symbols.No_Symbol then return ""; end if;
      return Sax.Symbols.Get (Symbol.Symbol).all;
   end Value;
   overriding procedure Finalize (Item : in out Parse_Context) is
   begin
      Close (Item);
   end Finalize;
end Sax.Contexts;

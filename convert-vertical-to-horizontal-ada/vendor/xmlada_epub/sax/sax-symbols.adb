------------------------------------------------------------------------------
--                     XML/Ada - An XML suite for Ada95                     --
--                                                                          --
--                     Copyright (C) 2010-2017, AdaCore                     --
--                                                                          --
-- This library is free software;  you can redistribute it and/or modify it --
-- under terms of the  GNU General Public License  as published by the Free --
-- Software  Foundation;  either version 3,  or (at your  option) any later --
-- version. This library is distributed in the hope that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE.                            --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

with Interfaces;                 use Interfaces;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Ada.Task_Identification;
with System.Address_Image;

package body Sax.Symbols is
   use type Ada.Task_Identification.Task_Id;
   Next_Table : Interfaces.Unsigned_64 := 0;
   pragma Thread_Local_Storage (Next_Table);
   function New_Table_Identity return Interfaces.Unsigned_64 is
   begin
      if Next_Table = Interfaces.Unsigned_64'Last then
         raise Storage_Error with "XML symbol table identity exhausted";
      end if;
      Next_Table := Next_Table + 1;
      return Next_Table;
   end New_Table_Identity;
   procedure Check_Owner (Table : Symbol_Table_Record) is
      use type Ada.Task_Identification.Task_Id;
   begin
      if Table.Owner /= Ada.Task_Identification.Current_Task then
         raise Program_Error with "XML table used outside its owning task";
      end if;
   end Check_Owner;
   function Owned_By (Table : access Symbol_Table_Record; Item : Symbol) return Boolean is
   begin
      Check_Owner (Table.all);
      return Item = No_Symbol or else Item = Empty_String
        or else (Item.Table_Identity = Table.Identity and then Item.Owner = Table.Owner);
   end Owned_By;
   procedure Destroy (Table : in out Symbol_Table_Access) is
      procedure Dispose is new Ada.Unchecked_Deallocation
        (Symbol_Table_Record'Class, Symbol_Table_Access);
   begin
      if Table /= null then
         Check_Owner (Table.all);
         Free (Table.all);
         Dispose (Table);
      end if;
   end Destroy;

   -----------------
   -- Debug_Print --
   -----------------

   function Debug_Print (S : Symbol) return String is
   begin
      if S = No_Symbol then
         return "<Symbol: null>";
      else
         return "<Symbol: " & System.Address_Image (S.Data.all'Address)
           & " {" & S.Data.all & "}>";
      end if;
   end Debug_Print;

   ----------
   -- Hash --
   ----------

   function Hash (Str : Cst_Byte_Sequence_Access) return Unsigned_32 is
      --  This hash function looks at every character, in order to make it
      --  likely that similar strings get different hash values. The rotate by
      --  7 bits has been determined empirically to be good, and it doesn't
      --  lose bits like a shift would. The final conversion can't overflow,
      --  because the table is 2**16 in size. This function probably needs to
      --  be changed if the hash table size is changed.

      --  Note that we could get some speed improvement by aligning the string
      --  to 32 or 64 bits, and doing word-wise xor's. We could also implement
      --  a growable table. It doesn't seem worth the trouble to do those
      --  things, for now.

      Result : Unsigned_32 := 0;
   begin
      for J in Str'Range loop
         Result := Rotate_Left (Result, 7) xor Character'Pos (Str (J));
      end loop;

      return Result;
   end Hash;

   -------------
   -- Get_Key --
   -------------

   function Get_Key (Str : Symbol) return Cst_Byte_Sequence_Access is
   begin
      return Str.Data;
   end Get_Key;

   ----------
   -- Free --
   ----------

   procedure Free (Str : in out Symbol) is
      function Convert is new Ada.Unchecked_Conversion
        (Cst_Byte_Sequence_Access, Byte_Sequence_Access);
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Byte_Sequence, Byte_Sequence_Access);
      S : Byte_Sequence_Access := Convert (Str.Data);
   begin
      Unchecked_Free (S);
      Str := No_Symbol;
   end Free;

   ---------------
   -- Key_Equal --
   ---------------

   function Key_Equal (Key1, Key2 : Cst_Byte_Sequence_Access) return Boolean is
   begin
      return Key1.all = Key2.all;
   end Key_Equal;

   ----------
   -- Find --
   ----------

   function Find
     (Table : access Symbol_Table_Record;
      Str   : Unicode.CES.Byte_Sequence) return Symbol
   is
      use String_Htable;
      Result : String_Htable.Element_Ptr;
      Hashed : Interfaces.Unsigned_32;
      Str_A  : Symbol;
   begin
      Check_Owner (Table.all);
      if Str'Length = 0 then
         return Empty_String;
      else
         Hashed := Hash (Cst_Byte_Sequence_Access'(Str'Unrestricted_Access));

         Result := String_Htable.Get_Ptr_With_Hash
           (Table.Hash, Str'Unrestricted_Access, Hashed);

         if Result = null then
            Str_A := (new Byte_Sequence'(Str), Table.Identity, Table.Owner);
            begin
               String_Htable.Set_With_Hash (Table.Hash, Str_A, Hashed);
            exception
               when Storage_Error => Free (Str_A); raise;
            end;

            return Str_A;
         end if;


         return Result.all;
      end if;
   end Find;

   ---------
   -- Get --
   ---------

   function Get (Sym : Symbol) return Cst_Byte_Sequence_Access is
   begin
      if Sym.Owner /= Ada.Task_Identification.Null_Task_Id
        and then Sym.Owner /= Ada.Task_Identification.Current_Task
      then raise Program_Error with "XML symbol used outside its owning task"; end if;
      return Sym.Data;
   end Get;

   ----------
   -- Free --
   ----------

   procedure Free (Table : in out Symbol_Table_Record) is
   begin
      Check_Owner (Table);
      String_Htable.Reset (Table.Hash);
   end Free;

   ----------
   -- Hash --
   ----------

   function Hash (S : Sax.Symbols.Symbol) return Interfaces.Unsigned_32 is
   begin
      return Hash (S.Data);
   end Hash;

   ---------
   -- "=" --
   ---------

   function "=" (S : Symbol; Str : Unicode.CES.Byte_Sequence) return Boolean is
   begin
      if S = No_Symbol then
         return False;
      else
         return Get (S).all = Str;
      end if;
   end "=";

end Sax.Symbols;

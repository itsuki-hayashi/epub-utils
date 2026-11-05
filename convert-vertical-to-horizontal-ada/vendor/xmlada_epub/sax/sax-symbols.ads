------------------------------------------------------------------------------
--                     XML/Ada - An XML suite for Ada95                     --
--                                                                          --
--                     Copyright (C) 2010-2018, AdaCore                     --
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

--  A symbol table.
--  This provides integers to represent strings internally. The implementation
--  is copied from namet.adb, in the GNAT sources

with Interfaces;
with Sax.HTable;
with Ada.Task_Identification;
with Unicode.CES;   use Unicode.CES;

package Sax.Symbols is

   type Symbol_Table_Record is tagged private;
   type Symbol_Table_Access is access all Symbol_Table_Record'Class;
   --  A symbol table associating integers with strings.
   --  By default, this is not task safe, so you will need to extend this if
   --  the symbol is to be shared between multiple tasks.

   procedure Check_Owner (Table : Symbol_Table_Record);
   procedure Destroy (Table : in out Symbol_Table_Access);

   type Symbol is private;
   function Owned_By (Table : access Symbol_Table_Record; Item : Symbol) return Boolean;

   No_Symbol    : constant Symbol;
   Empty_String : constant Symbol;

   function Find
     (Table : access Symbol_Table_Record;
      Str   : Unicode.CES.Byte_Sequence) return Symbol;
   --  Return the internal version of Str.
   --  Comparing Symbol is the same as comparing the string itself, but much
   --  faster.

   function Get (Sym : Symbol) return Cst_Byte_Sequence_Access;
   pragma Inline_Always (Get);
   --  The string associated with the symbol.
   --  The returned string must not be deallocated, it points to internal data

   procedure Free (Table : in out Symbol_Table_Record);
   --  Free the table

   function Hash (S : Symbol) return Interfaces.Unsigned_32;
   --  Returns a hash for the symbol

   function "=" (S : Symbol; Str : Unicode.CES.Byte_Sequence) return Boolean;
   --  Compare [S] and [Str]

   function Debug_Print (S : Symbol) return String;
   --  Return a displaying version of symbol (debugging purposes only)

private
   type Symbol is record
      Data : Cst_Byte_Sequence_Access;
      Table_Identity : Interfaces.Unsigned_64 := 0;
      Owner : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Null_Task_Id;
   end record;

   Cst_Empty_String : aliased constant Unicode.CES.Byte_Sequence := "";

   No_Symbol        : constant Symbol := (Data => null, others => <>);
   Empty_String     : constant Symbol := (Data => Cst_Empty_String'Access, others => <>);

   function Get_Key (Str : Symbol) return Cst_Byte_Sequence_Access;
   procedure Free (Str : in out Symbol);
   function Hash
     (Str : Cst_Byte_Sequence_Access) return Interfaces.Unsigned_32;
   function Key_Equal (Key1, Key2 : Cst_Byte_Sequence_Access) return Boolean;
   pragma Inline (Hash, Get_Key, Key_Equal);

   package String_Htable is new Sax.HTable
     (Element       => Symbol,
      Empty_Element => No_Symbol,
      Free          => Free,
      Key           => Cst_Byte_Sequence_Access,
      Get_Key       => Get_Key,
      Hash          => Hash,
      Equal         => Key_Equal);

   Hash_Num : constant := 2**10;
   --  Number of headers in the hash table

   type Hash_Type is range 0 .. Hash_Num - 1;

   function New_Table_Identity return Interfaces.Unsigned_64;
   type Symbol_Table_Record is tagged record
      Owner : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Current_Task;
      Identity : Interfaces.Unsigned_64 := New_Table_Identity;
      Hash : String_Htable.HTable (Hash_Num);
   end record;

end Sax.Symbols;

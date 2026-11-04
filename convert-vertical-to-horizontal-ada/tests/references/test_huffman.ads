with Huffman.Encoding.Length_Limited_Coding;
with Interfaces;

package Test_Huffman is
   type Symbol is range 0 .. 287;
   type Counts is array (Symbol) of Natural;
   type Lengths is array (Symbol) of Natural;
   procedure Reference is new Huffman.Encoding.Length_Limited_Coding
     (Symbol, Natural, Counts, Lengths, 15);
   type Small_Symbol is range 0 .. 7;
   type Small_Counts is array (Small_Symbol) of Natural;
   type Small_Lengths is array (Small_Symbol) of Natural;
   procedure Reference_3 is new Huffman.Encoding.Length_Limited_Coding
     (Small_Symbol, Natural, Small_Counts, Small_Lengths, 3);
   procedure Reference_4 is new Huffman.Encoding.Length_Limited_Coding
     (Small_Symbol, Natural, Small_Counts, Small_Lengths, 4);
   type Wide_Counts is array (Small_Symbol) of Interfaces.Integer_64;
   procedure Reference_Wide is new Huffman.Encoding.Length_Limited_Coding
     (Small_Symbol, Interfaces.Integer_64, Wide_Counts, Small_Lengths, 15);
end Test_Huffman;

--  Compile third-party generic bodies in the dependency project. Owned test
--  logic imports these instances and retains its strict warning policy.
with JSON.Parsers;
with JSON.Types;

package Test_JSON is
   package Values is new JSON.Types (Long_Long_Integer, Long_Long_Float);
   package Parsers is new JSON.Parsers (Values, Check_Duplicate_Keys => True);
end Test_JSON;

package Epub.Writing_Modes with SPARK_Mode, Pure is
   type Mode is (Other, Horizontal_TB, LR_TB,
                 Vertical_RL, Vertical_LR, Sideways_RL, Sideways_LR, TB_RL, TB_LR);
   subtype Vertical_Mode is Mode range Vertical_RL .. TB_LR;
   function Parse_Lower (Value : String) return Mode
     with Global => null;
   function Token (Value : Mode) return String
     with Global => null;
   function Map (Value : Mode; Microsoft : Boolean) return Mode
     with Global => null,
       Contract_Cases =>
         ((Value not in Vertical_Mode) => Map'Result = Value,
          ((Value in Vertical_Mode) and then
            (Microsoft or else (Value in TB_RL | TB_LR))) => Map'Result = LR_TB,
          others => Map'Result = Horizontal_TB);
   procedure Idempotence (Value : Mode; Microsoft : Boolean)
     with Ghost, Global => null,
       Post => Map (Map (Value, Microsoft), Microsoft) = Map (Value, Microsoft);
end Epub.Writing_Modes;

package body Epub.Writing_Modes with SPARK_Mode is
   function Parse_Lower (Value : String) return Mode is
     (if Value = "horizontal-tb" then Horizontal_TB
      elsif Value = "lr-tb" then LR_TB
      elsif Value = "vertical-rl" then Vertical_RL
      elsif Value = "vertical-lr" then Vertical_LR
      elsif Value = "sideways-rl" then Sideways_RL
      elsif Value = "sideways-lr" then Sideways_LR
      elsif Value = "tb-rl" then TB_RL
      elsif Value = "tb-lr" then TB_LR
      else Other);
   function Token (Value : Mode) return String is
     (case Value is
        when Other => "", when Horizontal_TB => "horizontal-tb",
        when LR_TB => "lr-tb", when Vertical_RL => "vertical-rl",
        when Vertical_LR => "vertical-lr", when Sideways_RL => "sideways-rl",
        when Sideways_LR => "sideways-lr", when TB_RL => "tb-rl", when TB_LR => "tb-lr");
   function Map (Value : Mode; Microsoft : Boolean) return Mode is
   begin
      if Value not in Vertical_Mode then
         return Value;
      elsif Microsoft or else Value in TB_RL | TB_LR then
         return LR_TB;
      else
         return Horizontal_TB;
      end if;
   end Map;
   procedure Idempotence (Value : Mode; Microsoft : Boolean) is
   begin
      pragma Assert (Map (Value, Microsoft) not in Vertical_Mode);
   end Idempotence;
end Epub.Writing_Modes;

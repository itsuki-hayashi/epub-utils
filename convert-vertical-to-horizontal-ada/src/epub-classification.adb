package body Epub.Classification with SPARK_Mode is
   function Classify
     (Fixed : Boolean; Images, Texts : Page_Count; Vertical : Boolean)
      return Layout is
   begin
      if Fixed then
         return Fixed_Layout;
      elsif Texts = 0 then
         return Image_Only;
      elsif Images >= 10 and then Images >= 4 * Texts then
         return Image_Dominated;
      elsif Vertical then
         return Vertical_Text;
      else
         return Horizontal;
      end if;
   end Classify;
end Epub.Classification;

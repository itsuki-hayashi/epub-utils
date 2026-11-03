package Epub.Classification with SPARK_Mode, Pure is
   type Layout is (Fixed_Layout, Image_Only, Image_Dominated,
                   Horizontal, Vertical_Text);
   subtype Page_Count is Natural range 0 .. Natural'Last / 5;
   function Classify
     (Fixed : Boolean; Images, Texts : Page_Count; Vertical : Boolean)
      return Layout
   with Global => null,
     Contract_Cases =>
       (Fixed => Classify'Result = Fixed_Layout,
        not Fixed and then Texts = 0 => Classify'Result = Image_Only,
        not Fixed and then Texts > 0 and then Images >= 10
          and then Images >= 4 * Texts =>
            Classify'Result = Image_Dominated,
        others => Classify'Result =
          (if Vertical then Vertical_Text else Horizontal));
end Epub.Classification;

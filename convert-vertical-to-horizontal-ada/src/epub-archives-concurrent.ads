with Epub.Conversion;
with Epub.Resources;
with Epub.CPUs;

package Epub.Archives.Concurrent is
   procedure Process
     (Sources, Outputs : Epub.Resources.String_Lists.Vector;
      Settings : Epub.Conversion.Options; Cores : Epub.CPUs.Processor_Lists.Vector;
      Automatic : Boolean; Results : out Epub.Conversion.Result_Lists.Vector;
      Observer : access procedure (Ordinal : Positive; Result : Epub.Conversion.Book_Result) := null);
end Epub.Archives.Concurrent;

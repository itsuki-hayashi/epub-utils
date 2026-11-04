with Ada.Finalization;

package Epub.Synchronization is
   protected type Mutex is
      entry Acquire;
      procedure Release;
   private
      Busy : Boolean := False;
   end Mutex;
   type Guard (Lock : not null access Mutex) is
     new Ada.Finalization.Limited_Controlled with private;
private
   type Guard (Lock : not null access Mutex) is
     new Ada.Finalization.Limited_Controlled with record
      Held : Boolean := False;
   end record;
   overriding procedure Initialize (Item : in out Guard);
   overriding procedure Finalize (Item : in out Guard);
end Epub.Synchronization;

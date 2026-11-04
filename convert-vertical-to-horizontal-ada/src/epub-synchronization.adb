package body Epub.Synchronization is
   protected body Mutex is
      entry Acquire when not Busy is
      begin
         Busy := True;
      end Acquire;
      procedure Release is
      begin
         pragma Assert (Busy);
         Busy := False;
      end Release;
   end Mutex;
   overriding procedure Initialize (Item : in out Guard) is
   begin
      Item.Lock.all.Acquire;
      Item.Held := True;
   end Initialize;
   overriding procedure Finalize (Item : in out Guard) is
   begin
      if Item.Held then
         Item.Held := False;
         Item.Lock.all.Release;
      end if;
   end Finalize;
end Epub.Synchronization;

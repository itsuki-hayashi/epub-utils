with Ada.Exceptions;
with Ada.Unchecked_Deallocation;
with Epub.Books;
with Epub.Classification;
with Epub.Destinations;
with Epub.Diagnostics;
with Epub.File_Streams;
with Epub.Files;
with Epub.Hash_Streams;
with Epub.Publication;
with Epub.Digests;
with Epub.Temporary_Files;
with Epub.Workers;
with Epub.Performance;

package body Epub.Archives.Concurrent is
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Zip_Streams.Time;
   use type Epub.Classification.Layout;
   use type Epub.Conversion.Processing_Status;
   type Operation is (Metadata, Validate_Batch, Analyze, Open_Output, Compress_Batch,
                      Write_Batch, Close_Output, Inspect_Saved, Verify_Batch, Release_Book);
   type Phase is (Need_Metadata, Reading_Metadata, Validating, Need_Analysis, Analyzing,
                  Need_Output, Opening_Output, Compressing, Need_Close, Closing_Output,
                  Need_Saved, Reading_Saved, Verifying, Need_Release, Releasing,
                  Await_Publication, Terminal);
   type Batch is record
      First, Last : Positive := 1;
   end record;
   package Batch_Lists is new Epub.Lists (Batch);
   subtype Hash is String (1 .. 64);
   type Hash_Array is array (Positive range <>) of Hash;
   type Hashes_Access is access Hash_Array;
   type Book_State;
   type Book_Access is access Book_State;
   type Run_State;
   type Run_Access is access Run_State;
   type Reply;
   type Reply_Access is access Reply;
   type Prepared_Array is array (Positive range 1 .. 32) of Prepared_Entry;
   type Reply is record
      Book : Positive;
      Kind : Operation;
      Slot : Positive := 1;
      First, Last, Current : Positive := 1;
      Error_Ordinal : Natural := 0;
      Error, Warnings : Unbounded_String;
      Encoded : Prepared_Array;
      Hashes : Hash_Array (1 .. 32);
      Held : Reply_Access;
   end record;
   type Pending_Array is array (Positive range <>) of Reply_Access;
   type Pending_Access is access Pending_Array;
   type Mail_Array is array (Positive range <>) of Reply_Access;
   type Mail_Access is access Mail_Array;
   protected type Mailbox is
      procedure Initialize (Storage : Mail_Access);
      procedure Post (Value : Reply_Access; Accepted : out Boolean);
      entry Take (Value : out Reply_Access);
      procedure Try_Take (Value : out Reply_Access);
      function Broken return Boolean;
   private
      Values : Mail_Access;
      Capacity : Positive := 1;
      Head, Tail : Positive := 1;
      Used : Natural := 0;
      Overflow : Boolean := False;
   end Mailbox;
   type Hashed_Access is access Epub.Hash_Streams.Stream;
   protected type Cancellation is
      procedure Set (Ordinal : Natural);
      function Limit return Natural;
   private
      Bound : Natural := Natural'Last;
   end Cancellation;
   type Book_State is limited record
      Input, Destination, Temporary : Unbounded_String;
      Result, Before_Output : Epub.Conversion.Book_Result;
      Source, Saved_Source : Epub.Archive_Sources.Reference;
      Items, Patched, Saved : Catalogue;
      Plan : Epub.Books.Book_Plan;
      Output : aliased Epub.File_Streams.Stream;
      Hashed : Hashed_Access;
      Writer : Writer_State;
      State : Phase := Need_Metadata;
      Jobs : Natural := 0;
      Batches : Batch_Lists.Vector;
      Next_Batch, Next_Write : Positive := 1;
      Pending : Pending_Access;
      Payload_Hashes : Hashes_Access;
      Writer_Busy, Failed, Reserved, Collision_Check, Verified : Boolean := False;
      Error_Ordinal : Natural := Natural'Last;
      Error, Warnings : Unbounded_String;
      Cancel : Cancellation;
      Output_Bytes : Interfaces.Unsigned_64 := 0;
      Entry_Count : Natural := 0;
      Profile_ID : Natural := Epub.Performance.New_Book;
      Publication : Epub.Publication.State := Epub.Publication.Unverified;
   end record;
   type Book_Array is array (Positive range <>) of Book_Access;
   type Books_Access is access Book_Array;
   type Natural_Array is array (Positive range <>) of Natural;
   type Naturals_Access is access Natural_Array;
   type Boolean_Array is array (Positive range <>) of Boolean;
   type Booleans_Access is access Boolean_Array;
   type Run_State is limited record
      Pool : Epub.Workers.Pool;
      Mail : Mailbox;
      Mail_Storage : Mail_Access;
      Books : Books_Access;
      Group_Head, Group_Next, Group_ID : Naturals_Access;
      Done : Booleans_Access;
      Settings : Epub.Conversion.Options;
      Limit : Positive := 1;
      Active_Books, Active_Jobs, Credits, Finished : Natural := 0;
      Batch_High_Water, Book_High_Water : Natural := 0;
      Next_Book, Next_Report : Positive := 1;
   end record;
   type Work is new Epub.Workers.Job with record
      Owner : Run_Access;
      Value : Reply_Access;
   end record;
   overriding procedure Execute (Item : in out Work);
   overriding procedure Failed (Item : in out Work; Message : String);
   overriding procedure Completed (Item : in out Work);
   overriding procedure Discard (Item : in out Work);
   procedure Free_Reply is new Ada.Unchecked_Deallocation (Reply, Reply_Access);
   procedure Free_Hashes is new Ada.Unchecked_Deallocation (Hash_Array, Hashes_Access);
   procedure Free_Pending is new Ada.Unchecked_Deallocation (Pending_Array, Pending_Access);
   procedure Free_Hashed is new Ada.Unchecked_Deallocation (Epub.Hash_Streams.Stream, Hashed_Access);
   procedure Free_Book is new Ada.Unchecked_Deallocation (Book_State, Book_Access);
   procedure Free_Books is new Ada.Unchecked_Deallocation (Book_Array, Books_Access);
   procedure Free_Naturals is new Ada.Unchecked_Deallocation (Natural_Array, Naturals_Access);
   procedure Free_Booleans is new Ada.Unchecked_Deallocation (Boolean_Array, Booleans_Access);
   procedure Free_Mail is new Ada.Unchecked_Deallocation (Mail_Array, Mail_Access);
   procedure Free_Run is new Ada.Unchecked_Deallocation (Run_State, Run_Access);
   Current_Reply : Reply_Access := null;
   pragma Thread_Local_Storage (Current_Reply);

   protected body Cancellation is
      procedure Set (Ordinal : Natural) is
      begin
         Bound := Natural'Min (Bound, Ordinal);
      end Set;
      function Limit return Natural is (Bound);
   end Cancellation;

   procedure Capture_Warning (Message : String) is
   begin
      if Current_Reply /= null then
         Append (Current_Reply.all.Warnings, Message & Character'Val (10));
      end if;
   end Capture_Warning;
   procedure Dispose (Value : in out Reply_Access) is
   begin
      if Value /= null then
         if Value.all.Held /= null then Dispose (Value.all.Held); end if;
         Free_Reply (Value);
      end if;
   end Dispose;
   function Exception_Text (Error : Ada.Exceptions.Exception_Occurrence) return String is
      Message : constant String := Ada.Exceptions.Exception_Message (Error);
   begin
      return (if Message'Length > 0 then Message else Ada.Exceptions.Exception_Name (Error));
   end Exception_Text;
   protected body Mailbox is
      procedure Initialize (Storage : Mail_Access) is
      begin
         Values := Storage;
         Capacity := Storage.all'Length;
      end Initialize;
      procedure Post (Value : Reply_Access; Accepted : out Boolean) is
      begin
         Accepted := Used < Capacity;
         if Accepted then
            Values.all (Tail) := Value;
            Tail := Tail mod Capacity + 1;
            Used := Used + 1;
         else
            Overflow := True;
         end if;
      end Post;
      entry Take (Value : out Reply_Access) when Used > 0 or Overflow is
      begin
         Try_Take (Value);
      end Take;
      procedure Try_Take (Value : out Reply_Access) is
      begin
         Value := null;
         if Used > 0 then
            Value := Values.all (Head);
            Values.all (Head) := null;
            Head := Head mod Capacity + 1;
            Used := Used - 1;
         end if;
      end Try_Take;
      function Broken return Boolean is (Overflow);
   end Mailbox;

   procedure Record_Error (Book : in out Book_State; Ordinal : Natural; Message : String) is
   begin
      Book.Failed := True;
      Book.Cancel.Set (Ordinal);
      if Ordinal < Book.Error_Ordinal or else Length (Book.Error) = 0 then
         Book.Error_Ordinal := Ordinal;
         Book.Error := To_Unbounded_String (Message);
      end if;
   end Record_Error;
   procedure Build_Batches (Book : in out Book_State; Saved : Boolean := False) is
      Empty : Batch_Lists.Vector;
      Last : constant Natural :=
        (if Saved then (if Book.Saved.Structure_Error_Ordinal > 0 then Book.Saved.Structure_Error_Ordinal - 1
                        else Book.Saved.Last_Index)
         else (if Book.Items.Structure_Error_Ordinal > 0 then Book.Items.Structure_Error_Ordinal - 1
               else Book.Items.Last_Index));
      Ordinal : Positive := 1;
   begin
      Book.Batches := Empty;
      Book.Next_Batch := 1;
      Book.Next_Write := 1;
      Free_Hashes (Book.Payload_Hashes);
      Free_Pending (Book.Pending);
      Book.Payload_Hashes := new Hash_Array (1 .. Last);
      while Ordinal <= Last loop
         declare
            First : constant Positive := Ordinal;
            Expanded : Interfaces.Unsigned_64 := 0;
         begin
            while Ordinal <= Last and then Ordinal - First < 32 loop
               declare
                  Bytes : constant Interfaces.Unsigned_64 :=
                    (if Saved then Book.Saved (Ordinal).Header.short_info.dd.uncompressed_size
                     else Book.Items (Ordinal).Header.short_info.dd.uncompressed_size);
               begin
                  exit when Ordinal > First and then Bytes > 262_144 - Expanded;
                  Ordinal := Ordinal + 1;
                  exit when Bytes >= 262_144;
                  Expanded := Expanded + Bytes;
               end;
            end loop;
            Book.Batches.Append ((First, Ordinal - 1));
         end;
      end loop;
      Book.Pending := new Pending_Array'(1 .. Book.Batches.Last_Index => null);
   end Build_Batches;

   procedure Release_Resources (Book : in out Book_State) is
      Empty : Catalogue;
      No_Source : Epub.Archive_Sources.Reference;
      No_Plan : Epub.Books.Book_Plan;
      Failure : Unbounded_String;
   begin
      Free_Hashed (Book.Hashed);
      begin Book.Output.Close;
      exception when Error : others => Failure := To_Unbounded_String (Exception_Text (Error)); end;
      Book.Saved := Empty;
      begin Epub.Archive_Sources.Close_Checked (Book.Saved_Source);
      exception
         when Error : others =>
            if Length (Failure) = 0 then Failure := To_Unbounded_String (Exception_Text (Error)); end if;
      end;
      Book.Saved_Source := No_Source;
      Book.Items := Empty;
      Book.Patched := Empty;
      Book.Writer.Written := Empty;
      Book.Source := No_Source;
      Book.Plan := No_Plan;
      Free_Hashes (Book.Payload_Hashes);
      Free_Pending (Book.Pending);
      if Length (Failure) > 0 then raise Epub.Files.File_Error with To_String (Failure); end if;
   end Release_Resources;

   overriding procedure Execute (Item : in out Work) is
      Reply_Value : Reply renames Item.Value.all;
      Book : Book_State renames Item.Owner.all.Books.all (Reply_Value.Book).all;
      Measured : constant Boolean := Reply_Value.Kind in Metadata | Validate_Batch | Open_Output |
        Write_Batch | Close_Output | Inspect_Saved | Verify_Batch;
      Timer : constant Epub.Performance.Phase :=
        (case Reply_Value.Kind is
           when Metadata | Validate_Batch => Epub.Performance.Input_Read,
           when Open_Output | Write_Batch | Close_Output => Epub.Performance.Output_Write,
           when others => Epub.Performance.Verification);
   begin
      Current_Reply := Item.Value;
      Epub.Performance.Begin_Job (Book.Profile_ID);
      Epub.Diagnostics.Capture (Capture_Warning'Access);
      if Measured then Epub.Performance.Start (Timer); end if;
      case Reply_Value.Kind is
         when Metadata =>
            Book.Source := Epub.Archive_Sources.Open (To_String (Book.Input));
            Read_Structure (Book.Source, Book.Items);
            Book.Entry_Count := Book.Items.Last_Index;
         when Validate_Batch | Verify_Batch =>
            for Ordinal in Reply_Value.First .. Reply_Value.Last loop
               exit when Ordinal > Book.Cancel.Limit;
               Reply_Value.Current := Ordinal;
               declare
                  Value : constant Member :=
                    (if Reply_Value.Kind = Validate_Batch then Book.Items (Ordinal) else Book.Saved (Ordinal));
                  Payload : constant String := Epub.Archive_Sources.Decode
                    (Value.Source, Value.Payload_Offset, Value.Header.short_info);
                  Digest : constant String := Epub.Digests.Digest (Payload);
               begin
                  Reply_Value.Hashes (Ordinal - Reply_Value.First + 1) := Digest;
                  Epub.Performance.Resource_Decode (Ordinal);
                  if Reply_Value.Kind = Verify_Batch then
                     if Ordinal > Book.Patched.Last_Index then
                        raise Invalid_Archive with "Verification failed: extra entry";
                     end if;
                     declare
                        Expected : constant Member := Book.Patched (Ordinal);
                        Expected_Hash : constant String :=
                          (if Expected.Payload_Loaded then Epub.Digests.Digest (To_String (Expected.Payload))
                           else To_String (Expected.Payload_SHA256));
                     begin
                        if Value.Name /= Expected.Name or else Value.Raw_Name /= Expected.Raw_Name
                          or else Value.Header.short_info.file_timedate /= Expected.Header.short_info.file_timedate
                          or else Value.Header.external_attributes /= Expected.Header.external_attributes
                          or else Interfaces.Unsigned_64 (Payload'Length) /=
                            (if Expected.Payload_Loaded then Interfaces.Unsigned_64 (Length (Expected.Payload))
                             else Expected.Header.short_info.dd.uncompressed_size)
                          or else Digest /= Expected_Hash
                        then
                           raise Invalid_Archive with "Verification failed: " & To_String (Expected.Name);
                        end if;
                     end;
                  end if;
               end;
            end loop;
         when Analyze =>
            Book.Result.Input_Bytes := Natural (Source_Size (Book.Items));
            Book.Plan := Epub.Books.Analyze_Book (Book.Items);
            Book.Result.Reason := Book.Plan.Reason;
            Book.Result.Has_Reason := True;
            for Patch of Book.Plan.Patches loop Book.Result.Changed_Entries.Append (Patch.Name); end loop;
            Book.Before_Output := Book.Result;
            if Item.Owner.all.Settings.Analyze_Only then
               Book.Result.Status := Epub.Conversion.Analyzed;
            else
               Book.Collision_Check := True;
               if Epub.Files.Exists (To_String (Book.Destination)) then
                  raise Epub.Files.File_Error with "Refusing to overwrite: " & To_String (Book.Destination);
               end if;
               if Item.Owner.all.Settings.Dry_Run then Book.Result.Status := Epub.Conversion.What_If; end if;
            end if;
         when Open_Output =>
            Epub.Files.Ensure_Directory (Epub.Files.Parent_Path (To_String (Book.Destination)));
            Epub.Performance.Start (Epub.Performance.Hashing);
            Book.Result.Input_SHA256 := To_Unbounded_String (Source_Digest (Book.Items));
            Epub.Performance.Stop (Epub.Performance.Hashing);
            if Book.Plan.Reason = Epub.Classification.Vertical_Text then
               Book.Patched := Epub.Books.Apply (Book.Items, Book.Plan);
            end if;
            Epub.Temporary_Files.Reserve
              (Epub.Files.Parent_Path (To_String (Book.Destination)), Book.Output, Book.Temporary);
            Book.Reserved := True;
            if Book.Plan.Reason = Epub.Classification.Vertical_Text then
               Book.Hashed := new Epub.Hash_Streams.Stream (Book.Output'Access);
               Begin_Rebuild (Book.Patched, Book.Hashed.all, Book.Writer);
            else
               Copy_Source (Book.Items, Book.Output);
               Book.Result.Output_SHA256 := Book.Result.Input_SHA256;
            end if;
         when Compress_Batch =>
            for Ordinal in Reply_Value.First .. Reply_Value.Last loop
               exit when Ordinal > Book.Cancel.Limit;
               Reply_Value.Current := Ordinal;
               Reply_Value.Encoded (Ordinal - Reply_Value.First + 1) := Prepare_Entry (Book.Patched, Ordinal);
            end loop;
         when Write_Batch =>
            for Ordinal in Reply_Value.Held.all.First .. Reply_Value.Held.all.Last loop
               Reply_Value.Current := Ordinal;
               Append_Entry (Book.Writer, Book.Hashed.all,
                 Reply_Value.Held.all.Encoded (Ordinal - Reply_Value.Held.all.First + 1));
            end loop;
         when Close_Output =>
            if Book.Plan.Reason = Epub.Classification.Vertical_Text then
               Finish_Rebuild (Book.Writer, Book.Hashed.all);
               Book.Result.Output_SHA256 := To_Unbounded_String (Book.Hashed.all.Digest);
            end if;
            Book.Output_Bytes := Interfaces.Unsigned_64 (Book.Output.Size);
            if Book.Output_Bytes > Interfaces.Unsigned_64 (Natural'Last) then
               raise Epub.Files.File_Error with "Output exceeds the report byte-count limit";
            end if;
            Book.Output.Flush;
            Book.Output.Close;
         when Inspect_Saved =>
            Book.Saved_Source := Epub.Archive_Sources.Open (To_String (Book.Temporary));
            Epub.Performance.Start (Epub.Performance.Hashing);
            if Epub.Archive_Sources.Digest (Book.Saved_Source) /= To_String (Book.Result.Output_SHA256) then
               raise Epub.Files.File_Error with "Temporary output verification failed";
            end if;
            Epub.Performance.Stop (Epub.Performance.Hashing);
            if Book.Plan.Reason = Epub.Classification.Vertical_Text then
               Read_Structure (Book.Saved_Source, Book.Saved);
            end if;
         when Release_Book =>
            Release_Resources (Book);
      end case;
      if Measured then Epub.Performance.Stop (Timer); end if;
   end Execute;
   overriding procedure Failed (Item : in out Work; Message : String) is
   begin
      Item.Value.all.Error := To_Unbounded_String (Message);
      Item.Value.all.Error_Ordinal :=
        (if Item.Value.all.Kind in Validate_Batch | Verify_Batch | Compress_Batch | Write_Batch
         then Item.Value.all.Current else 0);
   end Failed;
   overriding procedure Completed (Item : in out Work) is
      Accepted : Boolean;
      Value : Reply_Access := Item.Value;
   begin
      Epub.Diagnostics.Capture (null);
      Current_Reply := null;
      Item.Value := null;
      Item.Owner.all.Mail.Post (Value, Accepted);
      if not Accepted then
         Dispose (Value);
         raise Epub.Workers.Worker_Error with "Completion mailbox overflow";
      end if;
   end Completed;
   overriding procedure Discard (Item : in out Work) is
   begin
      Dispose (Item.Value);
   end Discard;

   procedure Process
     (Sources, Outputs : Epub.Resources.String_Lists.Vector;
      Settings : Epub.Conversion.Options; Cores : Epub.CPUs.Processor_Lists.Vector;
      Automatic : Boolean; Results : out Epub.Conversion.Result_Lists.Vector;
      Observer : access procedure (Ordinal : Positive; Result : Epub.Conversion.Book_Result) := null) is
      R : Run_Access;
      Empty_Results : Epub.Conversion.Result_Lists.Vector;

      function Small_Single_Book return Boolean is
      begin
         declare
            Source : constant Epub.Archive_Sources.Reference :=
              Epub.Archive_Sources.Open (To_String (Sources (1)));
            Book : Book_State;
            Expanded : Interfaces.Unsigned_64 := 0;
         begin
            Read_Structure (Source, Book.Items);
            if Book.Items.Structure_Error_Ordinal /= 0 then return True; end if;
            Build_Batches (Book);
            for Value of Book.Items loop
               Expanded := Expanded + Interfaces.Unsigned_64'Min (1_048_576, Value.Header.short_info.dd.uncompressed_size);
               exit when Expanded >= 1_048_576;
            end loop;
            Free_Hashes (Book.Payload_Hashes);
            Free_Pending (Book.Pending);
            return Expanded < 1_048_576 or else Book.Batches.Last_Index < 2;
         exception
            when others =>
               Free_Hashes (Book.Payload_Hashes);
               Free_Pending (Book.Pending);
               return True;
         end;
      exception
         when others => return True;
      end Small_Single_Book;

      procedure Serial is
      begin
         for Index in 1 .. Sources.Last_Index loop
            declare
               Result : constant Epub.Conversion.Book_Result := Epub.Conversion.Process_Book
                 (To_String (Sources (Index)), To_String (Outputs (Index)), Settings);
            begin
               Results.Append (Result);
               if Observer /= null then Observer.all (Index, Result); end if;
            end;
         end loop;
      end Serial;

      procedure Submit (Index : Positive; Kind : Operation; Slot : Positive := 1;
                        Held : Reply_Access := null) is
         Book : Book_State renames R.all.Books.all (Index).all;
         Value : constant Reply_Access := new Reply'(Book => Index, Kind => Kind, others => <>);
         Task_Job : Epub.Workers.Job_Access;
         Accepted : Boolean;
      begin
         Value.all.Slot := Slot;
         Value.all.Held := Held;
         if Kind in Validate_Batch | Compress_Batch | Verify_Batch then
            Value.all.First := Book.Batches (Slot).First;
            Value.all.Last := Book.Batches (Slot).Last;
            Value.all.Current := Value.all.First;
         end if;
         Task_Job := new Work'(Epub.Workers.Job with Owner => R, Value => Value);
         R.all.Pool.Submit (Task_Job, Accepted);
         if not Accepted then
            Epub.Workers.Destroy (Task_Job);
            raise Epub.Workers.Worker_Error with "Archive job queue exceeded its admission bound";
         end if;
         Book.Jobs := Book.Jobs + 1;
         R.all.Active_Jobs := R.all.Active_Jobs + 1;
      end Submit;

      procedure Drop_Ready (Book : in out Book_State) is
      begin
         if Book.Pending /= null then
            for Value of Book.Pending.all loop
               if Value /= null then
                  Dispose (Value);
                  R.all.Credits := R.all.Credits - 1;
               end if;
            end loop;
         end if;
      end Drop_Ready;

      procedure Remove_Temporary (Book : in out Book_State) is
      begin
         if Book.Reserved then
            begin
               Epub.Files.Remove (To_String (Book.Temporary));
               Book.Reserved := False;
            exception
               when Error : others =>
                  Book.Failed := True;
                  Append (Book.Error, "; cleanup failed: " & Exception_Text (Error));
            end;
         end if;
      end Remove_Temporary;

      procedure Publish_Ready is
      begin
         for Group in R.all.Group_Head.all'Range loop
            loop
               declare
                  Index : constant Natural := R.all.Group_Head.all (Group);
               begin
                  exit when Index = 0;
                  if R.all.Done.all (Index) then
                     R.all.Group_Head.all (Group) := R.all.Group_Next.all (Index);
                  else
                     exit when R.all.Books.all (Index) = null or else
                       R.all.Books.all (Index).all.State /= Await_Publication;
                     declare
                        Book : Book_State renames R.all.Books.all (Index).all;
                     begin
                        begin
                           if Book.Collision_Check and then Epub.Files.Exists (To_String (Book.Destination)) then
                              Book.Result := Book.Before_Output;
                              Book.Failed := True;
                              Book.Error := To_Unbounded_String
                                ("Refusing to overwrite: " & To_String (Book.Destination));
                           elsif not Book.Failed and then Book.Verified then
                              if not Epub.Publication.Eligible (Book.Publication, False) then
                                 raise Epub.Files.File_Error with "Refusing to publish unverified output or overwrite: "
                                   & To_String (Book.Destination);
                              end if;
                              Epub.Performance.Begin_Job (Book.Profile_ID);
                              Epub.Performance.Start (Epub.Performance.Publication);
                              Epub.Files.Publish (To_String (Book.Temporary), To_String (Book.Destination));
                              Epub.Performance.Stop (Epub.Performance.Publication);
                              Epub.Publication.Mark_Published (Book.Publication);
                              Book.Reserved := False;
                              Book.Result.Status :=
                                (if Book.Result.Reason = Epub.Classification.Vertical_Text
                                 then Epub.Conversion.Converted else Epub.Conversion.Preserved);
                              Book.Result.Output_Bytes := Natural (Book.Output_Bytes);
                              Book.Result.Has_Output_Bytes := True;
                              Book.Result.Entries_Verified := Book.Entry_Count;
                           end if;
                        exception
                           when Error : others => Record_Error (Book, 0, Exception_Text (Error));
                        end;
                        if Book.Failed then
                           Remove_Temporary (Book);
                           Book.Result.Status := Epub.Conversion.Failed;
                           Book.Result.Error := Book.Error;
                        end if;
                        Results.Replace_Element (Index, Book.Result);
                        Book.State := Terminal;
                        R.all.Done.all (Index) := True;
                        R.all.Finished := R.all.Finished + 1;
                        R.all.Group_Head.all (Group) := R.all.Group_Next.all (Index);
                     end;
                  end if;
               end;
            end loop;
         end loop;
         while R.all.Next_Report <= Sources.Last_Index and then R.all.Done.all (R.all.Next_Report) loop
            declare
               Book : Book_State renames R.all.Books.all (R.all.Next_Report).all;
            begin
               if Length (Book.Warnings) > 0 then
                  Epub.Diagnostics.Report (To_String (Book.Warnings));
               end if;
               if Observer /= null then Observer.all (R.all.Next_Report, Results (R.all.Next_Report)); end if;
               R.all.Next_Report := R.all.Next_Report + 1;
            end;
         end loop;
      end Publish_Ready;

      procedure Pump is
         Progress : Boolean;
      begin
         while R.all.Active_Books < R.all.Limit and then R.all.Next_Book <= Sources.Last_Index loop
            declare
               Index : constant Positive := R.all.Next_Book;
               Book : constant Book_Access := new Book_State;
            begin
               R.all.Books.all (Index) := Book;
               Book.all.Input := Sources (Index);
               Book.all.Destination := Outputs (Index);
               Book.all.Result.Book := To_Unbounded_String (Epub.Files.Basename (To_String (Book.all.Input)));
               Book.all.Result.Output := Book.all.Destination;
               R.all.Active_Books := R.all.Active_Books + 1;
               R.all.Book_High_Water := Natural'Max (R.all.Book_High_Water, R.all.Active_Books);
               R.all.Next_Book := Index + 1;
            end;
         end loop;
         for Index in R.all.Books.all'Range loop
            if R.all.Books.all (Index) /= null then
               declare
                  Book : Book_State renames R.all.Books.all (Index).all;
               begin
                  if Book.Failed then
                     Drop_Ready (Book);
                     if Book.Jobs = 0 and then Book.State not in Releasing | Await_Publication | Terminal then
                        Book.State := Need_Release;
                     end if;
                  end if;
                  case Book.State is
                     when Need_Metadata => Submit (Index, Metadata); Book.State := Reading_Metadata;
                     when Need_Analysis => Submit (Index, Analyze); Book.State := Analyzing;
                     when Need_Output => Submit (Index, Open_Output); Book.State := Opening_Output;
                     when Need_Close => Submit (Index, Close_Output); Book.State := Closing_Output;
                     when Need_Saved => Submit (Index, Inspect_Saved); Book.State := Reading_Saved;
                     when Need_Release =>
                        if Book.Jobs = 0 then Submit (Index, Release_Book); Book.State := Releasing; end if;
                     when Compressing =>
                        if not Book.Failed and then not Book.Writer_Busy and then
                          Book.Next_Write <= Book.Batches.Last_Index and then
                          Book.Pending.all (Book.Next_Write) /= null
                        then
                           Submit (Index, Write_Batch, Held => Book.Pending.all (Book.Next_Write));
                           Book.Pending.all (Book.Next_Write) := null;
                           Book.Next_Write := Book.Next_Write + 1;
                           Book.Writer_Busy := True;
                        end if;
                     when others => null;
                  end case;
               end;
            end if;
         end loop;
         loop
            Progress := False;
            exit when R.all.Credits >= 2 * R.all.Limit;
            for Index in R.all.Books.all'Range loop
               exit when R.all.Credits >= 2 * R.all.Limit;
               if R.all.Books.all (Index) /= null then
                  declare
                     Book : Book_State renames R.all.Books.all (Index).all;
                  begin
                     if not Book.Failed and then Book.State in Validating | Compressing | Verifying
                       and then Book.Next_Batch <= Book.Batches.Last_Index
                     then
                        Submit (Index, (if Book.State = Validating then Validate_Batch
                                        elsif Book.State = Compressing then Compress_Batch else Verify_Batch),
                                Slot => Book.Next_Batch);
                        Book.Next_Batch := Book.Next_Batch + 1;
                        R.all.Credits := R.all.Credits + 1;
                        R.all.Batch_High_Water := Natural'Max (R.all.Batch_High_Water, R.all.Credits);
                        Progress := True;
                     end if;
                  end;
               end if;
            end loop;
            exit when not Progress;
         end loop;
      end Pump;

      procedure Batch_Ended (Book : in out Book_State) is
      begin
         if Book.Jobs /= 0 or else Book.Next_Batch <= Book.Batches.Last_Index then return; end if;
         if Book.State = Validating then
            if Book.Items.Structure_Error_Ordinal > 0 then
               Record_Error (Book, Book.Items.Structure_Error_Ordinal, To_String (Book.Items.Structure_Error));
            elsif not Book.Failed then
               for Ordinal in 1 .. Book.Items.Last_Index loop
                  declare
                     Value : Member := Book.Items (Ordinal);
                  begin
                     Value.Payload_SHA256 := To_Unbounded_String (Book.Payload_Hashes.all (Ordinal));
                     Book.Items.Replace_Element (Ordinal, Value);
                  end;
               end loop;
               Book.State := Need_Analysis;
            end if;
         elsif Book.State = Verifying then
            if Book.Saved.Structure_Error_Ordinal > 0 then
               Record_Error (Book, Book.Saved.Structure_Error_Ordinal, To_String (Book.Saved.Structure_Error));
            elsif not Book.Failed then
               if Book.Saved.Last_Index /= Book.Patched.Last_Index then
                  Record_Error (Book, Book.Saved.Last_Index + 1, "Verification failed: entry count changed");
               elsif Book.Saved.Is_Empty or else To_String (Book.Saved (1).Name) /= "mimetype"
                 or else Book.Saved (1).Header.short_info.zip_type /= 0
                 or else Book.Saved (1).Header.short_info.bit_flag /= 0
                 or else Book.Saved (1).Header.short_info.extra_field_length /= 0
               then
                  Record_Error (Book, 1, "Invalid EPUB mimetype ZIP header");
               end if;
               Book.State := Need_Release;
            end if;
         elsif Book.State = Compressing and then not Book.Writer_Busy
           and then Book.Next_Write > Book.Batches.Last_Index and then not Book.Failed
         then
            Book.State := Need_Close;
         end if;
      end Batch_Ended;

      procedure Accept_Reply (Value : in out Reply_Access) is
         Book : Book_State renames R.all.Books.all (Value.all.Book).all;
      begin
         Book.Jobs := Book.Jobs - 1;
         R.all.Active_Jobs := R.all.Active_Jobs - 1;
         Append (Book.Warnings, Value.all.Warnings);
         if Length (Value.all.Error) > 0 then
            if Value.all.Kind = Release_Book and then Book.Failed then
               --  Cleanup follows the failing stage and cannot replace its
               --  earlier error with a close failure at ordinal zero.
               Append (Book.Error, "; cleanup failed: " & To_String (Value.all.Error));
            else
               Record_Error (Book, Value.all.Error_Ordinal, To_String (Value.all.Error));
            end if;
         end if;
         case Value.all.Kind is
            when Metadata =>
               if not Book.Failed then Book.State := Validating; Build_Batches (Book); end if;
            when Validate_Batch =>
               if not Book.Failed then
                  for Ordinal in Value.all.First .. Value.all.Last loop
                     Book.Payload_Hashes.all (Ordinal) := Value.all.Hashes (Ordinal - Value.all.First + 1);
                  end loop;
               end if;
               R.all.Credits := R.all.Credits - 1;
            when Analyze =>
               Book.State :=
                 (if Book.Failed or else Settings.Analyze_Only or else Settings.Dry_Run then Need_Release else Need_Output);
            when Open_Output =>
               if not Book.Failed then
                  Book.State := (if Book.Plan.Reason = Epub.Classification.Vertical_Text then Compressing else Need_Close);
                  Book.Next_Batch := 1;
                  Book.Next_Write := 1;
               end if;
            when Compress_Batch =>
               if Book.Failed then
                  R.all.Credits := R.all.Credits - 1;
               else
                  Book.Pending.all (Value.all.Slot) := Value;
                  Value := null;
               end if;
            when Write_Batch =>
               Book.Writer_Busy := False;
               R.all.Credits := R.all.Credits - 1;
            when Close_Output => if not Book.Failed then Book.State := Need_Saved; end if;
            when Inspect_Saved =>
               if not Book.Failed then
                  if Book.Plan.Reason = Epub.Classification.Vertical_Text then
                     Book.State := Verifying;
                     Build_Batches (Book, Saved => True);
                  else
                     Book.State := Need_Release;
                  end if;
               end if;
            when Verify_Batch => R.all.Credits := R.all.Credits - 1;
            when Release_Book =>
               if Book.Failed then Remove_Temporary (Book);
               elsif not Settings.Analyze_Only and then not Settings.Dry_Run then
                  Epub.Publication.Mark_Verified (Book.Publication);
                  Book.Verified := True;
               end if;
               Book.State := Await_Publication;
               R.all.Active_Books := R.all.Active_Books - 1;
         end case;
         if Value /= null then Dispose (Value); end if;
         Batch_Ended (Book);
      end Accept_Reply;

      procedure Cleanup is
         Value : Reply_Access;
      begin
         if R = null then return; end if;
         R.all.Pool.Stop;
         loop
            R.all.Mail.Try_Take (Value);
            exit when Value = null;
            Dispose (Value);
         end loop;
         if R.all.Books /= null then
            for Book of R.all.Books.all loop
               if Book /= null then
                  Drop_Ready (Book.all);
                  begin Release_Resources (Book.all);
                  exception when Error : others => Epub.Diagnostics.Report (Exception_Text (Error)); end;
                  Remove_Temporary (Book.all);
                  Free_Book (Book);
               end if;
            end loop;
            Free_Books (R.all.Books);
         end if;
         Free_Naturals (R.all.Group_Head);
         Free_Naturals (R.all.Group_Next);
         Free_Naturals (R.all.Group_ID);
         Free_Booleans (R.all.Done);
         Free_Mail (R.all.Mail_Storage);
         Free_Run (R);
      end Cleanup;
   begin
      Results := Empty_Results;
      if Sources.Last_Index /= Outputs.Last_Index then
         raise Constraint_Error with "Each source requires one destination";
      end if;
      if Sources.Is_Empty then return; end if;
      if Cores.Last_Index <= 1 or else (Automatic and then Sources.Last_Index = 1 and then Small_Single_Book) then
         Serial;
         return;
      end if;
      R := new Run_State;
      R.all.Settings := Settings;
      R.all.Limit := Cores.Last_Index;
      R.all.Mail_Storage := new Mail_Array'(1 .. 4 * R.all.Limit => null);
      R.all.Mail.Initialize (R.all.Mail_Storage);
      R.all.Books := new Book_Array'(1 .. Sources.Last_Index => null);
      R.all.Done := new Boolean_Array'(1 .. Sources.Last_Index => False);
      R.all.Group_Head := new Natural_Array'(1 .. Sources.Last_Index => 0);
      R.all.Group_Next := new Natural_Array'(1 .. Sources.Last_Index => 0);
      R.all.Group_ID := new Natural_Array'(1 .. Sources.Last_Index => 0);
      declare
         Groups : constant Epub.Destinations.Group_Lists.Vector := Epub.Destinations.Groups (Outputs);
         Tails : Natural_Array (1 .. Sources.Last_Index) := [others => 0];
         Empty : Epub.Conversion.Book_Result;
      begin
         for Index in 1 .. Sources.Last_Index loop
            declare
               Group : constant Positive := Groups (Index);
            begin
               R.all.Group_ID.all (Index) := Group;
               if Tails (Group) = 0 then R.all.Group_Head.all (Group) := Index;
               else R.all.Group_Next.all (Tails (Group)) := Index; end if;
               Tails (Group) := Index;
               Results.Append (Empty);
            end;
         end loop;
      end;
      begin
         R.all.Pool.Start (Cores);
      exception
         when Epub.Workers.Worker_Error | Epub.CPUs.Affinity_Error | Storage_Error | Tasking_Error =>
            Cleanup;
            if not Automatic then raise; end if;
            Epub.Diagnostics.Report ("Parallel workers unavailable; processing sequentially.");
            Results := Empty_Results;
            Serial;
            return;
      end;
      while R.all.Finished < Sources.Last_Index loop
         if R.all.Pool.Problem'Length > 0 or else R.all.Mail.Broken then
            raise Epub.Workers.Worker_Error with "Concurrent worker failed: " & R.all.Pool.Problem;
         end if;
         Pump;
         for Book of R.all.Books.all loop
            if Book /= null then Batch_Ended (Book.all); end if;
         end loop;
         Pump;
         if R.all.Pool.Problem'Length > 0 or else R.all.Mail.Broken then
            raise Epub.Workers.Worker_Error with "Concurrent worker failed: " & R.all.Pool.Problem;
         end if;
         Publish_Ready;
         exit when R.all.Finished = Sources.Last_Index;
         if R.all.Pool.Problem'Length > 0 or else R.all.Mail.Broken then
            raise Epub.Workers.Worker_Error with "Concurrent worker failed: " & R.all.Pool.Problem;
         end if;
         if R.all.Active_Jobs = 0 then
            raise Program_Error with "Concurrent archive graph made no progress";
         end if;
         declare
            Value : Reply_Access := null;
         begin
            select
               R.all.Mail.Take (Value);
            or
               delay 0.05;
            end select;
            if Value /= null then Accept_Reply (Value); end if;
         end;
      end loop;
      R.all.Pool.Join;
      R.all.Pool.Write_Statistics (R.all.Batch_High_Water, R.all.Book_High_Water);
      Cleanup;
   exception
      when others =>
         Cleanup;
         raise;
   end Process;
end Epub.Archives.Concurrent;

package body MIDI.Time.Generic_Clock is

   Current_State : State_Kind := Stopped;
   Current_Step : Step_Count := Step_Count'First;
   Next_Clock_Trig : Microseconds_Count := Microseconds_Count'Last;

   ---------------------------
   -- Internal_Clock_Period --
   ---------------------------

   function Internal_Clock_Period return Microseconds_Count is
   begin
      return Microseconds_Count ((1000.0 * 1000.0 * 60.0) /
                                 (Float (BPM) * 24.0));
   end Internal_Clock_Period;

   -----------
   -- State --
   -----------

   function State return State_Kind is
   begin
      return Current_State;
   end State;

   -------------
   -- Running --
   -------------

   function Running return Boolean is
   begin
      return Current_State in Running_External | Running_Internal;
   end Running;

   ----------
   -- Step --
   ----------

   function Step return Step_Count is
   begin
      return Current_Step;
   end Step;

   ------------
   -- Update --
   ------------

   procedure Update is
      Now : constant Microseconds_Count := Clock;
   begin

      case Current_State is
         when Stopped =>
            null; --  Nothing to do...

         when Running_Internal =>

            if Now >= Next_Clock_Trig then
               Next_Clock_Trig := Next_Clock_Trig + Internal_Clock_Period;

               Tick_Callback (Current_Step);

               Current_Step := Current_Step + 1;

               Send_Message ((Sys, Timming_Tick, others => <>));
            end if;

         when Running_External =>
            null; --  Nothing to do...
      end case;
   end Update;

   --------------------
   -- Internal_Start --
   --------------------

   procedure Internal_Start is
   begin
      case Current_State is
         when Stopped =>

            Current_State := Running_Internal;
            Next_Clock_Trig := Clock + Internal_Clock_Period;

            Current_Step := Step_Count'First;

            Start_Callback;

            Send_Message ((Sys, Start_Song, others => <>));

         when Running_Internal =>
            null;

         when Running_External =>
            null;

      end case;
   end Internal_Start;

   -----------------------
   -- Internal_Continue --
   -----------------------

   procedure Internal_Continue is
   begin
      case Current_State is
         when Stopped =>

            --  Same as Start but don't reset the Current_Step

            Current_State := Running_Internal;
            Next_Clock_Trig := Clock + Internal_Clock_Period;

            Continue_Callback;

            Send_Message ((Sys, Continue_Song, others => <>));

         when Running_Internal =>
            null;

         when Running_External =>
            null;
      end case;
   end Internal_Continue;

   -------------------
   -- Internal_Stop --
   -------------------

   procedure Internal_Stop is
   begin
      case Current_State is
         when Stopped =>
            null;

         when Running_Internal =>
            Current_State := Stopped;

            Stop_Callback;
            Send_Message ((Sys, Stop_Song, others => <>));

         when Running_External =>
            null;
      end case;
   end Internal_Stop;

   --------------------
   -- External_Start --
   --------------------

   procedure External_Start is
   begin
      case Current_State is
         when Stopped =>
            Current_State := Running_External;
            Current_Step := Step_Count'First;

            Start_Callback;

            if Propagate_External_Message then
               --  Propagate the clock start to our MIDI output
               Send_Message ((Sys, Start_Song, others => <>));
            end if;

         when Running_Internal =>
            null;

         when Running_External =>
            null;
      end case;
   end External_Start;

   -----------------------
   -- External_Continue --
   -----------------------

   procedure External_Continue is
   begin
      case Current_State is
         when Stopped =>

            --  Same as Start but don't reset the Current_Step

            Current_State := Running_External;

            Continue_Callback;

            if Propagate_External_Message then
               --  Propagate the clock start to our MIDI output
               Send_Message ((Sys, Continue_Song, others => <>));
            end if;

         when Running_Internal =>
            null;

         when Running_External =>
            null;
      end case;
   end External_Continue;

   -------------------
   -- External_Stop --
   -------------------

   procedure External_Stop is
   begin
      case Current_State is
         when Stopped =>
            null;

         when Running_Internal =>
            null;

         when Running_External =>

            --  Propagate the clock stop to our MIDI output
            Send_Message ((Sys, Stop_Song, others => <>));

            Stop_Callback;

            Current_State := Stopped;

      end case;
   end External_Stop;

   -------------------
   -- External_Tick --
   -------------------

   procedure External_Tick is
   begin
      case Current_State is
         when Stopped =>
            null; --  ?!? What is going on here?

         when Running_Internal =>
            null;

         when Running_External =>

            Tick_Callback (Current_Step);

            Current_Step := Current_Step + 1;

            if Propagate_External_Message then
               --  Propagate the clock tick to our MIDI output
               Send_Message ((Sys, Timming_Tick, others => <>));
            end if;

      end case;
   end External_Tick;

end MIDI.Time.Generic_Clock;

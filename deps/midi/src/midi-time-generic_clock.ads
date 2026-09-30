generic
   type Microseconds_Count is mod <>;

   with function Clock return Microseconds_Count;
   --  Return the count of microseconds since the start of the system

   with function BPM return BPM;
   --  Return current Beat Per Minute setting

   with procedure Tick_Callback (Step : Step_Count);
   --  This procedure will be called for each MIDI tick event, either from the
   --  internal or external clock.

   with procedure Start_Callback;
   --  This procedure will be called for each song start event, either from
   --  the internal or external clock.

   with procedure Continue_Callback;
   --  This procedure will be called for each continue event, either from the
   --  internal or external clock.

   with procedure Stop_Callback;
   --  This procedure will be called for each song stop event, either from the
   --  internal or external clock.

   with procedure Send_Message (Msg : Message);
   --  This procedure will be called to send clock MIDI messages from
   --  the internal clock, and replicate external clock messages if
   --  Propagate_External_Message is set to True.

   Propagate_External_Message : Boolean := True;
   --  If set to True, the external MIDI clock event will be propagated using
   --  the Send_Message procedure.

package MIDI.Time.Generic_Clock is

   type State_Kind is (Stopped, Running_Internal, Running_External);

   function State return State_Kind;
   --  Return the current state of the clock

   function Running return Boolean;
   --  Return True if the clock is running, either internal or external

   function Step return Step_Count;
   --  Return the current step of the clock

   procedure Update;
   --  This procedure has to be called at regular intervals to update the
   --  state of the clock. Calling Update at higher frequency will result
   --  in a more precise clock. We recommend starting with 1KHz (call every
   --  milliseconds), and adjust if need be.

   procedure Internal_Start;
   --  Call this procedure to start the internal clock. If an external clock
   --  is running this will be ignored.

   procedure Internal_Continue;
   --  Call this procedure to resume the internal clock. If an external clock
   --  is running this will be ignored.

   procedure Internal_Stop;
   --  Call this procedure to stop the internal clock. If an external clock is
   --  running this will be ignored.

   procedure External_Start;
   --  This procedure must be called when a MIDI song start message is
   --  recieved from external MIDI device.

   procedure External_Continue;
   --  This procedure must be called when a MIDI continue message is recieved
   --  from external MIDI device.

   procedure External_Stop;
   --  This procedure must be called when a MIDI song stop message is recieved
   --  from external MIDI device.

   procedure External_Tick;
   --  This procedure must be called when a MIDI clock tick message is
   --  recieved from external MIDI device.

end MIDI.Time.Generic_Clock;

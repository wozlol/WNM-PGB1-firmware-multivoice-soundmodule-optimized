-------------------------------------------------------------------------------
--                                                                           --
--                              Wee Noise Maker                              --
--                                                                           --
--                  Copyright (C) 2016-2017 Fabien Chouteau                  --
--                                                                           --
--    Wee Noise Maker is free software: you can redistribute it and/or       --
--    modify it under the terms of the GNU General Public License as         --
--    published by the Free Software Foundation, either version 3 of the     --
--    License, or (at your option) any later version.                        --
--                                                                           --
--    Wee Noise Maker is distributed in the hope that it will be useful,     --
--    but WITHOUT ANY WARRANTY; without even the implied warranty of         --
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU       --
--    General Public License for more details.                               --
--                                                                           --
--    You should have received a copy of the GNU General Public License      --
--    along with We Noise Maker. If not, see <http://www.gnu.org/licenses/>. --
--                                                                           --
-------------------------------------------------------------------------------

with HAL; use HAL;

with WNM.Mixer;
with WNM.Voices.Snare_Voice;
with WNM.Voices.Sampler_Voice;
with WNM.Voices.Chord_Voice;
with WNM.Voices.Hihat_Voice;
with WNM.Voices.Kick_Voice;

with Tresses; use Tresses;
with Tresses.Voices.Macro;
with Tresses.Macro;
with Tresses.Interfaces;

with WNM.Generic_Queue;
with WNM.Utils;
with WNM.Note_Priority;
with Interfaces;
with WNM.Persistent;

with WNM.Shared_Buffers;

package body WNM.Synth is

   use type MIDI.MIDI_UInt8;

   TK          : aliased WNM.Voices.Kick_Voice.Instance;
   TS          : aliased WNM.Voices.Snare_Voice.Instance;
   HH          : aliased WNM.Voices.Hihat_Voice.Instance;
   Chord       : aliased WNM.Voices.Chord_Voice.Instance;
   Sampler1    : aliased WNM.Voices.Sampler_Voice.Instance;
   Sampler2    : aliased WNM.Voices.Sampler_Voice.Instance;

   Lead_B     : aliased Tresses.Voices.Macro.Macro_Buffers
     with Import, Address => Shared_Buffers.Shared_Buffer
       (Shared_Buffers.Lead_Synth_Offset)'Address;
   Bass_B     : aliased Tresses.Voices.Macro.Macro_Buffers
     with Import, Address => Shared_Buffers.Shared_Buffer
       (Shared_Buffers.Bass_Synth_Offset)'Address;

   Lead : aliased Tresses.Voices.Macro.Instance (Lead_B'Access);
   Bass : aliased Tresses.Voices.Macro.Instance (Bass_B'Access);

   pragma Compile_Time_Error
     (Lead'Size > Shared_Buffers.Lead_Synth_Byte_Size * 8,
      "Invalid shared buffer size for Lead synth");

   pragma Compile_Time_Error
     (Bass'Size > Shared_Buffers.Bass_Synth_Byte_Size * 8,
      "Invalid shared buffer size for bass synth");

   Sample_Rec_Playback :
   WNM.Voices.Sampler_Voice.Sample_Rec_Playback_Instance;
   --  This voice is only used when playing the freshly recorded sample from
   --  RAM.

   subtype Voice_Class is Tresses.Interfaces.Four_Params_Voice'Class;
   type Voice_Access is access all Voice_Class;

   subtype Lead_Engine_Range is MIDI.MIDI_Data range 0 .. 32;
   function Lead_Engines (V : MIDI.MIDI_Data) return Tresses.Synth_Engines
   is (case V is
          when 0  => Tresses.Voice_Saw_Swarm,
          when 1  => Tresses.Voice_Analog_Buzz,
          when 2  => Tresses.Voice_Analog_Morph,
          when 3  => Tresses.Voice_FM2OP,
          when 4  => Tresses.Voice_Sand,
          when 5  => Tresses.Voice_Bass_808,
          when 6  => Tresses.Voice_House_Bass,
          when 7  => Tresses.Voice_Pluck_Bass,
          when 8  => Tresses.Voice_Reese,
          when 9  => Tresses.Voice_Screech,
          when 10 => Tresses.Voice_Plucked,
          when 11 => Tresses.Voice_PDR_Sine,
          when 12 => Tresses.Voice_PDR_Triangle,
          when 13 => Tresses.Voice_PDR_Sine_Square,
          when 14 => Tresses.Voice_PDR_Square_Sine,
          when 15 => Tresses.Voice_PDL_Trig_Warp,
          when 16 => Tresses.Voice_PDL_Triangle_Screech,
          when 17 => Tresses.Voice_Chip_Glide,
          when 18 => Tresses.Voice_Chip_Phaser,
          when 19 => Tresses.Voice_Chip_Echo_Square,
          when 20 => Tresses.Voice_Chip_Echo_Square_Saw,
          when 21 => Tresses.Voice_Chip_Bass,
          when 22 => Tresses.Voice_PDR_Square_Full_Sine,
          when 23 => Tresses.Voice_Triangle_Phaser,
          when 24 => Tresses.Voice_Sine_Phaser,
          when 25 => Tresses.Voice_Sine_Pluck,
          when 26 => Tresses.Voice_Triangle_Pluck,
          when 27 => Tresses.Voice_Chip_Pluck,
          when 28 => Tresses.Voice_User_Wave_Glide,
          when 29 => Tresses.Voice_User_Wave_Phaser,
          when 30 => Tresses.Voice_User_Wave_Pluck,
          when 31 => Tresses.Voice_User_Wave_Echo,
          when 32 => Tresses.Voice_User_Wave_PDR,
          when Lead_Engine_Range'Last + 1 .. MIDI.MIDI_Data'Last
                  => Tresses.Synth_Engines'Last);

   subtype Kick_Engine_Range is MIDI.MIDI_Data range 0 .. 5;
   function Kick_Engines (V : MIDI.MIDI_Data)
                          return Voices.Kick_Voice.Kick_Engine
   is (case V is
          when 0 => Voices.Kick_Voice.Sine_Kick,
          when 1 => Voices.Kick_Voice.Triangle_Kick,
          when 2 => Voices.Kick_Voice.Chip_Kick,
          when 3 => Voices.Kick_Voice.Sine_Click_Kick,
          when 4 => Voices.Kick_Voice.User_Wave_Kick,
          when others => Voices.Kick_Voice.User_Wave_Click_Kick);

   subtype Snare_Engine_Range is MIDI.MIDI_Data range 0 .. 6;
   function Snare_Engines (V : MIDI.MIDI_Data)
                           return Voices.Snare_Voice.Snare_Engine
   is (case V is
          when 0 => Voices.Snare_Voice.Sine_Snare,
          when 1 => Voices.Snare_Voice.Saw_Snare,
          when 2 => Voices.Snare_Voice.Triangle_Snare,
          when 3 => Voices.Snare_Voice.Virt_Analog,
          when 4 => Voices.Snare_Voice.Clap,
          when 5 => Voices.Snare_Voice.Clap_HP,
          when others => Voices.Snare_Voice.User_Wave_Snare);

   subtype HH_Engine_Range is MIDI.MIDI_Data range 0 .. 24;
   function HH_Engines (V : MIDI.MIDI_Data)
                        return Voices.Hihat_Voice.HH_Engine
   is (case V is
          when 0 => Voices.Hihat_Voice.Cymbal,
          when 1 => Voices.Hihat_Voice.HH909,
          when 2 => Voices.Hihat_Voice.HH707,
          when 3 => Voices.Hihat_Voice.HH808,
          when 4 => Voices.Hihat_Voice.HH505,
          when 5 => Voices.Hihat_Voice.HHLM2,
          when 6 => Voices.Hihat_Voice.HHCR78,
          when 7 => Voices.Hihat_Voice.HHMRK2,
          when 8 => Voices.Hihat_Voice.HH_Acoustic,

          when 9 => Voices.Hihat_Voice.HH909_BP,
          when 10 => Voices.Hihat_Voice.HH707_BP,
          when 11 => Voices.Hihat_Voice.HH808_BP,
          when 12 => Voices.Hihat_Voice.HH505_BP,
          when 13 => Voices.Hihat_Voice.HHLM2_BP,
          when 14 => Voices.Hihat_Voice.HHCR78_BP,
          when 15 => Voices.Hihat_Voice.HHMRK2_BP,
          when 16 => Voices.Hihat_Voice.HH_Acoustic_BP,

          when 17 => Voices.Hihat_Voice.HH909_HP,
          when 18 => Voices.Hihat_Voice.HH707_HP,
          when 19 => Voices.Hihat_Voice.HH808_HP,
          when 20 => Voices.Hihat_Voice.HH505_HP,
          when 21 => Voices.Hihat_Voice.HHLM2_HP,
          when 22 => Voices.Hihat_Voice.HHCR78_HP,
          when 23 => Voices.Hihat_Voice.HHMRK2_HP,
          when 24 => Voices.Hihat_Voice.HH_Acoustic_HP,

          when others => Voices.Hihat_Voice.HH_Acoustic_HP);

   subtype Sampler_Engine_Range is MIDI.MIDI_Data range 0 .. 7;
   function Sampler_Engines (V : MIDI.MIDI_Data)
                        return Voices.Sampler_Voice.Sampler_Engine
   is (case V is
          when 0      => Voices.Sampler_Voice.Overdrive,
          when 1      => Voices.Sampler_Voice.Crusher,
          when 2      => Voices.Sampler_Voice.Glide_Fast,
          when 3      => Voices.Sampler_Voice.Glide_Slow,
          when 4      => Voices.Sampler_Voice.Pitch_Down_1oct,
          when 5      => Voices.Sampler_Voice.Pitch_Down_2oct,
          when 6      => Voices.Sampler_Voice.Pitch_Up_1oct,
          when 7      => Voices.Sampler_Voice.Pitch_Up_2oct,
          when others => Voices.Sampler_Voice.Crusher);

   subtype Chord_Engine_Range is MIDI.MIDI_Data range 0 .. 2;
   function Chord_Engines (V : MIDI.MIDI_Data)
                        return Voices.Chord_Voice.Chord_Engine
   is (case V is
          when 0      => Voices.Chord_Voice.Waveform,
          when 1      => Voices.Chord_Voice.Mixed_Waveforms,
          when others => Voices.Chord_Voice.Custom_Waveform);

   Synth_Voices : constant array (Tresses_Channels) of
     Voice_Access :=
       (Sample1_Channel    => Sampler1'Access,
        Sample2_Channel    => Sampler2'Access,
        Kick_Channel       => TK'Access,
        Snare_Channel      => TS'Access,
        Hihat_Channel      => HH'Access,
        Lead_Channel       => Lead'Access,
        Bass_Channel       => Bass'Access,
        Chord_Channel      => Chord'Access,
        Reverb_Channel     => WNM.Mixer.FX_Reverb'Access,
        Drive_Channel      => WNM.Mixer.FX_Drive'Access,
        Bitcrusher_Channel => WNM.Mixer.FX_Bitcrush'Access);

   LFO_Targets : array (Tresses_Channels) of MIDI.MIDI_Data :=
     (others => MIDI.MIDI_Data'Last);
   --  MIDI_Data'Last means "no target", since the apply step below only
   --  acts on targets inside LFO_Compatible_CC. This has to match the
   --  project's own default of LFO_Target_Kind'Last, which is None.
   --  It used to default to Voice_Pan_CC, which left every channel's LFO
   --  modulating pan from boot until a project load happened to sync the
   --  real target over it. Pan is applied as one constant per buffer, so
   --  a moving pan steps the signal every 256 samples, which is heard as
   --  a slow wobble with fine continuous crackle riding on it.

   --  Bass and Lead are monophonic, so a new note takes the voice from
   --  whatever was sounding. The strike itself is harmless, the envelope
   --  ramps on from its current value and the oscillator phase is never
   --  reset, but the pitch change is not: a new pitch reads a different
   --  band-limited table, so the waveform value jumps. Waiting for a zero
   --  crossing of the outgoing note does not help, because the incoming
   --  one starts wherever its own table happens to sit. So the strike is
   --  held here and applied during the render, inside a short fade.
   subtype Declick_Channels is
     MIDI.MIDI_Channel range Bass_Channel .. Lead_Channel;

   type Pending_Strike is record
      Active   : Boolean        := False;
      Key      : MIDI.MIDI_Key  := 0;
      Velocity : MIDI.MIDI_Data := 0;
   end record;

   Pending_Note : array (Declick_Channels) of Pending_Strike;

   Last_Out : array (Declick_Channels) of Tresses.S16 := (others => 0);
   --  Last sample each of these channels produced, so a strike arriving
   --  while the voice is already effectively silent can be applied straight
   --  away with no fade. That matters for the plucked engines, whose whole
   --  character is the attack transient, and fading that in would be
   --  removing the part that makes them audible.

   Declick_Floor : constant := 200;
   --  About -44dB. Below this a direct switch cannot step audibly.

   Declick_Samples : constant := 48;  --  1.5ms at 32kHz

   Declick_Ramp : constant array (0 .. Declick_Samples - 1) of Tresses.S32 :=
     (
          0,    37,   146,   328,   582,   907,  1300,  1761,
       2287,  2876,  3526,  4233,  4994,  5806,  6665,  7568,
       8510,  9487, 10495, 11529, 12585, 13658, 14744, 15836,
      16931, 18023, 19109, 20182, 21238, 22272, 23280, 24257,
      25199, 26102, 26961, 27773, 28534, 29241, 29891, 30480,
      31006, 31467, 31860, 32185, 32439, 32621, 32730, 32767);
   --  Raised cosine, 0 to full scale in Q15. A straight line has a corner
   --  at each end, and on a pure tone with no harmonics to hide behind that
   --  corner is itself audible as a tick. This is smooth at both ends.

   procedure Render_Declicked
     (V      : in out Tresses.Voices.Macro.Instance;
      Chan   :        Declick_Channels;
      Buffer :    out WNM_HAL.Mono_Buffer;
      Aux    :    out WNM_HAL.Mono_Buffer);


   LFOs       : array (Tresses_Channels) of Tresses.LFO.Instance;
   LFO_Syncs  : array (Tresses_Channels) of Boolean := (others => False);
   LFO_Values : array (Tresses_Channels) of Tresses.S16;

   type Voice_Parameters_Array is array (Tresses_Channels) of
     Voice_Parameters;

   In_Voice_Parameters : Voice_Parameters_Array :=
     (others => (Voice_Volume_CC => Param_Range'Last / 2,
                 Voice_Pan_CC    => Param_Range'Last / 2,
                 Voice_Param_4_CC => Param_Range'Last,
                 others          => 0));
   Out_Voice_Parameters : Voice_Parameters_Array := (others => (others => 0));

   --  Last-note-priority mono retrig, available on every synth channel
   --  except Chord (which already has its own independent per-voice
   --  Key_On/Key_Off). Per-track setting, defaults to on: see
   --  WNM.Note_Priority. When off, a channel falls back to the original
   --  stock behavior of only releasing a voice when the released key
   --  matches the last key played.
   subtype Note_Channels is
     MIDI.MIDI_Channel range Kick_Channel .. Sample2_Channel;
   --  The channels that can actually be sent notes. Reverb, Drive and
   --  Bitcrusher are effects and never are, so they need none of the
   --  per-note bookkeeping below.

   Note_Prio : array (Note_Channels) of WNM.Note_Priority.Instance;

   subtype Bend_Channels is
     MIDI.MIDI_Channel range Kick_Channel .. Sample2_Channel;
   --  Every channel that can be pitched. The samplers are in: they already
   --  resample, so a bend is just a different playback rate.

   subtype Bend_Pitch_Voices is
     MIDI.MIDI_Channel range Kick_Channel .. Chord_Channel;
   --  Of those, the ones bent by setting a pitch. The samplers keep their
   --  own key and bend and work out their own playback rate, so they need
   --  none of the state below.

   Bend_Offset : array (Bend_Channels) of Tresses.S16 := (others => 0);

   Bend_Applied : array (Bend_Pitch_Voices) of Tresses.S16 :=
     (others => 0);


   Base_Pitch : array (Bend_Pitch_Voices) of Tresses.Pitch_Range :=
     (others => 0);
   --  Unbent pitch of whatever each channel is playing, so a bend can be
   --  applied without losing the note it applies to.

   function Bend_Range_Units return Integer
   is (case WNM.Persistent.Data.Bend_Range is
          when Two_Semitones => 2 * 128,
          when One_Octave    => 12 * 128);
   --  Tresses pitch units, 128 to the semitone.

   -------------------
   -- Bend_To_Units --
   -------------------

   function Bend_To_Units (Msg : MIDI.Message) return Tresses.S16 is
      Raw    : constant Integer := MIDI.Bend_Value (Msg) - MIDI.Bend_Center;
      Units  : Integer := (Raw * Bend_Range_Units) / MIDI.Bend_Center;
   begin
      if WNM.Persistent.Data.Bend_Res = Low then
         --  Coarse on purpose, 32 steps across the range.
         Units := (Units / 16) * 16;
      end if;

      return Tresses.S16 (Units);
   end Bend_To_Units;

   ----------------
   -- Bent_Pitch --
   ----------------

   function Bent_Pitch (Chan : Bend_Pitch_Voices)
                        return Tresses.Pitch_Range is
      P : constant Integer :=
        Integer (Base_Pitch (Chan)) + Integer (Bend_Offset (Chan));
   begin
      return Tresses.Pitch_Range
        (Integer'Max (Integer (Tresses.Pitch_Range'First),
                      Integer'Min (Integer (Tresses.Pitch_Range'Last), P)));
   end Bent_Pitch;

   ----------------
   -- Apply_Bend --
   ----------------

   procedure Apply_Bend (Chan : Bend_Pitch_Voices) is
   begin
      --  Nothing to do with the wheel centred, which is most of the time,
      --  so this costs nothing until it is actually moved. Goes through the
      --  class-wide access so it works for the drums as well as Bass and
      --  Lead, since Set_Pitch is common to every voice.
      if Integer (Bend_Applied (Chan)) /= Integer (Bend_Offset (Chan))
      then
         Bend_Applied (Chan) := Bend_Offset (Chan);
         Synth_Voices (Chan).Set_Pitch (Bent_Pitch (Chan));
      end if;
   end Apply_Bend;

   Retrig_Enabled : array (Tresses_Channels) of Boolean := (others => True);
   Last_Key : array (Tresses_Channels) of MIDI.MIDI_Key := (others => 0);

   FX_Send : array (MIDI.MIDI_Channel) of FX_Kind := (others => Bypass);

   Pan_For_Chan : array (MIDI.MIDI_Channel) of WNM_HAL.Audio_Pan :=
     (others => WNM_HAL.Init_Pan);

   Volume_For_Chan : array (MIDI.MIDI_Channel) of WNM_HAL.Audio_Volume :=
     (others => WNM_HAL.Init_Volume);

   Overall_Synth_Perf : WNM.Utils.Perf_Timer;
   Synth_Perf : array (Tresses_Channels) of WNM.Utils.Perf_Timer;

   G_CPU_Load : CPU_Load := 0.0 with Volatile, Atomic;
   G_Max_CPU_Load : CPU_Load := 0.0 with Volatile, Atomic;
   G_Count_Missed_Deadlines : HAL.UInt32 := 0 with Volatile, Atomic;

   -- Coproc Event Queue --
   package Coproc_Event_Queues
   is new WNM.Generic_Queue (Coproc.Message, "Synth coproc");
   Coproc_Event_Queue : Coproc_Event_Queues.Instance
     (WNM_Configuration.Coproc_Queue_Capacity);

   procedure Next_Points (Output : out WNM.Mixer.FX_Send_Buffers);

   function Vol_To_Param (V : MIDI.MIDI_Data)
                          return Tresses.Param_Range
     with Inline_Always;

   function To_Volume (V : Tresses.Param_Range)
                       return WNM_HAL.Audio_Volume
     with Inline_Always;

   function To_Pan (V : Tresses.Param_Range)
                    return WNM_HAL.Audio_Pan
     with Inline_Always;

   function To_Shape (V : MIDI.MIDI_Data)
                      return Tresses.LFO.Shape_Kind
     with Inline_Always;

   -----------
   -- Start --
   -----------

   procedure Start (This : in out WNM.Utils.Perf_Timer) is
   begin
      if WNM_Configuration.Individual_Synth_Perf_Enabled then
         WNM.Utils.Start (This);
      end if;
   end Start;

   ----------
   -- Stop --
   ----------

   procedure Stop (This : in out WNM.Utils.Perf_Timer) is
   begin
      if WNM_Configuration.Individual_Synth_Perf_Enabled then
         WNM.Utils.Stop (This);
      end if;
   end Stop;

   ------------------
   -- Vol_To_Param --
   ------------------

   function Vol_To_Param (V : MIDI.MIDI_Data)
                          return Tresses.Param_Range
   is
      V_Clamp : constant MIDI.MIDI_Data := MIDI.MIDI_Data'Min (V, 100);
      Ret : constant Tresses.Param_Range := Param_Range (V_Clamp) *
        (Param_Range'Last / Param_Range (100));
   begin
      return Ret;
   end Vol_To_Param;

   ---------------
   -- To_Volume --
   ---------------

   function To_Volume (V : Tresses.Param_Range)
                       return WNM_HAL.Audio_Volume
   is (WNM_HAL.Audio_Volume (V / 328));

   ------------
   -- To_Pan --
   ------------

   function To_Pan (V : Tresses.Param_Range)
                    return WNM_HAL.Audio_Pan
   is (WNM_HAL.Audio_Pan (V / 328));

   --------------
   -- To_Shape --
   --------------

   function To_Shape (V : MIDI.MIDI_Data)
                      return Tresses.LFO.Shape_Kind
   is (case V is
          when 0 => Tresses.LFO.Sine,
          when 1 => Tresses.LFO.Triangle,
          when 2 => Tresses.LFO.Ramp_Up,
          when 3 => Tresses.LFO.Ramp_Down,
          when 4 => Tresses.LFO.Exp_Up,
          when 5 => Tresses.LFO.Exp_Down,
          when others => Tresses.LFO.Random
      );

   -------------------
   -- Last_CPU_Load --
   -------------------

   function Last_CPU_Load return CPU_Load
   is (G_CPU_Load);

   ------------------
   -- Max_CPU_Load --
   ------------------

   function Max_CPU_Load return CPU_Load
   is (G_Max_CPU_Load);

   ----------------------
   -- Missed_Deadlines --
   ----------------------

   function Missed_Deadlines return HAL.UInt32
   is (G_Count_Missed_Deadlines);

   --------------------
   -- Synth_CPU_Load --
   --------------------

   function Synth_CPU_Load (Chan : MIDI.MIDI_Channel) return CPU_Load
   is (if WNM_Configuration.Individual_Synth_Perf_Enabled
         and then
          Chan in Synth_Perf'Range
       then WNM.Utils.Load (Synth_Perf (Chan))
       else 0.0);

   ------------------------
   -- Synth_CPU_Max_Load --
   ------------------------

   function Synth_CPU_Max_Load (Chan : MIDI.MIDI_Channel) return CPU_Load
   is (if WNM_Configuration.Individual_Synth_Perf_Enabled
         and then
          Chan in Synth_Perf'Range
       then WNM.Utils.Max_Load (Synth_Perf (Chan))
       else 0.0);

   --------------------------
   -- Synth_CPU_Load_Reset --
   --------------------------

   procedure Synth_CPU_Load_Reset (Chan : MIDI.MIDI_Channel) is
   begin
      if WNM_Configuration.Individual_Synth_Perf_Enabled
         and then
          Chan in Synth_Perf'Range
      then
         WNM.Utils.Reset (Synth_Perf (Chan));
      end if;
   end Synth_CPU_Load_Reset;

   ------------------------
   -- Clear_Max_CPU_Load --
   ------------------------

   procedure Clear_Max_CPU_Load is
   begin
      G_Max_CPU_Load := 0.0;
   end Clear_Max_CPU_Load;

   ----------------------------
   -- Clear_Missed_Deadlines --
   ----------------------------

   procedure Clear_Missed_Deadlines is
   begin
      G_Count_Missed_Deadlines := 0;
   end Clear_Missed_Deadlines;

   ----------------------
   -- Push_Copro_Event --
   ----------------------

   procedure Push_Copro_Event (Msg : WNM.Coproc.Message) is
   begin
      Coproc_Event_Queues.Push (Coproc_Event_Queue, Msg);
   end Push_Copro_Event;

   ---------------------------
   -- Process_Coproc_Events --
   ---------------------------

   procedure Process_Coproc_Events is
      use MIDI;
      use WNM.Coproc;

      Msg : WNM.Coproc.Message;
      Success : Boolean;
   begin
      loop
         Coproc_Event_Queues.Pop (Coproc_Event_Queue, Msg, Success);

         exit when not Success;

         case Msg.Kind is

            when WNM.Coproc.Buffer_Available =>

               Next_Points (WNM.Mixer.Mixer_Buffers (Msg.Buffer_Id));

               --  Send the buffers back to main CPU
               WNM.Coproc.Push_To_Main (Msg);

            when WNM.Coproc.MIDI_Event =>

               --  Ada.Text_IO.Put_Line ("Synth message is MIDI");
               --  Ada.Text_IO.Put_Line
               --    (Clock'Img & " - " &
               --     MIDI.Img (Msg.MIDI_Evt));

               if Msg.MIDI_Evt.Chan in Synth_Voices'Range then
                  declare
                     Voice : Voice_Class renames
                       Synth_Voices (Msg.MIDI_Evt.Chan).all;
                  begin
                     case Msg.MIDI_Evt.Kind is
                     when MIDI.Note_On =>

                        declare
                           Key : constant MIDI_Key := Msg.MIDI_Evt.Key;
                        begin
                           if Msg.MIDI_Evt.Chan in Declick_Channels then
                              --  Held until the render, see Render_Declicked
                              Pending_Note (Msg.MIDI_Evt.Chan) :=
                                (Active   => True,
                                 Key      => Key,
                                 Velocity => Msg.MIDI_Evt.Velocity);
                           else
                              if Msg.MIDI_Evt.Chan = Sample1_Channel then
                                 Sampler1.Set_MIDI_Pitch (Key);
                              elsif Msg.MIDI_Evt.Chan = Sample2_Channel then
                                 Sampler2.Set_MIDI_Pitch (Key);
                              elsif Msg.MIDI_Evt.Chan = Chord_Channel then

                                 Chord.Key_On (Msg.MIDI_Evt.Key,
                                               Tresses.MIDI_Param
                                                 (Msg.MIDI_Evt.Velocity));

                              else
                                 if Msg.MIDI_Evt.Chan in Bend_Pitch_Voices
                                 then
                                    --  Start already bent, so a hit
                                    --  triggered while the wheel is held
                                    --  off centre lands on the bent pitch
                                    --  instead of only following the wheel
                                    --  once it moves again.
                                    Base_Pitch (Msg.MIDI_Evt.Chan) :=
                                      Tresses.MIDI_Pitch
                                        (Standard.MIDI.MIDI_UInt8 (Key));
                                    Bend_Applied (Msg.MIDI_Evt.Chan) :=
                                      Bend_Offset (Msg.MIDI_Evt.Chan);
                                    Voice.Set_Pitch
                                      (Bent_Pitch (Msg.MIDI_Evt.Chan));
                                 else
                                    Voice.Set_Pitch
                                      (Tresses.MIDI_Pitch
                                         (Standard.MIDI.MIDI_UInt8 (Key)));
                                 end if;
                              end if;

                              Voice.Note_On (Tresses.MIDI_Param
                                             (Msg.MIDI_Evt.Velocity));
                           end if;

                           if Msg.MIDI_Evt.Chan /= Chord_Channel then
                              if Retrig_Enabled (Msg.MIDI_Evt.Chan)
                                and then Msg.MIDI_Evt.Chan in Note_Channels
                              then
                                 WNM.Note_Priority.Note_On
                                   (Note_Prio (Msg.MIDI_Evt.Chan),
                                    Key, Msg.MIDI_Evt.Velocity);
                              else
                                 Last_Key (Msg.MIDI_Evt.Chan) := Key;
                              end if;
                           end if;

                           if LFO_Syncs (Msg.MIDI_Evt.Chan) then
                              LFOs (Msg.MIDI_Evt.Chan).Sync;
                           end if;
                        end;

                     when MIDI.Note_Off =>

                        declare
                           Key : constant MIDI_Key := Msg.MIDI_Evt.Key;
                        begin
                           if Msg.MIDI_Evt.Chan in Declick_Channels
                             and then Pending_Note
                               (Msg.MIDI_Evt.Chan).Active
                             and then Pending_Note
                               (Msg.MIDI_Evt.Chan).Key = Key
                           then
                              --  Pressed and released within the same
                              --  buffer, so it never sounded. Drop it,
                              --  rather than let the held strike land after
                              --  the release and leave the voice stuck on.
                              Pending_Note (Msg.MIDI_Evt.Chan).Active :=
                                False;
                           end if;

                           if Msg.MIDI_Evt.Chan = Chord_Channel then
                              Chord.Key_Off (Msg.MIDI_Evt.Key);

                           elsif not Retrig_Enabled (Msg.MIDI_Evt.Chan)
                             or else Msg.MIDI_Evt.Chan not in Note_Channels
                           then
                              --  Stock behavior: only release if this key
                              --  matches the last one played.
                              if Last_Key (Msg.MIDI_Evt.Chan) = Key then
                                 Voice.Note_Off;
                                 Last_Key (Msg.MIDI_Evt.Chan) := 0;
                              end if;

                           else
                              declare
                                 Result : WNM.Note_Priority.Off_Result;
                              begin
                                 WNM.Note_Priority.Note_Off
                                   (Note_Prio (Msg.MIDI_Evt.Chan),
                                    Key, Result);

                                 case Result.Kind is
                                 when WNM.Note_Priority.No_Change =>
                                    null;

                                 when WNM.Note_Priority.Silence =>
                                    Voice.Note_Off;

                                 when WNM.Note_Priority.Retrigger =>
                                    --  Another key is still held: resume it
                                    --  instead of releasing the voice, so
                                    --  trills don't die on the newest
                                    --  key's release.
                                    if Msg.MIDI_Evt.Chan in Declick_Channels
                                    then
                                       Pending_Note (Msg.MIDI_Evt.Chan) :=
                                         (Active   => True,
                                          Key      => Result.Key,
                                          Velocity => Result.Velocity);
                                    else
                                       Voice.Set_Pitch
                                         (Tresses.MIDI_Pitch
                                            (Standard.MIDI.MIDI_UInt8
                                               (Result.Key)));
                                       Voice.Note_On
                                         (Tresses.MIDI_Param
                                            (Result.Velocity));
                                    end if;
                                 end case;
                              end;
                           end if;
                        end;

                     when MIDI.Pitch_Bend =>
                        if Msg.MIDI_Evt.Chan in Bend_Channels then
                           Bend_Offset (Msg.MIDI_Evt.Chan) :=
                             Bend_To_Units (Msg.MIDI_Evt);

                           case Msg.MIDI_Evt.Chan is
                              when Chord_Channel =>
                                 Chord.Set_Bend
                                   (Bend_Offset (Msg.MIDI_Evt.Chan));
                              when Sample1_Channel =>
                                 Sampler1.Set_Bend
                                   (Bend_Offset (Msg.MIDI_Evt.Chan));
                              when Sample2_Channel =>
                                 Sampler2.Set_Bend
                                   (Bend_Offset (Msg.MIDI_Evt.Chan));
                              when others =>
                                 null;
                           end case;
                        end if;

                     when MIDI.Continous_Controller =>
                        case Msg.MIDI_Evt.Controller is
                           when LFO_Compatible_CC =>

                              if Msg.MIDI_Evt.Chan = Sample1_Channel
                                and then
                                  Msg.MIDI_Evt.Controller = Voice_Param_1_CC
                              then
                                 Sampler1.Set_Sample
                                   (Msg.MIDI_Evt.Controller_Value);

                              elsif Msg.MIDI_Evt.Chan = Sample2_Channel
                                and then
                                  Msg.MIDI_Evt.Controller = Voice_Param_1_CC
                              then
                                 Sampler2.Set_Sample
                                   (Msg.MIDI_Evt.Controller_Value);

                              elsif Msg.MIDI_Evt.Controller in
                                Voice_Volume_CC | Voice_Pan_CC
                              then
                                 In_Voice_Parameters
                                   (Msg.MIDI_Evt.Chan)
                                   (Msg.MIDI_Evt.Controller)
                                   := Vol_To_Param
                                     (Msg.MIDI_Evt.Controller_Value);

                              else

                                 In_Voice_Parameters
                                   (Msg.MIDI_Evt.Chan)
                                   (Msg.MIDI_Evt.Controller)
                                   := Tresses.MIDI_Param
                                     (Msg.MIDI_Evt.Controller_Value);
                              end if;

                           when Voice_Engine_CC =>

                              case Msg.MIDI_Evt.Chan is
                              when Kick_Channel =>
                                 TK.Set_Engine
                                   (Kick_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when Lead_Channel =>
                                 Lead.Set_Engine
                                   (Lead_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when Bass_Channel =>
                                 Bass.Set_Engine
                                   (Lead_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when Snare_Channel =>
                                 TS.Set_Engine
                                   (Snare_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when Hihat_Channel =>
                                 HH.Set_Engine
                                   (HH_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when Chord_Channel =>
                                 Chord.Set_Engine
                                   (Chord_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when Sample1_Channel =>
                                 Sampler1.Set_Engine
                                   (Sampler_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when Sample2_Channel =>
                                 Sampler2.Set_Engine
                                   (Sampler_Engines
                                      (Msg.MIDI_Evt.Controller_Value));
                              when others =>
                                 null;
                              end case;

                           when Voice_FX_CC =>
                              FX_Send (Msg.MIDI_Evt.Chan) :=
                                (case Msg.MIDI_Evt.Controller_Value is
                                    when FX_Select_Bypass     => Bypass,
                                    when FX_Select_Overdrive  => Overdrive,
                                    when FX_Select_Reverb     => Reverb,
                                    when FX_Select_Bitcrusher => Bitcrusher,
                                    when others => Bypass);

                           when Voice_LFO_Rate_CC =>
                              LFOs (Msg.MIDI_Evt.Chan).Set_Rate
                                (MIDI_Param (Msg.MIDI_Evt.Controller_Value),
                                 WNM_Configuration.Audio.Samples_Per_Buffer);

                           when Voice_LFO_Shape_CC =>
                              LFOs (Msg.MIDI_Evt.Chan).Set_Shape
                                (To_Shape (Msg.MIDI_Evt.Controller_Value));

                           when Voice_LFO_Amp_CC =>
                              LFOs (Msg.MIDI_Evt.Chan).Set_Amplitude
                                (MIDI_Param (Msg.MIDI_Evt.Controller_Value));

                           when Voice_LFO_Amp_Mode_CC =>
                              LFOs (Msg.MIDI_Evt.Chan).Set_Amp_Mode
                                (Tresses.LFO.Amplitude_Kind'Enum_Val
                                   (Msg.MIDI_Evt.Controller_Value));

                           when Voice_LFO_Target_CC =>
                              LFO_Targets (Msg.MIDI_Evt.Chan) :=
                                Msg.MIDI_Evt.Controller_Value;

                           when Voice_LFO_Loop_CC =>
                              LFOs (Msg.MIDI_Evt.Chan).Set_Loop_Mode
                                (if Msg.MIDI_Evt.Controller_Value /= 0
                                 then Tresses.LFO.Repeat
                                 else Tresses.LFO.One_Shot);

                           when Voice_LFO_Sync_CC =>
                              LFO_Syncs (Msg.MIDI_Evt.Chan) :=
                                Msg.MIDI_Evt.Controller_Value /= 0;

                           when Voice_Retrig_CC =>
                              if Msg.MIDI_Evt.Chan in Retrig_Enabled'Range
                              then
                                 Retrig_Enabled (Msg.MIDI_Evt.Chan) :=
                                   Msg.MIDI_Evt.Controller_Value /= 0;
                              end if;

                           when Chord_Voices_CC =>
                              if Msg.MIDI_Evt.Chan = Chord_Channel then
                                 Chord.Set_Active_Voices
                                   (Natural
                                      (Msg.MIDI_Evt.Controller_Value) + 1);
                              end if;

                           when others =>
                              null;
                        end case;
                     when others =>
                        null;
                     end case;
                  end;

               elsif Msg.MIDI_Evt.Chan = Sample_Rec_Playback_Channel then
                  case Msg.MIDI_Evt.Kind is
                     when Note_On =>
                        Sample_Rec_Playback.Note_On (Msg.MIDI_Evt.Key);
                     when others =>
                        null;
                  end case;
               end if;

            when Synth_CPU_Crash =>
               raise Program_Error with "Synth exception requested";
         end case;
      end loop;
   end Process_Coproc_Events;

   -----------------------
   -- LFO_Current_Value --
   -----------------------

   function LFO_Current_Value (Chan : Tresses_Channels) return Tresses.S16 is
   begin
      return LFO_Values (Chan);
   end LFO_Current_Value;

   ---------------------------
   -- Param_Value_After_LFO --
   ---------------------------

   function Param_Value_After_LFO (Chan : Tresses_Channels)
                                   return Tresses.Param_Range
   is
      Target : constant MIDI.MIDI_Data := LFO_Targets (Chan);
   begin
      if Target in LFO_Compatible_CC then
         return Out_Voice_Parameters (Chan) (Target);
      else
         return 0;
      end if;
   end Param_Value_After_LFO;

   ----------------------------
   -- Param_Value_Before_LFO --
   ----------------------------

   function Param_Value_Before_LFO (Chan : Tresses_Channels)
                                    return Tresses.Param_Range
   is
      Target : constant MIDI.MIDI_Data := LFO_Targets (Chan);
   begin
      if Target in LFO_Compatible_CC then
         return In_Voice_Parameters (Chan) (Target);
      else
         return 0;
      end if;
   end  Param_Value_Before_LFO;

   -----------------
   -- Next_Points --
   -----------------

   procedure Next_Points (Output : out WNM.Mixer.FX_Send_Buffers)
   is
      Buffer, Aux_Buffer : WNM_HAL.Mono_Buffer;

      --------------
      -- Add_Clip --
      --------------

      function Add_Clip (A : Param_Range; B : S16) return Param_Range is
         Result : constant S32 := S32 (A) + S32 (B);
      begin
         if Result > S32 (Param_Range'Last) then
            return Param_Range'Last;
         elsif Result < S32 (Param_Range'First) then
            return Param_Range'First;
         else
            return Param_Range (Result);
         end if;
      end Add_Clip;

      ---------
      -- Mix --
      ---------

      procedure Mix (Chan : MIDI.MIDI_Channel) is
         FX : constant FX_Kind := FX_Send (Chan);
         Volume : constant Audio_Volume := Volume_For_Chan (Chan);
         Pan : constant Audio_Pan := Pan_For_Chan (Chan);

         L_Peak_Tmp, R_Peak_Tmp : S16;
      begin
         WNM_HAL.Mix (Output.L (FX), Output.R (FX),
                      Buffer, Volume, Pan, L_Peak_Tmp, R_Peak_Tmp);

         L_Peak (Chan) := L_Peak_Tmp;
         R_Peak (Chan) := R_Peak_Tmp;

         Utils.Peak_Decay (L_Peak_History (Chan));
         Utils.Peak_Decay (R_Peak_History (Chan));

         L_Peak_History (Chan) :=
           S16'Max (L_Peak_History (Chan), L_Peak (Chan));

         R_Peak_History (Chan) :=
           S16'Max (R_Peak_History (Chan), R_Peak (Chan));
      end Mix;
   begin
      Utils.Start (Overall_Synth_Perf);

      --  Keep the glide engines' resolution in step with the setting.
      --  One store per buffer, so no need to wire up a change notification.
      Tresses.Glide_Full_Resolution :=
        WNM.Persistent.Data.Glide_Res = High;

      --  Take input params
      Out_Voice_Parameters := In_Voice_Parameters;

      --  Compute LFOs
      for Chan in LFOs'Range loop
         LFO_Values (Chan) := LFOs (Chan).Render;
      end loop;

      --  Apply LFOs
      for Chan in Tresses_Channels loop
         if LFO_Targets (Chan) in LFO_Compatible_CC then
            Out_Voice_Parameters (Chan)(LFO_Targets (Chan)) :=
              Add_Clip (Out_Voice_Parameters (Chan)(LFO_Targets (Chan)),
                        LFO_Values (Chan));
         end if;
      end loop;

      --  Set params
      for Chan in Tresses_Channels loop
         Synth_Voices (Chan).Set_Param
           (1, Out_Voice_Parameters (Chan)(Voice_Param_1_CC));
         Synth_Voices (Chan).Set_Param
           (2, Out_Voice_Parameters (Chan)(Voice_Param_2_CC));
         Synth_Voices (Chan).Set_Param
           (3, Out_Voice_Parameters (Chan)(Voice_Param_3_CC));
         Synth_Voices (Chan).Set_Param
           (4, Out_Voice_Parameters (Chan)(Voice_Param_4_CC));

         Pan_For_Chan (Chan) := To_Pan
           (Out_Voice_Parameters (Chan)(Voice_Pan_CC));

         Volume_For_Chan (Chan) := To_Volume
            (Out_Voice_Parameters (Chan)(Voice_Volume_CC));
      end loop;

      --  Send the FX parameters in FX buffer
      Output.Parameters (Overdrive) := Out_Voice_Parameters (Drive_Channel);
      Output.Parameters (Bitcrusher) :=
        Out_Voice_Parameters (Bitcrusher_Channel);
      Output.Parameters (Reverb) := Out_Voice_Parameters (Reverb_Channel);

      if WNM.Mixer.Get_Sample_Rec_Mode in WNM.Mixer.Play then
         --  We are in sample record playback mode, the synth CPU is now in
         --  charge of playing the recorded sample.

         Sample_Rec_Playback.Render (Output.R (Bypass));
         Output.L (Bypass) := Output.R (Bypass);

      elsif WNM.Mixer.Get_Sample_Rec_Mode in WNM.Mixer.Saving then
         --  Do nothing...
         null;
      else

         --  Regular synthesis of all channels

         Start (Synth_Perf (Kick_Channel));
         Apply_Bend (Kick_Channel);
         TK.Render (Buffer);
         Mix (Kick_Channel);
         Stop (Synth_Perf (Kick_Channel));

         Start (Synth_Perf (Snare_Channel));
         Apply_Bend (Snare_Channel);
         TS.Render (Buffer);
         Mix (Snare_Channel);
         Stop (Synth_Perf (Snare_Channel));

         Start (Synth_Perf (Lead_Channel));
         Render_Declicked (Lead, Lead_Channel, Buffer, Aux_Buffer);
         Mix (Lead_Channel);
         Stop (Synth_Perf (Lead_Channel));

         Start (Synth_Perf (Bass_Channel));
         Render_Declicked (Bass, Bass_Channel, Buffer, Aux_Buffer);
         Mix (Bass_Channel);
         Stop (Synth_Perf (Bass_Channel));

         Start (Synth_Perf (Chord_Channel));
         Chord.Render (Buffer);
         Mix (Chord_Channel);
         Stop (Synth_Perf (Chord_Channel));

         Start (Synth_Perf (Sample1_Channel));
         Sampler1.Render (Buffer);
         Mix (Sample1_Channel);
         Stop (Synth_Perf (Sample1_Channel));

         Start (Synth_Perf (Sample2_Channel));
         Sampler2.Render (Buffer);
         Mix (Sample2_Channel);
         Stop (Synth_Perf (Sample2_Channel));

         Start (Synth_Perf (Hihat_Channel));
         Apply_Bend (Hihat_Channel);
         HH.Render (Buffer);
         Mix (Hihat_Channel);
         Stop (Synth_Perf (Hihat_Channel));
      end if;

      Utils.Stop (Overall_Synth_Perf);

      G_CPU_Load := Utils.Load (Overall_Synth_Perf);

      if G_CPU_Load > 100.0 then
         G_Count_Missed_Deadlines := G_Count_Missed_Deadlines + 1;
      end if;

      if G_CPU_Load > G_Max_CPU_Load then
         G_Max_CPU_Load := G_CPU_Load;
      end if;

   end Next_Points;

   ----------------------
   -- Lead_Engine_Last --
   ----------------------

   ----------------------
   -- Render_Declicked --
   ----------------------

   procedure Render_Declicked
     (V      : in out Tresses.Voices.Macro.Instance;
      Chan   :        Declick_Channels;
      Buffer :    out WNM_HAL.Mono_Buffer;
      Aux    :    out WNM_HAL.Mono_Buffer)
   is
      P     : Pending_Strike renames Pending_Note (Chan);
      Split : constant Natural := Buffer'First + Declick_Samples - 1;
   begin
      Apply_Bend (Chan);

      if not P.Active then
         V.Render (Buffer, Aux);
         Last_Out (Chan) := Buffer (Buffer'Last);
         return;
      end if;

      P.Active := False;

      if abs Integer (Last_Out (Chan)) < Declick_Floor then
         --  Nothing meaningful sounding, so there is nothing to declick.
         --  Strike immediately and leave the attack completely alone.
         Base_Pitch (Chan) :=
           Tresses.MIDI_Pitch (Standard.MIDI.MIDI_UInt8 (P.Key));
         Bend_Applied (Chan) := Bend_Offset (Chan);
         V.Set_Pitch (Bent_Pitch (Chan));
         V.Note_On (Tresses.MIDI_Param (P.Velocity));
         V.Render (Buffer, Aux);
         Last_Out (Chan) := Buffer (Buffer'Last);
         return;
      end if;

      --  Ramp the outgoing note to silence, so the switch happens from
      --  zero and the pitch change has nothing to step away from.
      V.Render (Buffer (Buffer'First .. Split), Aux (Aux'First .. Split));
      for I in Buffer'First .. Split loop
         Buffer (I) := Tresses.S16
           ((Tresses.S32 (Buffer (I)) * Declick_Ramp (Split - I)) / 2**15);
      end loop;

      Base_Pitch (Chan) :=
        Tresses.MIDI_Pitch (Standard.MIDI.MIDI_UInt8 (P.Key));
      Bend_Applied (Chan) := Bend_Offset (Chan);
      V.Set_Pitch (Bent_Pitch (Chan));
      V.Note_On (Tresses.MIDI_Param (P.Velocity));

      --  And back up, so the incoming note starts from zero too.
      V.Render (Buffer (Split + 1 .. Buffer'Last),
                Aux (Split + 1 .. Aux'Last));
      for I in Split + 1 ..
        Natural'Min (Split + Declick_Samples, Buffer'Last)
      loop
         Buffer (I) := Tresses.S16
           ((Tresses.S32 (Buffer (I)) * Declick_Ramp (I - Split - 1))
            / 2**15);
      end loop;

      Last_Out (Chan) := Buffer (Buffer'Last);
   end Render_Declicked;

   function Lead_Engine_Last return MIDI.MIDI_Data
   is (Lead_Engine_Range'Last);

   ---------------------
   -- Lead_Engine_Img --
   ---------------------

   function Lead_Engine_Img (Engine : MIDI.MIDI_Data) return String
   is (Tresses.Img (Lead_Engines (Engine)));

   ----------------------
   -- Lead_Param_Label --
   ----------------------

   function Lead_Param_Label (Engine : MIDI.MIDI_Data;
                              Id : Tresses.Param_Id)
                              return String
   is
      E : constant Tresses.Engines := Lead_Engines (Engine);
   begin
      if E = Tresses.Voice_Analog_Buzz and then Id = 1 then
         --  Tresses labels this "Waveform", but it doesn't pick a waveform.
         --  It shifts which of the band-limited comb tables the oscillator
         --  reads, so what it actually controls is brightness.
         return "Comb Brightness";
      end if;

      return Tresses.Macro.Param_Label (E, Id);
   end Lead_Param_Label;

   ----------------------------
   -- Lead_Param_Short_Label --
   ----------------------------

   function Lead_Param_Short_Label (Engine : MIDI.MIDI_Data;
                                    Id : Tresses.Param_Id)
                                    return Tresses.Short_Label
   is
      E : constant Tresses.Engines := Lead_Engines (Engine);
   begin
      return Tresses.Macro.Param_Short_Label (E, Id);
   end Lead_Param_Short_Label;

   ----------------------
   -- Kick_Engine_Last --
   ----------------------

   function Kick_Engine_Last return MIDI.MIDI_Data
   is (Kick_Engine_Range'Last);

   ---------------------
   -- Kick_Engine_Img --
   ---------------------

   function Kick_Engine_Img (Engine : MIDI.MIDI_Data) return String
   is (WNM.Voices.Kick_Voice.Img (Kick_Engines (Engine)));

   ----------------------
   -- Kick_Param_Label --
   ----------------------

   function Kick_Param_Label (Id : Tresses.Param_Id) return String
   is (TK.Param_Label (Id));

   ----------------------------
   -- Kick_Param_Short_Label --
   ----------------------------

   function Kick_Param_Short_Label (Id : Tresses.Param_Id)
                                    return Tresses.Short_Label
   is (TK.Param_Short_Label (Id));

   -----------------------
   -- Snare_Engine_Last --
   -----------------------

   function Snare_Engine_Last return MIDI.MIDI_Data
   is (Snare_Engine_Range'Last);

   ----------------------
   -- Snare_Engine_Img --
   ----------------------

   function Snare_Engine_Img (Engine : MIDI.MIDI_Data) return String
   is (WNM.Voices.Snare_Voice.Img (Snare_Engines (Engine)));

   -----------------------
   -- Snare_Param_Label --
   -----------------------

   function Snare_Param_Label (Id : Tresses.Param_Id) return String
   is (TS.Param_Label (Id));

   -----------------------------
   -- Snare_Param_Short_Label --
   -----------------------------

   function Snare_Param_Short_Label (Id : Tresses.Param_Id)
                                    return Tresses.Short_Label
   is (TS.Param_Short_Label (Id));

   -----------------------
   -- Hihat_Engine_Last --
   -----------------------

   function Hihat_Engine_Last return MIDI.MIDI_Data
   is (HH_Engine_Range'Last);

   ----------------------
   -- Hihat_Engine_Img --
   ----------------------

   function Hihat_Engine_Img (Engine : MIDI.MIDI_Data) return String
   is (WNM.Voices.Hihat_Voice.Img (HH_Engines (Engine)));

   ------------------------
   -- Cymbal_Param_Label --
   ------------------------

   function Hihat_Param_Label (Id : Tresses.Param_Id) return String
   is (HH.Param_Label (Id));

   ------------------------------
   -- Cymbal_Param_Short_Label --
   ------------------------------

   function Hihat_Param_Short_Label (Id : Tresses.Param_Id)
                                      return Tresses.Short_Label
   is (HH.Param_Short_Label (Id));

   -------------------------
   -- Sampler_Engine_Last --
   -------------------------

   function Sampler_Engine_Last return MIDI.MIDI_Data
   is (Sampler_Engine_Range'Last);

   ------------------------
   -- Sampler_Engine_Img --
   ------------------------

   function Sampler_Engine_Img (Engine : MIDI.MIDI_Data) return String
   is (Voices.Sampler_Voice.Img (Sampler_Engines (Engine)));

   -------------------------
   -- Sampler_Param_Label --
   -------------------------

   function Sampler_Param_Label (Chan : Sampler_Channels;
                                 Id   : Tresses.Param_Id)
                                 return String
   is (case Chan is
          when Sample1_Channel => Sampler1.Param_Label (Id),
          when Sample2_Channel => Sampler2.Param_Label (Id));

   -------------------------------
   -- Sampler_Param_Short_Label --
   -------------------------------

   function Sampler_Param_Short_Label (Chan : Sampler_Channels;
                                       Id   : Tresses.Param_Id)
                                       return Tresses.Short_Label
   is (case Chan is
          when Sample1_Channel => Sampler1.Param_Short_Label (Id),
          when Sample2_Channel => Sampler2.Param_Short_Label (Id));

   ------------------------
   -- Reverb_Param_Label --
   ------------------------

   function Reverb_Param_Label (Id : Tresses.Param_Id)
                                 return String
   is (Mixer.FX_Reverb.Param_Label (Id));

   ------------------------------
   -- Reverb_Param_Short_Label --
   ------------------------------

   function Reverb_Param_Short_Label (Id : Tresses.Param_Id)
                                       return Tresses.Short_Label
   is (Mixer.FX_Reverb.Param_Short_Label (Id));

   -----------------------
   -- Drive_Param_Label --
   -----------------------

   function Drive_Param_Label (Id : Tresses.Param_Id)
                               return String
   is (Mixer.FX_Drive.Param_Label (Id));

   -----------------------------
   -- Drive_Param_Short_Label --
   -----------------------------

   function Drive_Param_Short_Label (Id : Tresses.Param_Id)
                                     return Tresses.Short_Label
   is (Mixer.FX_Drive.Param_Short_Label (Id));

   --------------------------
   -- Bitcrush_Param_Label --
   --------------------------

   function Bitcrush_Param_Label (Id : Tresses.Param_Id)
                               return String
   is (Mixer.FX_Bitcrush.Param_Label (Id));

   --------------------------------
   -- Bitcrush_Param_Short_Label --
   --------------------------------

   function Bitcrush_Param_Short_Label (Id : Tresses.Param_Id)
                                        return Tresses.Short_Label
   is (Mixer.FX_Bitcrush.Param_Short_Label (Id));

   -----------------------
   -- Chord_Engine_Last --
   -----------------------

   function Chord_Engine_Last return MIDI.MIDI_Data
   is (Chord_Engine_Range'Last);

   ----------------------
   -- Chord_Engine_Img --
   ----------------------

   function Chord_Engine_Img (Engine : MIDI.MIDI_Data) return String
   is (Voices.Chord_Voice.Img (Chord_Engines (Engine)));

   -----------------------
   -- Chord_Param_Label --
   -----------------------

   function Chord_Param_Label (Id : Tresses.Param_Id)
                               return String
   is (Chord.Param_Label (Id));

   -----------------------------
   -- Chord_Param_Short_Label --
   -----------------------------

   function Chord_Param_Short_Label (Id : Tresses.Param_Id)
                                     return Tresses.Short_Label
   is (Chord.Param_Short_Label (Id));

begin
   Lead.Set_Engine (Voice_Saw_Swarm);
   Lead.Set_User_Waveform (User_Waveform'Access);
   Bass.Set_User_Waveform (User_Waveform'Access);
end WNM.Synth;

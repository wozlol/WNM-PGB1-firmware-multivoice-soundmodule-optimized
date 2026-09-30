package MIDI.Time
with Preelaborate
is

   type BPM is new Float range 0.01 .. 2000.00;

   type Step_Count is mod 48;

   type Time_Division is (Div_4, Div_8, Div_16, Div_32,
                          Div_4T, Div_8T, Div_16T, Div_32T);

   function On_Time (Div : Time_Division; Step : Step_Count) return Boolean
   is ((case Div is
          when Div_4   => (Step mod 24) = 0,
          when Div_8   => (Step mod 12) = 0,
          when Div_16  => (Step mod  6) = 0,
          when Div_32  => (Step mod  3) = 0,
          when Div_4T  => (Step mod 16) = 0,
          when Div_8T  => (Step mod  8) = 0,
          when Div_16T => (Step mod  4) = 0,
          when Div_32T => (Step mod  2) = 0));

end MIDI.Time;

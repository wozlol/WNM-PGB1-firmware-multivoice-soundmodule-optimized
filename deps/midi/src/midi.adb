package body MIDI is

   ---------
   -- Img --
   ---------

   function Img (Msg : Message) return String is
   begin
      case Msg.Kind is
         when Note_Off =>
         return "(Note Off," & Msg.Chan'Img & "," &
           Msg.Key'Img & "," &
           Msg.Velocity'Img & ")";

         when Note_On =>
            return "(Note On," & Msg.Chan'Img & "," & Msg.Key'Img & "," &
              Msg.Velocity'Img & ")";

         when Aftertouch =>
            return "(Aftertouch," & Msg.Chan'Img & "," & Msg.Key'Img & "," &
              Msg.Velocity'Img & ")";

         when Continous_Controller =>
            return "(Continous Controller," & Msg.Chan'Img & "," &
              Msg.Controller'Img & "," &
              Msg.Controller_Value'Img & ")";

         when Patch_Change =>
            return "(Patch Change," & Msg.Chan'Img & "," &
              Msg.Instrument'Img & ")";

         when Channel_Pressure =>
            return "(Channel Pressure," & Msg.Chan'Img & "," &
              Msg.Pressure'Img & ")";

         when Pitch_Bend =>
            return "(Pitch Bend," & Msg.Chan'Img & "," & Msg.Bend'Img & ")";

         when Sys =>
            case Msg.Cmd is
               when Exclusive =>
                  return "(System Exclusive)";
               when End_Exclusive =>
                  return "(End System Exclusive)";
               when Song_Position =>
                  return "(Song Posistion," & Msg.S1'Img & "," &
                    Msg.S2'Img & ")";
               when Song_Select =>
                  return "(Song Select," & Msg.S1'Img & ")";
               when Bus_Select =>
                  return "(Bus Select," & Msg.S1'Img & ")";
               when Tune_Request =>
                  return "(Tune Request)";
               when Timming_Tick =>
                  return "(Timming Tick)";
               when Start_Song =>
                  return "(Start Song)";
               when Continue_Song =>
                  return "(Continue Song)";
               when Stop_Song =>
                  return "(Stop Song)";
               when Active_Sensing =>
                  return "(Active Sensing)";
               when Reset =>
                  return "(Reset)";
            end case;
      end case;
   end Img;

end MIDI;

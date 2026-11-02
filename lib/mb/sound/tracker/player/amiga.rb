module MB
  module Sound
    module Tracker
      class Player
        # Amiga period arithmetic shared by MOD and the Amiga-period modes of
        # S3M, XM, and IT: a period is a sample clock divider, so the
        # playback rate is a clock over the period, slides move the period
        # in steps (bigger steps are bigger at low notes, as on the
        # hardware), and notes come from a table.
        module Amiga
          # The Amiga's PAL clock over 2 (Paula's sample rate is this over
          # the period): period 428 plays 8287 Hz.
          PAL = 3_546_894.6

          # The period at +note+ (neutral; 60 is period 428) with +finetune+
          # (eighths of a semitone, -8..7): ProTracker's finetune row
          # (ModReader::FINETUNE_PERIODS) over 2 per octave above C-1 (note
          # 48) and times 2 per octave below it, fractional as the
          # reference plays them (finetune 0 is the period table itself);
          # rounded to an integer on hardware.
          def amiga_period(note, finetune = 0)
            i = note - ModReader::FIRST_NOTE
            if finetune == 0 && i >= 0 && i < ModReader::PERIODS.length
              return ModReader::PERIODS[i]
            end
            octave, semi = (note - 48).divmod(12)
            base = ModReader::FINETUNE_PERIODS.fetch(finetune.clamp(-8, 7))[semi]
            p = base * 2.0**-octave
            hardware? ? p.round : p
          end
        end
      end
    end
  end
end

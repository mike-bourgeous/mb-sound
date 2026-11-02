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
          # (eighths of a semitone, -8..7) times +scale+ (4 for S3M/XM's
          # finer periods): the table's period (the notes the composer
          # heard; equal-tempered outside the table's five octaves) moved by
          # the finetune, rounded to an integer on hardware.
          def amiga_period(note, finetune = 0, scale: 1)
            base = 428.0 * 2**(-(note - 60) / 12.0)
            i = note - ModReader::FIRST_NOTE
            base = ModReader::PERIODS[i].to_f if i >= 0 && i < ModReader::PERIODS.length
            p = base * 2**(-finetune / 96.0) * scale
            hardware? ? p.round : p
          end
        end
      end
    end
  end
end

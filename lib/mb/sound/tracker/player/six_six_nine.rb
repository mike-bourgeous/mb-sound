module MB
  module Sound
    module Tracker
      class Player
        # Composer 669 effects.  669 works in Hz: a channel's "period" here
        # is its playback rate, and slides add to it.  Effects carry on from
        # row to row until the channel gets a new note or effect.  Timing:
        # each order entry sets the speed (ticks per row) and the last row
        # its pattern plays; ticks run at a fixed 78 BPM (32 ms).
        #
        # Measured from the reference player's output (tracker-1, openmpt123
        # 0.7.13, synthetic one-note files; playback rates in Hz per tick
        # per unit of the effect's value): a/b slide up/down by 80 every
        # tick, c slides toward the new note by 40 without restarting it, d
        # raises the note by 80 once, e alternates the note and the note
        # plus 668 on odd ticks (669's square vibrato), f sets the speed
        # from this row.  UNIS 669's g (balance) and h (retrigger) are
        # skipped.
        class SixSixNine < Player
          # Playback-rate steps per unit of an effect value (see the class
          # description).
          SLIDE = 80.0
          TONE_PORTA = 40.0
          ADJUST = 80.0
          VIBRATO = 668.0

          private

          def frequency(_ch, period)
            period.to_f
          end

          def setup
            super
            @order_speed = nil
          end

          def start_row(order, row, cells)
            if row == 0 || @last_order != order
              @last_order = order
              s = @song.flags[:tempos][order]
              @speed = s if s && s > 0
            end
            super
            brk = @song.flags[:breaks][order]
            @break_to = 0 if brk && row >= brk && @jump_to.nil? && @break_to.nil?
          end

          # The playback rate of +note+ (60 is the sample's rate).
          def rate_of(ch, note)
            s = ch.sample && @song.samples[ch.sample]
            base = s ? s.rate : SixSixNineReader::RATE
            r = base * 2**((note - 60) / 12.0)
            hardware? ? r.round : r
          end

          def row_cell(ch, cell)
            ch.out_period = ch.period
            return continuing(ch, 0) if cell.nil?

            if cell.note
              s = cell.instrument - 1
              if cell.effect == 2 && ch.period && ch.voice
                ch.target = rate_of(ch, cell.note)
              elsif (smp = @song.samples[s]) && !smp.empty?
                ch.sample = s
                ch.note = cell.note
                ch.period = rate_of(ch, cell.note)
                ch.target = nil
                trigger(ch, s, 0)
              end
              ch.arp = nil
            end
            ch.volume = (cell.volume * 64 / 15.0).round if cell.volume

            if cell.effect
              ch.arp = [cell.effect, cell.param]
              case cell.effect
              when 2 then ch.target ||= ch.period
              when 3 then ch.period += cell.param * ADJUST if ch.period
              when 5 then @speed = cell.param if cell.param > 0
              when 6 then unsupported('g balance (UNIS 669)')
              when 7 then unsupported('h retrigger (UNIS 669)')
              end
            end
            continuing(ch, 0)
          end

          def tick_effect(ch, _cell, t)
            ch.out_period = ch.period
            continuing(ch, t)
          end

          # The channel's carried effect on tick +t+ of the row.
          def continuing(ch, t)
            return unless ch.arp && ch.period
            effect, param = ch.arp
            case effect
            when 0 then ch.period += param * SLIDE
            when 1 then ch.period = [ch.period - param * SLIDE, 1.0].max
            when 2
              if ch.target
                step = param * TONE_PORTA
                ch.period = ch.period < ch.target ? [ch.period + step, ch.target].min : [ch.period - step, ch.target].max
              end
            when 4 then ch.out_period = ch.period + (t.odd? ? param * VIBRATO : 0) if param > 0
            end
            ch.out_period = ch.period unless effect == 4
          end
        end
      end
    end
  end
end

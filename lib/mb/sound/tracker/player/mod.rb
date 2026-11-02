module MB
  module Sound
    module Tracker
      class Player
        # ProTracker effects (MOD): 0xy arpeggio, 1xx/2xx portamento up and
        # down, 3xx tone portamento, 4xy vibrato, 5xy/6xy tone portamento or
        # vibrato plus volume slide, 7xy tremolo, 8xx pan (0..255; not
        # ProTracker's, but common), 9xx sample offset, Axy volume slide,
        # Bxx position jump, Cxx volume, Dxx pattern break, Fxx speed (below
        # 32) or tempo; E1x/E2x fine portamento, E4x/E7x vibrato and tremolo
        # waveforms, E5x finetune, E6x pattern loop, E8x pan, E9x retrigger,
        # EAx/EBx fine volume slides, ECx note cut, EDx note delay, EEx
        # pattern delay.  Skipped (counted in Result#unsupported): E0x
        # filter, E3x glissando, EFx invert loop.
        class MOD < Player
          include Amiga

          # ProTracker's period limits (B-3 and C-1); multichannel MODs
          # (FastTracker's) slide further.
          PT_LIMITS = [113, 856].freeze

          def initialize(song, **options)
            super
            @limits = song.channels == 4 ? PT_LIMITS : [28, 6848]
          end

          private

          def frequency(_ch, period)
            Amiga::PAL / period.to_f
          end

          def period_of(note, finetune)
            amiga_period(note, finetune)
          end

          def clamp_period(p)
            p.clamp(*@limits)
          end

          def row_cell(ch, cell)
            ch.out_period = ch.period
            ch.out_volume = nil
            ch.delay_note = nil
            ch.cut_tick = nil
            ch.retrig = nil
            ch.arp = nil
            return if cell.nil?

            effect = cell.effect
            param = cell.param
            sub = effect == 14 ? param >> 4 : nil
            x = param & 15

            if cell.instrument
              s = cell.instrument - 1
              if (smp = @song.samples[s]) && !smp.empty?
                ch.pending = s
                ch.volume = smp.volume
                ch.finetune = smp.finetune
              else
                # (an empty sample number stops the channel in ProTracker)
                ch.pending = nil
              end
            end
            ch.finetune = x >= 8 ? x - 16 : x if sub == 5

            if cell.note
              if sub == 13 && x > 0
                ch.delay_note = cell
              else
                note_on(ch, cell)
              end
            end
            ch.out_period = ch.period

            case effect
            when 0 then ch.arp = param if param > 0
            when 3 then ch.memory[:porta] = param if param > 0
            when 4, 6
              vib_memory(ch, param) if effect == 4
            when 5
            when 7
              ch.memory[:trem_speed] = param >> 4 if param >> 4 > 0
              ch.memory[:trem_depth] = x if x > 0
            when 8 then ch.pan = param / 127.5 - 1.0
            when 9 then ch.memory[:offset] = param if param > 0
            when 11 then @jump_to = param
            when 12 then ch.volume = [param, 64].min
            when 13
              r = (param >> 4) * 10 + x
              @break_to = r > 63 ? 0 : r
            when 14 then extended(ch, sub, x)
            when 15
              if param == 0
                @stopped = true
              elsif param < 32
                @speed = param
              else
                set_tempo(param)
              end
            end
          end

          def vib_memory(ch, param)
            ch.memory[:vib_speed] = param >> 4 if param >> 4 > 0
            ch.memory[:vib_depth] = param & 15 if param & 15 > 0
          end

          # A note on the row's first tick (or a delayed one).
          def note_on(ch, cell)
            effect = cell.effect
            target = period_of(cell.note, ch.finetune)
            target = cell.period if hardware? && cell.period && ch.finetune == 0
            sample = ch.pending || ch.sample
            if (effect == 3 || effect == 5) && ch.period && ch.voice
              ch.target = target
              ch.sample = sample if sample
              return
            end
            return if sample.nil?

            ch.note = cell.note
            ch.period = target
            ch.target = nil
            ch.vib_pos = 0 if ch.vib_wave < 4
            ch.trem_pos = 0 if ch.trem_wave < 4
            offset = 0
            if effect == 9
              ch.memory[:offset] = cell.param if cell.param > 0
              offset = ch.memory[:offset] * 256
            end
            trigger(ch, sample, offset)
          end

          def extended(ch, sub, x)
            case sub
            when 0 then unsupported('E0x filter')
            when 1 then slide(ch, -x) if ch.period
            when 2 then slide(ch, x) if ch.period
            when 3 then unsupported('E3x glissando') if x > 0
            when 4 then ch.vib_wave = x
            when 6
              if x == 0
                ch.loop_row = current_row
              elsif ch.loop_count == 0
                ch.loop_count = x
                @loop_to = ch.loop_row
              else
                ch.loop_count -= 1
                @loop_to = ch.loop_row if ch.loop_count > 0
              end
            when 7 then ch.trem_wave = x
            when 8 then ch.pan = x / 7.5 - 1.0
            when 9 then ch.retrig = x if x > 0
            when 10 then ch.volume = [ch.volume + x, 64].min
            when 11 then ch.volume = [ch.volume - x, 0].max
            when 12
              x == 0 ? ch.volume = 0 : ch.cut_tick = x
            when 14 then @delay_rows = [@delay_rows, x].max
            when 15 then unsupported('EFx invert loop') if x > 0
            end
          end

          def slide(ch, amount)
            ch.period = clamp_period(ch.period + amount)
            ch.out_period = ch.period
          end

          def tick_effect(ch, cell, t)
            ch.out_period = ch.period
            ch.out_volume = nil
            if ch.delay_note && t == (ch.delay_note.param & 15)
              note_on(ch, ch.delay_note)
              ch.out_period = ch.period
            end
            return if cell.nil? || cell.effect.nil?

            param = cell.param
            case cell.effect
            when 0 then arpeggio(ch, t) if ch.arp
            when 1 then slide(ch, -param) if ch.period && param > 0
            when 2 then slide(ch, param) if ch.period && param > 0
            when 3 then tone_porta(ch, ch.memory[:porta])
            when 4 then vibrato(ch, ch.memory[:vib_speed], ch.memory[:vib_depth])
            when 5
              tone_porta(ch, ch.memory[:porta])
              volume_slide(ch, param)
            when 6
              vibrato(ch, ch.memory[:vib_speed], ch.memory[:vib_depth])
              volume_slide(ch, param)
            when 7 then tremolo(ch, ch.memory[:trem_speed], ch.memory[:trem_depth])
            when 10 then volume_slide(ch, param)
            when 14
              x = param & 15
              case param >> 4
              when 9 then trigger(ch, ch.sample, 0) if ch.retrig && ch.sample && t % ch.retrig == 0
              when 12 then ch.volume = 0 if ch.cut_tick == t
              end
            end
          end

          def arpeggio(ch, t)
            k = t % 3
            return if k == 0 || ch.period.nil?
            semis = k == 1 ? ch.arp >> 4 : ch.arp & 15
            ch.out_period = arp_period(ch, semis)
          end

          # The period +semis+ above the channel's: the table's note above
          # the nearest note (hardware), or the exact ratio.
          def arp_period(ch, semis)
            return ch.period * 2**(-semis / 12.0) unless hardware?
            base = ModReader.note_of((ch.period * 2**(ch.finetune / 96.0)).round)
            base ? period_of(base + semis, ch.finetune) : ch.period
          end

          def tone_porta(ch, speed)
            return unless ch.target && ch.period
            if ch.period < ch.target
              ch.period = [ch.period + speed, ch.target].min
            else
              ch.period = [ch.period - speed, ch.target].max
            end
            ch.out_period = ch.period
          end

          def vibrato(ch, speed, depth)
            return unless ch.period
            ch.out_period = ch.period + vib_delta(ch.vib_wave, ch.vib_pos, depth, 7)
            ch.vib_pos = (ch.vib_pos + speed) & 63
          end

          # A vibrato or tremolo offset: the waveform times +depth+, shifted
          # down by +shift+ bits (integer on hardware).
          def vib_delta(wave, pos, depth, shift)
            w = wave_value(wave, pos)
            return w * depth / (1 << shift).to_f unless hardware?
            d = (w.abs * depth) >> shift
            w < 0 ? -d : d
          end

          def tremolo(ch, speed, depth)
            ch.out_volume = (ch.volume + vib_delta(ch.trem_wave, ch.trem_pos, depth, 6)).clamp(0, 64)
            ch.trem_pos = (ch.trem_pos + speed) & 63
          end

          def current_row
            @current_row
          end

          def start_row(order, row, cells)
            @current_row = row
            super
          end
        end
      end
    end
  end
end

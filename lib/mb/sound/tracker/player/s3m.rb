module MB
  module Sound
    module Tracker
      class Player
        # Scream Tracker 3 effects (S3M; effects are letters, A=1..Z=26).
        # Periods are ST3's (four times the Amiga's at C2Spd 8363, scaled
        # by each sample's C2Spd), and the playback rate is 14317056 Hz
        # over the period.
        #
        # Played: A speed, B jump, C break (decimal row), D volume slides
        # (fine DxF/DFx), E/F portamento down/up (fine EFx, extra fine EEx),
        # G tone portamento, H vibrato, I tremor, J arpeggio, K/L vibrato or
        # tone portamento plus volume slide, O sample offset, Q retrigger
        # with volume change, R tremolo, S3x/S4x waveforms, S8x pan, SBx
        # pattern loop, SCx cut, SDx delay, SEx pattern delay, T tempo, U
        # fine vibrato, V global volume, X pan.  D, E, F, I, J, K, L, Q, R,
        # and S share one memory per channel, as in ST3.  Skipped (counted):
        # S1x glissando, S2x finetune, SAx, SFx, Y panbrello, Z MIDI.
        class S3M < Player
          # The playback rate over the period (Hz).
          CLOCK = 14_317_056.0

          # ST3's octave-0 periods (C to B), times 16.
          TABLE = [1712, 1616, 1525, 1440, 1357, 1281, 1209, 1141, 1077, 1017, 961, 907].freeze

          # Effects sharing the "last value" memory.
          SHARED = [4, 5, 6, 9, 10, 11, 12, 17, 18, 19].freeze

          # Q's volume changes by the x nibble.
          RETRIG_VOLUME = {
            1 => [:add, -1], 2 => [:add, -2], 3 => [:add, -4], 4 => [:add, -8], 5 => [:add, -16], 6 => [:mul, 2 / 3r], 7 => [:mul, 1 / 2r],
            9 => [:add, 1], 10 => [:add, 2], 11 => [:add, 4], 12 => [:add, 8], 13 => [:add, 16], 14 => [:mul, 3 / 2r], 15 => [:mul, 2],
          }.freeze

          def initialize(song, **options)
            super
            @limits = song.flags[:amiga_limits] ? [113 * 4, 856 * 4] : [28, 65_535]
            @fast = song.flags[:fast_slides]
          end

          private

          def frequency(_ch, period)
            CLOCK / period.to_f
          end

          def sample_rate(ch)
            s = ch.sample && @song.samples[ch.sample]
            s ? s.rate : 8363.0
          end

          # The ST3 period of neutral +note+ at C2Spd +rate+.
          def period_of(note, rate)
            oct = note / 12 - 1
            semi = note % 12
            if hardware?
              base = oct >= 0 ? (8363 * 16 * TABLE[semi]) >> oct : (8363 * 16 * TABLE[semi]) << -oct
              (base / rate.round).clamp(1, 1 << 20)
            else
              8363.0 * 16 * TABLE[semi] / 2.0**oct / rate
            end
          end

          def clamp_period(p)
            p.clamp(*@limits)
          end

          def start_row(order, row, cells)
            @current_row = row
            super
          end

          def param_of(ch, cell)
            e = cell.effect
            v = cell.param
            if SHARED.include?(e)
              v == 0 ? v = ch.memory[:last] : ch.memory[:last] = v
            end
            v
          end

          def row_cell(ch, cell)
            ch.out_period = ch.period
            ch.out_volume = nil
            ch.delay_note = nil
            ch.cut_tick = nil
            ch.retrig = nil
            ch.tremor = nil if cell.nil? || cell.effect != 9
            return if cell.nil?

            e = cell.effect
            v = e ? param_of(ch, cell) : 0
            ch.vol_column = v # (the effect's value with memory, for the ticks)

            if e == 19 && v >> 4 == 13 && (v & 15) > 0
              ch.delay_note = cell
            else
              cell_note(ch, cell, e, v)
            end

            case e
            when 1 then @speed = v if v > 0
            when 2 then @jump_to = v
            when 3
              r = (v >> 4) * 10 + (v & 15)
              @break_to = r > 63 ? 0 : r
            when 4 then volume_slide_s3m(ch, v, 0)
            when 5, 6 then porta_fine(ch, e, v)
            when 7 then ch.memory[:porta] = v if v > 0
            when 8, 21 then vib_params(ch, v)
            when 9 then ch.tremor ||= [0, v]
            when 10 then ch.arp = v
            when 11, 12 then volume_slide_s3m(ch, v, 0)
            when 15
            when 17 then ch.retrig = v
            when 18
              ch.memory[:trem_speed] = v >> 4 if v >> 4 > 0
              ch.memory[:trem_depth] = v & 15 if v & 15 > 0
            when 19 then special(ch, v)
            when 20 then set_tempo(v) if v >= 32
            when 22 then @global_volume = [v, 64].min.to_f
            when 24 then ch.pan = v >= 0xA4 ? 0.0 : (v.clamp(0, 128) / 64.0 - 1.0)
            when 25 then unsupported('Y panbrello')
            when 26 then unsupported('Z MIDI macro')
            end
            ch.out_period = ch.period
            tremor(ch) if e == 9
          end

          # A cell's note, instrument, and volume.
          def cell_note(ch, cell, e, v)
            if cell.instrument
              s = cell.instrument - 1
              smp = @song.samples[s]
              if smp && !smp.empty?
                ch.pending = s
                ch.volume = smp.volume
              end
            end
            if cell.note == :cut
              cut(ch)
            elsif cell.note.is_a?(Integer)
              sample = ch.pending || ch.sample
              if (e == 7 || e == 12) && ch.period && ch.voice
                ch.target = period_of(cell.note, sample ? @song.samples[sample].rate : sample_rate(ch))
                ch.memory[:porta] = v if e == 7 && v > 0
              elsif sample
                ch.sample = sample
                ch.note = cell.note
                ch.period = period_of(cell.note, @song.samples[sample].rate)
                ch.target = nil
                ch.vib_pos = 0 if ch.vib_wave < 4
                ch.trem_pos = 0 if ch.trem_wave < 4
                offset = 0
                if e == 15
                  ch.memory[:offset] = cell.param if cell.param > 0
                  offset = ch.memory[:offset] * 256
                end
                trigger(ch, sample, offset)
              end
            end
            ch.pending = nil if cell.note.is_a?(Integer)
            ch.volume = cell.volume if cell.volume
          end

          def vib_params(ch, v)
            ch.memory[:vib_speed] = v >> 4 if v >> 4 > 0
            ch.memory[:vib_depth] = v & 15 if v & 15 > 0
          end

          # D: +tick+ 0 runs fine slides (and normal ones with fast slides).
          def volume_slide_s3m(ch, v, tick)
            x = v >> 4
            y = v & 15
            if x == 15 && y > 0
              ch.volume = [ch.volume - y, 0].max if tick == 0
            elsif y == 15 && x > 0
              ch.volume = [ch.volume + x, 64].min if tick == 0
            elsif tick > 0 || @fast
              if y == 0
                ch.volume = [ch.volume + x, 64].min
              else
                ch.volume = [ch.volume - y, 0].max
              end
            end
          end

          # E/F on tick 0: fine (Fx) and extra fine (Ex) slides.
          def porta_fine(ch, e, v)
            return unless ch.period
            amount = if v >= 0xF0 then (v & 15) * 4
                     elsif v >= 0xE0 then v & 15
                     else 0
                     end
            return if amount == 0
            ch.period = clamp_period(ch.period + (e == 5 ? amount : -amount))
          end

          def special(ch, v)
            x = v & 15
            case v >> 4
            when 1 then unsupported('S1x glissando') if x > 0
            when 2 then unsupported('S2x finetune')
            when 3 then ch.vib_wave = x
            when 4 then ch.trem_wave = x
            when 8 then ch.pan = x / 7.5 - 1.0
            when 10 then unsupported('SAx stereo control')
            when 11
              if x == 0
                ch.loop_row = @current_row
              elsif ch.loop_count == 0
                ch.loop_count = x
                @loop_to = ch.loop_row
              else
                ch.loop_count -= 1
                @loop_to = ch.loop_row if ch.loop_count > 0
              end
            when 12
              x == 0 ? cut(ch) : ch.cut_tick = x
            when 14 then @delay_rows = [@delay_rows, x].max
            when 15 then unsupported('SFx funk repeat') if x > 0
            end
          end

          def tick_effect(ch, cell, t)
            ch.out_period = ch.period
            ch.out_volume = nil
            if ch.delay_note && t == (ch.delay_note.param & 15)
              cell_note(ch, ch.delay_note, nil, 0)
              ch.out_period = ch.period
            end
            return if cell.nil? || cell.effect.nil?

            v = ch.vol_column
            case cell.effect
            when 4 then volume_slide_s3m(ch, v, t)
            when 5, 6
              if v < 0xE0 && ch.period
                ch.period = clamp_period(ch.period + (cell.effect == 5 ? v * 4 : -v * 4))
                ch.out_period = ch.period
              end
            when 7 then tone_porta(ch, ch.memory[:porta] * 4)
            when 8 then vibrato(ch, 5)
            when 21 then vibrato(ch, 7)
            when 9 then tremor(ch)
            when 10 then arpeggio(ch, t)
            when 11
              vibrato(ch, 5)
              volume_slide_s3m(ch, v, t)
            when 12
              tone_porta(ch, ch.memory[:porta] * 4)
              volume_slide_s3m(ch, v, t)
            when 17 then retrigger(ch, t)
            when 18 then tremolo(ch)
            when 19
              ch.cut_tick && t == ch.cut_tick && v >> 4 == 12 and cut(ch)
            end
          end

          def tone_porta(ch, speed)
            return unless ch.target && ch.period
            ch.period = ch.period < ch.target ? [ch.period + speed, ch.target].min : [ch.period - speed, ch.target].max
            ch.out_period = ch.period
          end

          def vibrato(ch, shift)
            return unless ch.period
            w = wave_value(ch.vib_wave, ch.vib_pos)
            depth = ch.memory[:vib_depth]
            d = hardware? ? (w.abs * depth) >> shift : w.abs * depth / (1 << shift).to_f
            ch.out_period = ch.period + (w < 0 ? -d : d)
            ch.vib_pos = (ch.vib_pos + ch.memory[:vib_speed]) & 63
          end

          def tremolo(ch)
            w = wave_value(ch.trem_wave, ch.trem_pos)
            d = (w.abs * ch.memory[:trem_depth]) >> 6
            ch.out_volume = (ch.volume + (w < 0 ? -d : d)).clamp(0, 64)
            ch.trem_pos = (ch.trem_pos + ch.memory[:trem_speed]) & 63
          end

          def tremor(ch)
            count, v = ch.tremor || [0, ch.vol_column]
            on = (v >> 4) + 1
            off = (v & 15) + 1
            ch.out_volume = count % (on + off) < on ? nil : 0
            ch.tremor = [count + 1, v]
          end

          def arpeggio(ch, t)
            k = t % 3
            return if k == 0 || ch.period.nil? || ch.arp.nil?
            semis = k == 1 ? ch.arp >> 4 : ch.arp & 15
            ch.out_period = ch.period * 2**(-semis / 12.0)
            ch.out_period = ch.out_period.round if hardware?
          end

          def retrigger(ch, t)
            v = ch.retrig || 0
            y = v & 15
            return if y == 0 || t % y != 0 || ch.sample.nil?
            if (change = RETRIG_VOLUME[v >> 4])
              ch.volume = (change[0] == :add ? ch.volume + change[1] : (ch.volume * change[1]).floor).clamp(0, 64)
            end
            trigger(ch, ch.sample, 0)
          end
        end
      end
    end
  end
end

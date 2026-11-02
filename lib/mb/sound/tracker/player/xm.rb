module MB
  module Sound
    module Tracker
      class Player
        # FastTracker 2 effects (XM): the ProTracker set (0-F, with FT2's
        # per-effect memories) plus G global volume, H global volume slide,
        # K key off, L envelope position, P pan slide, R multi retrigger, T
        # tremor, X1/X2 extra fine portamento, and the volume column (set
        # volume, slides, fine slides, vibrato speed and depth, pan, pan
        # slides, tone portamento).  Instruments map notes to samples
        # (Instrument#keymap), with volume and pan envelopes, fadeout after
        # key off, and auto-vibrato.  Linear frequencies (64 periods a
        # semitone, 8363 Hz at C-4) or Amiga periods (four times
        # ProTracker's), per the module's flag.  Skipped (counted): E3x
        # glissando, E0x, EFx.
        class XM < Player
          include Envelopes

          # FT2's fadeout scale (the volume fades from this by the
          # instrument's fadeout per tick after key off).
          FADE = 32_768

          def initialize(song, **options)
            super
            @linear = song.linear
          end

          private

          def setup
            super
            @channels.each { |ch| ch.pan = 0.0; ch.fade = FADE; ch.env_tick = 0; ch.key_on = false }
            @pan_ticks = Array.new(@song.channels, 0)
            @auto = Array.new(@song.channels) { [0, 0] } # [position, ticks since the note]
          end

          def frequency(_ch, period)
            if @linear
              8363.0 * 2**((4608 - period.to_f) / 768)
            else
              8363.0 * 1712 / period.to_f
            end
          end

          # The period of neutral +note+ on sample +s+ (its relative note
          # and finetune).
          def period_of(note, s)
            smp = @song.samples[s]
            n0 = note - 12 + (smp&.relative_note || 0)
            ft = smp&.finetune || 0
            if @linear
              # (FT2 steps finetune by 1/16 semitone, its top 5 bits: 4
              # linear periods; measured from openmpt123, finetune 12 and 13
              # play as 8, 46 as 40, 111 as 104)
              7680 - n0 * 64 - (ft >> 3) * 4
            else
              p = 1712.0 * 2**(-(n0 - 48 + ft / 128.0) / 12)
              hardware? ? p.round : p
            end
          end

          def clamp_period(p)
            return [p, PERIOD_FLOOR].max if unlimited?
            @linear ? p.clamp(1, 7680) : p.clamp(28, 65_535)
          end

          def start_row(order, row, cells)
            @current_row = row
            super
          end

          # +param+ or the effect's memory (+key+) when it is 0.
          def mem(ch, key, param)
            param == 0 ? ch.memory[key] : (ch.memory[key] = param)
          end

          def row_cell(ch, cell)
            ch.out_period = ch.period
            ch.out_volume = nil
            ch.delay_note = nil
            ch.cut_tick = nil
            ch.retrig = nil
            ch.arp = nil
            ch.tremor = nil
            return if cell.nil?

            e = cell.effect
            param = cell.param
            if e == 14 && param >> 4 == 13 && (param & 15) > 0
              ch.delay_note = cell
            else
              apply_cell(ch, cell)
            end

            case e
            when 0 then ch.arp = param if param > 0
            when 1 then mem(ch, :up, param)
            when 2 then mem(ch, :down, param)
            when 3 then mem(ch, :porta, param)
            when 4
              ch.memory[:vib_speed] = param >> 4 if param >> 4 > 0
              ch.memory[:vib_depth] = param & 15 if param & 15 > 0
            when 5, 6, 10 then mem(ch, :vol, param)
            when 7
              ch.memory[:trem_speed] = param >> 4 if param >> 4 > 0
              ch.memory[:trem_depth] = param & 15 if param & 15 > 0
            when 8 then ch.pan = param / 127.5 - 1.0
            when 11 then @jump_to = param
            when 12 then ch.volume = [param, 64].min
            when 13
              r = (param >> 4) * 10 + (param & 15)
              @break_to = r > 63 ? 0 : r
            when 14 then extended(ch, param)
            when 15
              if param == 0
                nil
              elsif param < 32
                @speed = param
              else
                set_tempo(param)
              end
            when 16 then @global_volume = [param, 64].min.to_f
            when 17 then mem(ch, :global, param)
            when 20 then (param == 0 ? key_off(ch) : ch.cut_tick = [:key_off, param])
            when 21 then ch.env_tick = param
            when 25 then mem(ch, :pan_slide, param)
            when 27 then ch.retrig = mem(ch, :retrig, param)
            when 29 then ch.tremor = [0, mem(ch, :tremor, param)]
            when 33
              x = param & 15
              case param >> 4
              when 1 then slide(ch, -mem(ch, :xup, x))
              when 2 then slide(ch, mem(ch, :xdown, x))
              end
            end
            volume_column_tick0(ch, cell.volume) if cell.volume && ch.delay_note.nil?
            ch.out_period = ch.period
            # (FT2's vibrato holds its waveform's value on a row's first
            # tick, measured: Effects::Oscillator :fasttracker)
            vibrato(ch, 0) if e == 4 || e == 6
          end

          def vibrato_style
            { kind: :protracker, timing: :fasttracker }
          end

          # A cell's note, instrument, and volume column value (on the row's
          # first tick, or a note delay's tick).
          def apply_cell(ch, cell)
            e = cell.effect
            porta = e == 3 || e == 5 || (cell.volume && cell.volume >> 4 == 15)
            ch.instrument = cell.instrument - 1 if cell.instrument
            inst = ch.instrument && @song.instruments[ch.instrument]
            note = cell.note

            if note == :off
              key_off(ch)
            elsif note.is_a?(Integer) && inst
              s, _ = inst.keymap[note.clamp(0, 119)]
              smp = s && @song.samples[s]
              if porta && ch.period && ch.voice
                ch.target = period_of(note, ch.sample || s)
              elsif smp && !smp.empty?
                ch.sample = s
                ch.note = note
                ch.period = period_of(note, s)
                ch.target = nil
                ch.vibrato.retrigger
                ch.trem_pos = 0 if ch.trem_wave < 4
                offset = 0
                if e == 9
                  offset = mem(ch, :offset, cell.param) * 256
                end
                trigger(ch, s, offset)
                reset_envelopes(ch) unless cell.instrument
              else
                cut(ch)
              end
            end

            if cell.instrument && ch.sample && inst
              smp = @song.samples[ch.sample]
              ch.volume = smp.volume
              ch.pan = smp.pan / 127.5 - 1.0 if smp.pan
              reset_envelopes(ch)
            end
            if cell.volume && cell.volume >= 0x10 && cell.volume <= 0x50
              ch.volume = cell.volume - 0x10
            elsif cell.volume && cell.volume >> 4 == 12
              ch.pan = (cell.volume & 15) * 16 / 127.5 - 1.0
            end
          end

          def reset_envelopes(ch)
            ch.key_on = true
            ch.env_tick = 0
            ch.fade = FADE
            @pan_ticks[ch.index] = 0
            @auto[ch.index] = [0, 0]
          end

          def key_off(ch)
            ch.key_on = false
            inst = ch.instrument && @song.instruments[ch.instrument]
            ch.volume = 0 unless inst&.volume_envelope&.enabled
          end

          def volume_column_tick0(ch, v)
            x = v & 15
            case v >> 4
            when 8 then ch.volume = [ch.volume - x, 0].max
            when 9 then ch.volume = [ch.volume + x, 64].min
            when 10 then ch.memory[:vib_speed] = x if x > 0
            when 11 then ch.memory[:vib_depth] = x if x > 0
            when 15 then ch.memory[:porta] = x * 16 if x > 0
            end
          end

          def volume_column_tick(ch, v)
            x = v & 15
            case v >> 4
            when 6 then ch.volume = [ch.volume - x, 0].max
            when 7 then ch.volume = [ch.volume + x, 64].min
            when 11 then vibrato(ch, 1)
            when 13 then ch.pan = [ch.pan - x / 127.5, -1.0].max
            when 14 then ch.pan = [ch.pan + x / 127.5, 1.0].min
            when 15 then tone_porta(ch)
            end
          end

          def extended(ch, param)
            x = param & 15
            case param >> 4
            when 0 then unsupported('E0x filter')
            when 1 then slide(ch, -mem(ch, :fup, x) * 4)
            when 2 then slide(ch, mem(ch, :fdown, x) * 4)
            when 3 then unsupported('E3x glissando') if x > 0
            when 4
              ch.vibrato.wave = x
              unsupported('E4x random vibrato') if x & 3 == 3
            when 5 then nil
            when 6
              if x == 0
                ch.loop_row = @current_row
              elsif ch.loop_count == 0
                ch.loop_count = x
                @loop_to = ch.loop_row
              else
                ch.loop_count -= 1
                @loop_to = ch.loop_row if ch.loop_count > 0
              end
            when 7 then ch.trem_wave = x
            when 8 then ch.pan = x / 7.5 - 1.0
            when 9 then ch.retrig = [:e9, x] if x > 0
            when 10 then ch.volume = [ch.volume + mem(ch, :fvup, x), 64].min
            when 11 then ch.volume = [ch.volume - mem(ch, :fvdown, x), 0].max
            when 12
              x == 0 ? ch.volume = 0 : ch.cut_tick = [:cut, x]
            when 14 then @delay_rows = [@delay_rows, x].max
            when 15 then unsupported('EFx funk repeat') if x > 0
            end
          end

          def slide(ch, amount)
            return unless ch.period
            ch.period = clamp_period(ch.period + amount)
            ch.out_period = ch.period
          end

          def tick_effect(ch, cell, t)
            ch.out_period = ch.period
            ch.out_volume = nil
            if ch.delay_note && t == (ch.delay_note.param & 15)
              apply_cell(ch, ch.delay_note)
              volume_column_tick0(ch, ch.delay_note.volume) if ch.delay_note.volume
              ch.out_period = ch.period
            end
            return if cell.nil?
            volume_column_tick(ch, cell.volume) if cell.volume
            return if cell.effect.nil?

            param = cell.param
            case cell.effect
            when 0 then arpeggio(ch, t) if ch.arp
            when 1 then slide(ch, -ch.memory[:up] * 4)
            when 2 then slide(ch, ch.memory[:down] * 4)
            when 3 then tone_porta(ch)
            when 4 then vibrato(ch, t)
            when 5
              tone_porta(ch)
              volume_slide(ch, ch.memory[:vol])
            when 6
              vibrato(ch, t)
              volume_slide(ch, ch.memory[:vol])
            when 7 then tremolo(ch)
            when 10 then volume_slide(ch, ch.memory[:vol])
            when 14
              kind, at = ch.cut_tick
              ch.volume = 0 if kind == :cut && at == t
              kind, x = ch.retrig
              trigger(ch, ch.sample, 0) if kind == :e9 && ch.sample && t % x == 0
            when 17
              v = ch.memory[:global]
              @global_volume = (v >> 4 > 0 ? @global_volume + (v >> 4) : @global_volume - (v & 15)).clamp(0, 64)
            when 20
              kind, at = ch.cut_tick
              key_off(ch) if kind == :key_off && at == t
            when 25
              v = ch.memory[:pan_slide]
              ch.pan = (v >> 4 > 0 ? ch.pan + (v >> 4) / 127.5 : ch.pan - (v & 15) / 127.5).clamp(-1.0, 1.0)
            when 27 then multi_retrig(ch, t)
            when 29 then tremor(ch)
            end
          end

          # Arpeggio in FT2's order (Effects::Arpeggio :fasttracker: its tick
          # counter counts down, so at speed 6 the row plays 0, y, x).
          def arpeggio(ch, t)
            return if ch.period.nil?
            semis = Effects::Arpeggio.semitones(ch.arp, t, speed: @speed, order: :fasttracker)
            return if semis == 0
            ch.out_period = @linear ? ch.period - semis * 64 : ch.period * 2**(-semis / 12.0)
            ch.out_period = ch.out_period.round if hardware?
          end

          def tone_porta(ch)
            return unless ch.target && ch.period
            ch.period = Effects::Slide.toward(ch.period, ch.target, ch.memory[:porta] * 4)
            ch.out_period = ch.period
          end

          # Vibrato on tick +t+: the waveform (Effects::Oscillator) times the
          # depth over 32, in periods.
          def vibrato(ch, t)
            return unless ch.period
            w = ch.vibrato.tick(t, ch.memory[:vib_speed]) or return
            depth = ch.memory[:vib_depth]
            d = hardware? ? (w.abs * depth) >> 5 : w.abs * depth / 32.0
            ch.out_period = ch.period + (w < 0 ? -d : d)
          end

          def tremolo(ch)
            w = wave_value(ch.trem_wave, ch.trem_pos)
            d = (w.abs * ch.memory[:trem_depth]) >> 6
            ch.out_volume = (ch.volume + (w < 0 ? -d : d)).clamp(0, 64)
            ch.trem_pos = (ch.trem_pos + ch.memory[:trem_speed]) & 63
          end

          def tremor(ch)
            count, v = ch.tremor || [0, ch.memory[:tremor]]
            on = (v >> 4) + 1
            off = (v & 15) + 1
            ch.out_volume = count % (on + off) < on ? nil : 0
            ch.tremor = [count + 1, v]
          end

          def multi_retrig(ch, t)
            v = ch.retrig || 0
            y = v & 15
            return if y == 0 || t % y != 0 || ch.sample.nil?
            if (change = S3M::RETRIG_VOLUME[v >> 4])
              ch.volume = (change[0] == :add ? ch.volume + change[1] : (ch.volume * change[1]).floor).clamp(0, 64)
            end
            trigger(ch, ch.sample, 0)
          end

          # Envelopes and fadeout move on after each tick.
          def end_tick(ch, _t)
            inst = ch.instrument && @song.instruments[ch.instrument]
            return unless inst && ch.voice
            ch.env_tick = envelope_next(inst.volume_envelope, ch.env_tick, ch.key_on) if ch.env_tick
            @pan_ticks[ch.index] = envelope_next(inst.pan_envelope, @pan_ticks[ch.index], ch.key_on)
            ch.fade = [ch.fade - inst.fadeout, 0].max if !ch.key_on && inst.volume_envelope&.enabled
          end

          # The instrument's auto-vibrato, on every tick.
          def before_record(ch, _t)
            inst = ch.instrument && @song.instruments[ch.instrument]
            return unless inst && ch.voice
            if (vib = inst.vibrato) && ch.out_period
              type, sweep, depth, rate = vib
              pos, age = @auto[ch.index]
              ramp = sweep > 0 ? [age.to_f / sweep, 1.0].min : 1.0
              w = wave_value(type == 1 ? 2 : (type == 2 ? 1 : 0), pos >> 2)
              ch.out_period += w * depth * ramp / 256.0
              @auto[ch.index] = [(pos + rate) & 255, age + 1]
            end
          end

          def output_volume(ch)
            v = (ch.out_volume || ch.volume).to_f.clamp(0, 64) / 64.0
            inst = ch.instrument && @song.instruments[ch.instrument]
            if inst
              env = envelope_value(inst.volume_envelope, ch.env_tick)
              v *= env / 64.0 if env
              v *= ch.fade.to_f / FADE
            end
            v * @global_volume / 64.0
          end

          def output_pan(ch)
            p = ch.pan.to_f.clamp(-1.0, 1.0)
            inst = ch.instrument && @song.instruments[ch.instrument]
            env = inst && envelope_value(inst.pan_envelope, @pan_ticks[ch.index])
            return p unless env
            (p + (env - 32) / 32.0 * (1 - p.abs)).clamp(-1.0, 1.0)
          end
        end
      end
    end
  end
end

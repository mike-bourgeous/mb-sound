module MB
  module Sound
    module Tracker
      class Player
        # Impulse Tracker effects (IT), built on the S3M player: the same
        # letters with IT's memories (D for D/K/L, E and F shared (and G
        # with the compatible-Gxx flag), H and U shared, the others their
        # own), hexadecimal C breaks, the volume column (volume, fine and
        # normal slides, pitch slides, pan, tone portamento, vibrato), M/N
        # channel volume, P pan slides, T tempo slides, V/W global volume, X
        # pan, SAx high offsets, S6x fine pattern delays, and S7x past-note
        # and new-note actions.  Linear slides (64 periods a semitone) or
        # Amiga periods, both from each sample's C5Speed (the rate of C-5,
        # note 60).
        #
        # Instruments map notes through their keyboard (a note may play
        # another note of another sample), with volume, pan, and pitch
        # envelopes (loops and sustain loops), fadeout after key off (the
        # 1024 scale) or a note fade, global volumes (sample, instrument,
        # channel, song), and default pans.  New note actions move the
        # sounding note to a background voice (continue, note off, or fade;
        # the instrument's NNA or S73-S76) that plays on in a log of its own
        # (Result#logs past the pattern channels: tracks :bg1, :bg2, ...)
        # until it fades out or its one-shot sample ends; duplicate checks
        # (DCT/DCA) apply to the background voices of the same channel.
        # Skipped (counted): filter envelopes, Y panbrello, Z macros, S9x,
        # SFx, S1x.
        class IT < S3M
          include Envelopes

          # IT's fadeout scale.
          FADE = 1024

          # Background voices at most (the oldest is cut for a new one).
          MAX_BACKGROUND = 16

          # Volume column tone portamento speeds (values 193-202).
          VOL_PORTA = [0, 1, 4, 8, 16, 32, 64, 96, 128, 255].freeze

          # A background voice (see the class description).
          Voice = Struct.new(:host, :sample, :note, :instrument, :period, :volume, :pan, :env_tick, :pan_tick, :pitch_tick, :fade, :fading, :key_on,
                             :channel_volume, :position, :log, keyword_init: true)

          def initialize(song, **options)
            super
            @linear = song.linear
            @range = @linear ? [1, 15_360] : [28, 65_535]
            @fast = false
          end

          private

          def setup
            super
            @channels.each { |ch|
              ch.fade = FADE
              ch.env_tick = 0
              ch.key_on = false
              ch.offset = 0.0
              ch.memory[:pan_tick] = 0
              ch.memory[:pitch_tick] = 0
              ch.memory[:fading] = false
              ch.memory[:nna] = nil
            }
            @voices = []
            @bg_logs = []
          end

          def finish
            @logs.concat(@bg_logs)
            super
          end

          def sample_rate_of(s)
            smp = s && @song.samples[s]
            smp ? smp.rate : 8363.0
          end

          def frequency(ch, period)
            rate = sample_rate_of(ch.sample)
            @linear ? rate * 2**((3840 - period.to_f) / 768) : CLOCK / period.to_f * rate / 8363.0
          end

          # The period of neutral +note+ (C-5 is 60) for sample +s+.
          def period_of(note, s)
            if @linear
              p = 7680 - note * 64
              hardware? ? p : p.to_f
            else
              super(note, 8363.0)
            end
          end

          def param_of(ch, cell)
            e = cell.effect
            v = cell.param
            key = case e
                  when 4, 11, 12 then :d
                  when 5, 6 then :ef
                  when 7 then @song.flags[:compat_gxx] ? :ef : :g
                  when 8, 21 then nil
                  else e
                  end
            return v if key.nil? || [1, 2, 3, 20, 22, 24].include?(e)
            v == 0 ? ch.memory[key] : (ch.memory[key] = v)
          end

          def row_cell(ch, cell)
            ch.out_period = ch.period
            ch.out_volume = nil
            ch.delay_note = nil
            ch.cut_tick = nil
            ch.retrig = nil
            ch.tremor = nil
            return if cell.nil?

            e = cell.effect
            v = e ? param_of(ch, cell) : 0
            ch.vol_column = v
            if e == 19 && v >> 4 == 13 && (v & 15) > 0
              ch.delay_note = cell
            else
              cell_note(ch, cell, e, v)
              volume_column(ch, cell.volume, 0) if cell.volume
            end

            case e
            when 1 then @speed = v if v > 0
            when 2 then @jump_to = v
            when 3 then @break_to = v
            when 4, 11, 12 then volume_slide_s3m(ch, v, 0)
            when 5, 6 then porta_fine(ch, e, v)
            when 7 then ch.memory[:porta] = v if v > 0
            when 8, 21 then vib_params(ch, v)
            when 9 then ch.tremor ||= [0, v]
            when 10 then ch.arp = v
            when 13 then ch.channel_volume = [v, 64].min
            when 14 then channel_volume_slide(ch, v, 0)
            when 16 then pan_slide(ch, v, 0)
            when 17 then ch.retrig = v
            when 18
              ch.memory[:trem_speed] = v >> 4 if v >> 4 > 0
              ch.memory[:trem_depth] = v & 15 if v & 15 > 0
            when 19 then special(ch, v)
            when 20 then set_tempo(v) if v >= 32
            when 22 then @global_volume = [v, 128].min / 2.0
            when 23 then global_slide(v, 0)
            when 24 then ch.pan = v / 127.5 - 1.0
            when 25 then unsupported('Y panbrello')
            when 26 then unsupported('Z MIDI macro')
            end
            ch.out_period = ch.period
            vibrato(ch, e == 21 ? 7 : 5, 0) if e == 8 || e == 11 || e == 21
            vibrato(ch, 5, 0) if cell.volume&.between?(203, 212) && !(e == 8 || e == 11 || e == 21)
            tremor(ch) if e == 9
          end

          # IT's vibrato (without old effects) moves on and reads its
          # waveform on every tick, the first included, starts upward, and
          # has its own tables (Effects::Waveform :it); with old effects it
          # plays as ST3's.
          def vibrato_style
            @song.flags[:old_effects] ? super : { kind: :it, timing: :impulse }
          end

          # The vibrato's period offset: ST3's with old effects; else
          # (value * depth) >> 4 for H (>> 6 for U), as 1/64 semitones
          # through IT's linear slide steps (Effects.it_linear_units) or as
          # periods (Amiga slides).  Measured: depth 8 swings 50 cents at
          # either rate, 1/16 semitone steps above 1/4 semitone.
          def vibrato_offset(w, depth, shift)
            return super if @song.flags[:old_effects]
            d = (w.abs * depth) >> (shift - 1)
            d = Effects.it_linear_units(d) if @linear
            d = w.abs * depth / (1 << (shift - 1)).to_f if !hardware? && !@linear
            w < 0 ? -d : d
          end

          # Arpeggio: semitones up as 64 linear periods each, or the
          # period's ratio (Amiga slides).
          def arpeggio(ch, t)
            return super unless @linear
            k = t % 3
            return if k == 0 || ch.period.nil? || ch.arp.nil?
            semis = k == 1 ? ch.arp >> 4 : ch.arp & 15
            ch.out_period = ch.period - semis * 64
          end

          def cell_note(ch, cell, e, v)
            inst = nil
            if cell.instrument
              ch.instrument = cell.instrument - 1 if @song.instruments
              ch.pending = cell.instrument - 1 unless @song.instruments
            end
            note = cell.note
            case note
            when :cut then cut(ch)
            when :off then key_off(ch)
            when :fade then ch.memory[:fading] = true
            when Integer
              porta = e == 7 || e == 12 || (cell.volume && cell.volume.between?(193, 202))
              s, played = sample_for(ch, note)
              smp = s && @song.samples[s]
              if porta && ch.period && ch.voice
                ch.target = period_of(played, s || ch.sample)
              elsif smp && !smp.empty?
                new_note_action(ch, s, played)
                ch.sample = s
                ch.note = played
                ch.period = period_of(played, s)
                ch.target = nil
                ch.vibrato.retrigger
                ch.trem_pos = 0 if ch.trem_wave < 4
                offset = 0
                if e == 15
                  offset = ch.memory[15] * 256 + (ch.memory[:high] || 0) * 65_536
                  offset = 0 if offset >= smp.length
                end
                ch.offset = offset.to_f
                trigger(ch, s, offset, played)
                start_note(ch, smp)
              end
            end
            if cell.instrument && ch.sample && !note.is_a?(Symbol)
              smp = @song.samples[ch.sample]
              ch.volume = smp.volume
              inst = @song.instruments && @song.instruments[ch.instrument]
              ch.pan = inst.pan / 32.0 - 1.0 if inst&.pan
              ch.pan = smp.pan / 32.0 - 1.0 if smp.pan
              start_note(ch, smp) unless note.is_a?(Integer)
            end
            ch.volume = cell.volume if cell.volume && cell.volume <= 64
          end

          # [the sample index, the note it plays] for +note+ on the
          # channel's instrument (or sample).
          def sample_for(ch, note)
            if @song.instruments
              inst = ch.instrument && @song.instruments[ch.instrument]
              return [nil, note] unless inst
              s, n = inst.keymap[note.clamp(0, 119)]
              [s, n]
            else
              [ch.pending || ch.sample, note]
            end
          end

          def start_note(ch, _smp)
            ch.key_on = true
            ch.env_tick = 0
            ch.memory[:pan_tick] = 0
            ch.memory[:pitch_tick] = 0
            ch.fade = FADE
            ch.memory[:fading] = false
          end

          def instrument_of(x)
            @song.instruments && x.instrument && @song.instruments[x.instrument]
          end

          def key_off(ch)
            ch.key_on = false
            env = instrument_of(ch)&.volume_envelope
            ch.memory[:fading] = true if env.nil? || !env.enabled || env.loop
          end

          # The new note action for the note sounding on +ch+: the
          # instrument's NNA (or S73-S76's), cutting it or moving it to a
          # background voice; then the duplicate check on the channel's
          # background voices.
          def new_note_action(ch, sample, note)
            inst = instrument_of(ch)
            nna = ch.memory[:nna] || inst&.nna || 0
            ch.memory[:nna] = nil
            if inst && inst.dct > 0
              @voices.each { |v|
                next unless v.host == ch.index && v.instrument == ch.instrument
                same = case inst.dct
                       when 1 then v.note == note
                       when 2 then v.sample == sample
                       else true # (3: the instrument)
                       end
                next unless same
                case inst.dca
                when 0 then v.fade = 0
                when 1 then v.key_on = false
                when 2 then v.fading = true
                end
              }
            end
            return unless ch.voice && ch.sample && nna > 0 && current_volume(ch) > 0
            move_to_background(ch, nna)
          end

          def move_to_background(ch, nna)
            @voices.shift.then { |old| old.fade = 0 } if @voices.length >= MAX_BACKGROUND
            busy = @voices.map(&:log)
            log = @bg_logs.find { |l| !busy.include?(l) } || Log.new(:"bg#{@bg_logs.length + 1}").tap { |l| @bg_logs << l }
            v = Voice.new(host: ch.index, sample: ch.sample, note: ch.note, instrument: ch.instrument, period: ch.out_period || ch.period, volume: ch.volume,
                          pan: ch.pan, env_tick: ch.env_tick, pan_tick: ch.memory[:pan_tick], pitch_tick: ch.memory[:pitch_tick], fade: ch.fade,
                          fading: ch.memory[:fading] || nna == 3, key_on: ch.key_on && nna == 1, channel_volume: ch.channel_volume,
                          position: ch.offset, log: log)
            @voices << v
            smp = @song.samples[v.sample]
            pad(log)
            log.triggers << Trigger.new(tick: @tick, sample: v.sample, offset: v.position.to_i.clamp(0, [smp.length - 1, 0].max), note: ch.note)
            cut(ch)
          end

          def volume_column(ch, vc, tick)
            case vc
            when 0..64 then nil
            when 65..74 then ch.volume = [ch.volume + (vc - 65), 64].min if tick == 0
            when 75..84 then ch.volume = [ch.volume - (vc - 75), 0].max if tick == 0
            when 85..94 then ch.volume = [ch.volume + (vc - 85), 64].min if tick > 0
            when 95..104 then ch.volume = [ch.volume - (vc - 95), 0].max if tick > 0
            when 105..114
              (ch.period = clamp_period(ch.period + (vc - 105) * 4); ch.out_period = ch.period) if tick > 0 && ch.period
            when 115..124
              (ch.period = clamp_period(ch.period - (vc - 115) * 4); ch.out_period = ch.period) if tick > 0 && ch.period
            when 128..192 then ch.pan = (vc - 128) / 32.0 - 1.0 if tick == 0
            when 193..202
              ch.memory[:porta] = VOL_PORTA[vc - 193] if tick == 0 && vc > 193
              tone_porta(ch, ch.memory[:porta] * 4) if tick > 0
            when 203..212
              ch.memory[:vib_depth] = vc - 203 if tick == 0 && vc > 203
              vibrato(ch, 5, tick) if tick > 0
            end
          end

          def channel_volume_slide(ch, v, tick)
            x = v >> 4
            y = v & 15
            delta = if x == 15 && y > 0 then tick == 0 ? -y : 0
                    elsif y == 15 && x > 0 then tick == 0 ? x : 0
                    elsif tick > 0 then y == 0 ? x : -y
                    else 0
                    end
            ch.channel_volume = (ch.channel_volume + delta).clamp(0, 64)
          end

          def pan_slide(ch, v, tick)
            x = v >> 4
            y = v & 15
            delta = if x == 15 && y > 0 then tick == 0 ? y : 0
                    elsif y == 15 && x > 0 then tick == 0 ? -x : 0
                    elsif tick > 0 then y == 0 ? -x : y
                    else 0
                    end
            ch.pan = (ch.pan + delta / 32.0).clamp(-1.0, 1.0)
          end

          def global_slide(v, tick)
            x = v >> 4
            y = v & 15
            delta = if x == 15 && y > 0 then tick == 0 ? -y : 0
                    elsif y == 15 && x > 0 then tick == 0 ? x : 0
                    elsif tick > 0 then y == 0 ? x : -y
                    else 0
                    end
            @global_volume = (@global_volume + delta / 2.0).clamp(0.0, 64.0)
          end

          def special(ch, v)
            x = v & 15
            case v >> 4
            when 6 then unsupported('S6x fine pattern delay') if x > 0
            when 7 then instrument_control(ch, x)
            when 9 then unsupported('S9x sound control') if x > 0
            when 10 then ch.memory[:high] = x
            else super
            end
          end

          def instrument_control(ch, x)
            case x
            when 0..2
              @voices.each { |vo|
                next unless vo.host == ch.index
                case x
                when 0 then vo.fade = 0
                when 1 then vo.key_on = false
                when 2 then vo.fading = true
                end
              }
            when 3..6 then ch.memory[:nna] = x - 3
            else unsupported('S77-S7C envelope switches')
            end
          end

          def tick_effect(ch, cell, t)
            ch.out_period = ch.period
            ch.out_volume = nil
            if ch.delay_note && t == (ch.delay_note.param & 15)
              cell_note(ch, ch.delay_note, nil, 0)
              volume_column(ch, ch.delay_note.volume, 0) if ch.delay_note.volume
              ch.out_period = ch.period
            end
            return if cell.nil?
            volume_column(ch, cell.volume, t) if cell.volume && ch.delay_note.nil?
            return if cell.effect.nil?
            effect_tick(ch, cell, t)
          end

          def effect_tick(ch, cell, t)
            v = ch.vol_column
            case cell.effect
            when 14 then channel_volume_slide(ch, v, t)
            when 16 then pan_slide(ch, v, t)
            when 20
              set_tempo((@tempo + (v >> 4 == 1 ? v & 15 : -(v & 15))).clamp(32, 255)) if v < 32
            when 23 then global_slide(v, t)
            else super
            end
          end

          def current_volume(ch)
            output_volume(ch)
          end

          # Envelopes, fades, and background voices move on after a tick.
          def end_tick(ch, _t)
            return unless ch.voice
            inst = instrument_of(ch)
            ch.offset += frequency(ch, ch.out_period || ch.period) * Player.tick_seconds(@tempo) if ch.period
            if inst
              ch.env_tick = envelope_next(inst.volume_envelope, ch.env_tick, ch.key_on)
              ch.memory[:pan_tick] = envelope_next(inst.pan_envelope, ch.memory[:pan_tick], ch.key_on)
              ch.memory[:pitch_tick] = envelope_next(inst.pitch_envelope, ch.memory[:pitch_tick], ch.key_on)
              ch.memory[:fading] = true if !ch.key_on && envelope_done?(inst.volume_envelope, ch.env_tick, ch.key_on)
            end
            ch.fade = [ch.fade - (inst&.fadeout || 0), 0].max if ch.memory[:fading]
            cut(ch) if ch.memory[:fading] && ch.fade <= 0
            smp = ch.sample && @song.samples[ch.sample]
            cut(ch) if smp && !smp.loop && !smp.sustain_loop && ch.offset >= smp.length
          end

          # The pitch envelope, before each tick is recorded.
          def before_record(ch, _t)
            return unless ch.voice && ch.out_period
            env = instrument_of(ch)&.pitch_envelope
            return unless env&.enabled && !env.filter
            semis = envelope_value(env, ch.memory[:pitch_tick]) / 2.0
            ch.out_period = @linear ? ch.out_period - semis * 64 : ch.out_period * 2**(-semis / 12.0)
          end

          def record_tick
            super
            record_voices
          end

          def record_voices
            @voices.each { |v| record_voice(v) }
            @voices.reject! { |v| v.fade <= 0 }
            @voices.each { |v| advance_voice(v) }
            @voices.reject! { |v| v.fade <= 0 }
          end

          def record_voice(v)
            log = v.log
            pad(log)
            inst = instrument_of(v)
            period = v.period
            if (env = inst&.pitch_envelope) && env.enabled && !env.filter
              semis = envelope_value(env, v.pitch_tick) / 2.0
              period = @linear ? period - semis * 64 : period * 2**(-semis / 12.0)
            end
            log.freq[@tick] = frequency(v, period)
            log.volume[@tick] = voice_volume(v, v.volume, v.env_tick, v.fade, v.channel_volume)
            log.pan[@tick] = voice_pan(v, v.pan, v.pan_tick)
          end

          def advance_voice(v)
            inst = instrument_of(v)
            v.position += frequency(v, v.period) * Player.tick_seconds(@tempo)
            if inst
              v.env_tick = envelope_next(inst.volume_envelope, v.env_tick, v.key_on)
              v.pan_tick = envelope_next(inst.pan_envelope, v.pan_tick, v.key_on)
              v.pitch_tick = envelope_next(inst.pitch_envelope, v.pitch_tick, v.key_on)
              env = inst.volume_envelope
              v.fading = true if !v.key_on && (env.nil? || !env.enabled || env.loop || envelope_done?(env, v.env_tick, false))
              v.fade = 0 if env&.enabled && envelope_done?(env, v.env_tick, false) && envelope_value(env, v.env_tick) <= 0
            end
            v.fade = [v.fade - (inst&.fadeout || 0), 0].max if v.fading
            smp = @song.samples[v.sample]
            v.fade = 0 if smp && !smp.loop && !smp.sustain_loop && v.position >= smp.length
          end

          def voice_volume(x, volume, env_tick, fade, channel_volume)
            smp = @song.samples[x.sample]
            inst = instrument_of(x)
            v = volume.to_f.clamp(0, 64) / 64.0 * (smp ? smp.global_volume / 64.0 : 1.0) * (inst ? inst.global_volume / 128.0 : 1.0)
            env = inst && envelope_value(inst.volume_envelope, env_tick)
            v *= env / 64.0 if env
            v * fade.to_f / FADE * channel_volume / 64.0 * @global_volume / 64.0
          end

          def voice_pan(x, pan, tick)
            p = pan.to_f.clamp(-1.0, 1.0)
            inst = instrument_of(x)
            env = inst && envelope_value(inst.pan_envelope, tick)
            env ? (p + env / 32.0 * (1 - p.abs)).clamp(-1.0, 1.0) : p
          end

          def output_volume(ch)
            voice_volume(ch, ch.out_volume || ch.volume, ch.env_tick, ch.fade, ch.channel_volume)
          end

          def output_pan(ch)
            voice_pan(ch, ch.pan, ch.memory[:pan_tick])
          end
        end
      end
    end
  end
end

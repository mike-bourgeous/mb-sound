module MB
  module Sound
    module SQ80
      # The SQ-80-flavored playable voice (first built as
      # bin/synths/sq80_voice.rb, 2026-10-07; a library patch since
      # sq80-lib-1, 2026-10-17) made from the library's general pieces:
      # three wavetable oscillators (OSC1-3) into the four-pole lowpass
      # (lp4) with drive, a four-segment SQ-80 envelope on the VCA (ENV4),
      # ENV1 blipping OSC3, ENV2 on the filter, a delayed vibrato LFO, and
      # two oddities: a per-key poly pressure flutter and a looping chop
      # envelope.  Console: MB::Sound.sq80 (SQ80Methods); named settings in
      # SQ80.presets.
      #
      # Settings (see DEFAULTS; Hash settings merge into the defaults, so
      # `env4: { t4: 50 }` changes only T4):
      #
      # +voices+ - Voices (1..16).
      # +cutoff+ - Filter cutoff in Hz before modulation (a number or node).
      # +reso+ - lp4 resonance 0..1 at CC 71's center (a number or node).
      # +drive_mode+ - :feedback (soft-clipped resonance) or :input.
      # +drive+ - lp4 drive amount (a number or node).
      # +chop+ - Depth in octaves of a looping envelope (two 32nd-note
      #          segments, repeating while a key is held) on the cutoff
      #          (0: off; a number or node).
      # +flutter+ - Depth in octaves per unit of poly pressure of a
      #             sample-and-hold LFO on the cutoff whose rate follows
      #             the key's poly pressure (0: off; a number or node).
      # +second_release+ - The SQ-80's second release on ENV4 (a pseudo
      #                    reverb tail).
      # +osc1+..+osc3+ - { wave:, semitones:, level:, vibrato:, env1: }:
      #                  the wave (Waves.[]: :formant, :synth3, :prime, or a
      #                  library table name), the tuning in semitones,
      #                  the mix level (linear), whether LFO1 vibrato moves
      #                  it, and whether ENV1 sets its level.
      # +env1+, +env2+, +env4+ - SQ80.env_options panel values (0..63
      #                          times, -63..+63 levels, lv, t1v, tk, ...).
      # +lfo1+ - { rate:, depth:, delay:, wheel:, pressure: }: the vibrato
      #          triangle (Hz, semitones, seconds, and the mod wheel's and
      #          aftertouch's extra depth in semitones).
      # +filter+ - { env2:, key:, velocity:, aftertouch: }: cutoff
      #            modulation in octaves (key: octaves per octave from C4).
      # +transpose+ - Semitones added to every oscillator (-24 plays two
      #               octaves down; the filter's key tracking still follows
      #               the keys played).
      # +level+ - Output gain (linear).
      module Voice
        # The defaults: the sound of bin/synths/sq80_voice.rb.
        DEFAULTS = {
          voices: 8,
          cutoff: 500,
          reso: 0.4,
          drive_mode: :feedback,
          drive: 1.5,
          chop: 1.5,
          flutter: 1.0,
          second_release: false,
          osc1: { wave: :formant, semitones: 0, level: 0.45, vibrato: true, env1: false },
          osc2: { wave: :synth3, semitones: 0.06, level: 0.35, vibrato: true, env1: false },
          osc3: { wave: :prime, semitones: -12, level: 0.4, vibrato: false, env1: true },
          # ENV1 blips OSC3 (CYC: every stage runs, even for a short key-up;
          # restart: each note's blip starts from zero)
          env1: { l1: 63, l2: 18, l3: 0, t1: 0, t2: 14, t3: 20, t4: 16, lv: 30, cycle: true, restart: true },
          # ENV2: the filter; velocity on levels and attack, higher keys decay faster
          env2: { l1: 63, l2: 36, l3: 24, t1: 4, t2: 28, t3: 38, t4: 30, lv: 24, t1v: 30, tk: 24 },
          # ENV4: the VCA, exponential velocity on its levels (LV "X")
          env4: { l1: 63, l2: 54, l3: 46, t1: 2, t2: 30, t3: 42, t4: 32, lv: 36, lv_curve: :exp },
          lfo1: { rate: 5.2, depth: 0.06, delay: 0.4, wheel: 0.35, pressure: 0.2 },
          filter: { env2: 3, key: 0.5, velocity: 0.5, aftertouch: 1.5 },
          transpose: 0,
          level: 1.6,
        }.freeze

        # Settings whose values are Hashes merged into the defaults'.
        NESTED = DEFAULTS.select { |_k, v| v.is_a?(Hash) }.keys.freeze

        # Keys each nested setting takes (env1/env2/env4 take any
        # SQ80.env_options panel keyword).
        NESTED_KEYS = {
          osc: %i[wave semitones level vibrato env1],
          lfo1: %i[rate depth delay wheel pressure],
          filter: %i[env2 key velocity aftertouch],
        }.freeze

        module_function

        # Returns settings Hash +base+ with +changes+ merged in, nested
        # Hashes (osc1, env4, ...) key by key (a patch's settings changed by
        # the caller's).
        def merge(base, changes)
          base.merge(changes) { |_k, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) : b }
        end

        # Returns DEFAULTS with +settings+ merged in (nested Hashes merged
        # key by key), checking the names (ArgumentError with suggestions).
        def settings(**settings)
          settings.each_key do |k|
            next if DEFAULTS.key?(k)
            raise ArgumentError, "Unknown SQ-80 setting #{k.inspect}#{GraphIO.suggest(k, DEFAULTS.keys)}"
          end

          DEFAULTS.merge(settings) { |k, default, given|
            next given unless NESTED.include?(k)
            raise ArgumentError, "SQ-80 setting #{k.inspect} takes a Hash (got #{given.inspect})" unless given.is_a?(Hash)

            allowed = NESTED_KEYS[k.start_with?('osc') ? :osc : k]
            given.each_key do |nk|
              next if allowed.nil? || allowed.include?(nk)
              raise ArgumentError, "Unknown SQ-80 #{k} setting #{nk.inspect}#{GraphIO.suggest(nk, allowed)}"
            end
            default.merge(given)
          }
        end

        # The voice's Synth graph for MIDI +source+ (a Notes, Clip,
        # filename, or other source; see MidiMethods#synth) with +settings+
        # (see the module description).  +seed+ seeds the voices' random
        # parts (the flutter).
        def build(source, seed: nil, **settings)
          s = self.settings(**settings)
          o1, o2, o3 = s[:osc1], s[:osc2], s[:osc3]
          tables = [o1, o2, o3].map { |o| Waves[o[:wave]] }
          cutoff, reso, drive, chop, flutter = s.values_at(:cutoff, :reso, :drive, :chop, :flutter)
          drive_mode = s[:drive_mode].to_sym
          raise ArgumentError, "SQ-80 drive_mode is :feedback or :input (got #{s[:drive_mode].inspect})" unless [:feedback, :input].include?(drive_mode)

          raise ArgumentError, 'Give at least one SQ-80 oscillator a level' if [o1, o2, o3].all? { |o| zero?(o[:level]) }

          lfo1 = s[:lfo1]
          filter = s[:filter]
          second_release = s[:second_release]
          synth_options = { voices: s[:voices] }
          synth_options[:seed] = seed unless seed.nil?

          MB::Sound.synth(source, **synth_options) { |v|
            # LFO1: delayed vibrato (semitones), deeper with the wheel and aftertouch
            vibrato = v.lfo(lfo1[:rate], shape: :tri, depth: lfo1[:depth], delay: lfo1[:delay], wheel: lfo1[:wheel], pressure: lfo1[:pressure])

            # OSC1-3 (pitched tables; levels and ENV1 applied in the mix below)
            transpose = s[:transpose]
            raise ArgumentError, "SQ-80 transpose is a number of semitones (got #{transpose.inspect})" unless transpose.is_a?(Numeric)
            oscs = [o1, o2, o3].zip(tables).map { |o, table| zero?(o[:level]) ? nil : osc(v, o, table, vibrato, transpose) }

            # GM2 envelope time knobs (CC 72/73/75) act on ENV4 only (cheaper)
            env1 = [o1, o2, o3].any? { |o| o[:env1] && !zero?(o[:level]) } ? v.sq80_env(**s[:env1], gm: false) : nil

            env2 = v.sq80_env(**s[:env2], gm: false)

            mods = {}
            mods[env2] = filter[:env2] unless zero?(filter[:env2])
            mods[:key] = filter[:key] unless zero?(filter[:key])
            mods[:velocity] = filter[:velocity] unless zero?(filter[:velocity])
            mods[:aftertouch] = filter[:aftertouch] unless zero?(filter[:aftertouch])

            # Oddity 1: each finger's pressure sets its own S&H flutter rate and depth
            mods[flutter_lfo(v)] = v.poly_pressure * (flutter.is_a?(Numeric) ? flutter.to_f : flutter) unless zero?(flutter)

            # Oddity 2: a looping envelope chops the filter in 16ths while held
            unless zero?(chop)
              chopper = v.env([[1, 1.n32, 24], [0, 1.n32, -12], [0, 0.15]], release_at: 2, loop: 0, curve: :linear, sensitivity: 0, gm: false)
              mods[chopper] = chop.is_a?(Numeric) ? chop.to_f.oct : chop
            end

            cut = v.mod_scale(cutoff, mods) * v.brightness
            drive_opts = drive_mode == :input ? { drive: drive, drive_mode: :input } : { drive: drive, drive_mode: :feedback, clip: :soft }

            env4 = v.sq80_env(**s[:env4], second_release: second_release)

            mix = [o1, o2, o3].zip(oscs).filter_map { |o, sig|
              next unless sig
              sig = sig * env1 if o[:env1]
              sig * o[:level]
            }.reduce(:+)

            mix.lp4(cut.clip(20, 18000), resonance: v.reso(reso), **drive_opts) * env4
          } * s[:level]
        end

        # The cutoff of the S&H flutter's glide (see .flutter_lfo).
        FLUTTER_GLIDE_HZ = 12

        # The flutter LFO of voice +v+ (a Notes): random steps whose rate
        # follows the key's poly pressure (2.5 Hz, up to 2.5 octaves faster
        # at full pressure), gliding from step to step through a critically
        # damped lowpass at FLUTTER_GLIDE_HZ (no overshoot; about 13 ms time
        # constant), since jumps of up to 2.5 octaves on a resonant cutoff
        # zippered (omnibus9, the maintainer's sq80-lib-1 Bench note on
        # :flutter_pad, 2026-10-17: "seems like it's still not
        # interpolating").  Its range stays -1..1.
        def flutter_lfo(v)
          v.lfo(v.mod_scale(2.5, :poly_pressure => 2.5.oct), shape: :noise)
            .filter(:lowpass, cutoff: FLUTTER_GLIDE_HZ, quality: 0.5)
        end

        # One oscillator: +table+ at the voice's pitch (+o+'s semitones and
        # +transpose+, plus +vibrato+ if o[:vibrato]).
        def osc(v, o, table, vibrato, transpose = 0)
          semis = o[:semitones]
          semis += transpose unless zero?(transpose)
          pitch = if o[:vibrato]
            zero?(semis) ? v.hz.transpose(vibrato) : v.hz.transpose(v.mod_sum(semis, vibrato => 1))
          else
            zero?(semis) ? v.hz : v.hz.transpose(semis)
          end

          pitch.wavetable(table)
        end

        # True if +x+ is the number 0 (nodes never are).
        def zero?(x)
          x.is_a?(Numeric) && x == 0
        end
        private_class_method :osc, :zero?
      end
    end
  end
end

module MB
  module Sound
    module SQ80
      # A named setting of SQ80::Voice: +name+ (a Symbol), +description+,
      # and +settings+ (Voice settings over Voice::DEFAULTS).
      Patch = Data.define(:name, :description, :settings) do
        # The full Voice settings (defaults merged).
        def full_settings
          Voice.settings(**settings)
        end

        # The Ruby that builds this patch on live MIDI.
        def to_ruby
          "sq80(#{name.inspect})"
        end
      end

      # The library's SQ-80 voice patches (sq80-lib-1, 2026-10-17), as data:
      # `sq80(:flutter_pad)` plays one on live MIDI, `sq80(clip,
      # :flutter_pad, cutoff: 900)` on a clip with a setting changed.
      # Levels are matched by loudness on a short chord phrase (within
      # about 1 LU of :classic).  Each is also a graph document in presets/
      # (preset :sq80_flutter_pad, midi: midi; bin/save_presets.rb).
      PATCHES = [
        Patch.new(
          :classic,
          'The voice as first built (bin/synths/sq80_voice.rb), two octaves down: a formant wave, a SYNTH 3-style wave a few cents up, and a blipped PRIME an octave below them into a driven four-pole; 32nd-note filter chop and poly pressure flutter.',
          { transpose: -24, level: 2.81 }
        ),
        Patch.new(
          :flutter_pad,
          'A slow pad: no chop, deep per-key pressure flutter (press one finger harder than the others), a long second-release tail.',
          {
            cutoff: 650, reso: 0.3, chop: 0, flutter: 2.5, second_release: true,
            osc3: { level: 0.25, env1: false },
            env2: { t1: 30, t2: 40, l2: 44, l3: 36, t1v: 0 },
            env4: { t1: 30, t2: 40, l2: 60, l3: 54, t4: 40 },
            lfo1: { depth: 0.08 },
            level: 1.41,
          }
        ),
        Patch.new(
          :chop,
          'Rhythm from the chop envelope: a dark, resonant filter opened in 32nd notes while keys are held, restarting with each note, so chords stagger.',
          {
            transpose: -12, cutoff: 260, reso: 0.65, chop: 3.0, flutter: 0,
            env2: { l2: 20, l3: 10 },
            env4: { l3: 58, t4: 20 },
            level: 1.39,
          }
        ),
        Patch.new(
          :vox_lead,
          'A vowel lead: the formant wave up front with a slightly flat SYNTH 3, input drive, deeper delayed vibrato.',
          {
            voices: 4, cutoff: 1400, reso: 0.25, drive_mode: :input, drive: 2.5, chop: 0, flutter: 0.5,
            osc1: { level: 0.7 }, osc2: { semitones: -0.08, level: 0.3 }, osc3: { level: 0 },
            lfo1: { depth: 0.12, delay: 0.25 },
            env4: { t1: 6, l2: 58, l3: 52, t4: 24 },
            level: 2.01,
          }
        ),
        Patch.new(
          :prime_bass,
          'A bass: PRIME an octave down and SYNTH 3 without vibrato, input drive, a snappy filter envelope that velocity opens.',
          {
            voices: 2, transpose: 12, cutoff: 220, reso: 0.5, drive_mode: :input, drive: 3.0, chop: 0, flutter: 0,
            osc1: { level: 0.15 }, osc2: { semitones: 0.04, level: 0.4, vibrato: false }, osc3: { level: 0.55, env1: false },
            env2: { t1: 0, t1v: 0, l2: 20, l3: 6, t2: 18, t3: 24 },
            filter: { env2: 3.5, velocity: 1.0 },
            env4: { t1: 0, l2: 58, l3: 50, t4: 12 },
            lfo1: { depth: 0 },
            level: 5.52,
          }
        ),
        Patch.new(
          :glass,
          'Glassy keys: SYNTH 3 an octave up over a little formant and the PRIME blip, decaying to nothing with a second-release tail.',
          {
            cutoff: 1800, reso: 0.2, chop: 0, flutter: 1.5, second_release: true,
            osc1: { level: 0.15 }, osc2: { semitones: 12, level: 0.45 },
            env1: { t2: 20, t3: 30 },
            env4: { t1: 0, l2: 40, t2: 34, l3: 0, t3: 44, t4: 36 },
            level: 2.39,
          }
        ),
      ].to_h { |p| [p.name, p] }.freeze

      # The patch named +name+ (a Patch), or an ArgumentError with
      # suggestions.
      def self.patch(name)
        PATCHES.fetch(name.to_sym) {
          raise ArgumentError, "No SQ-80 patch #{name.inspect}#{GraphIO.suggest(name.to_sym, PATCHES.keys)}"
        }
      end

      # The names of the library's SQ-80 patches.
      def self.patch_names
        PATCHES.keys
      end
    end
  end
end

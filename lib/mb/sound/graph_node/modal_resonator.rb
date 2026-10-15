module MB
  module Sound
    module GraphNode
      # A bank of struck resonators sharing one input (modal synthesis):
      # every impulse of the input rings each mode of a struck object, a
      # decaying sine at the frequency times the mode's ratio (plus an offset
      # in Hz for doublets that beat), with the mode's amplitude, falling 60
      # dB in the decay times the mode's decay share.  Like Resonator (one
      # mode; see there for the complex one-pole that lets the frequency and
      # decay move every sample without changing the ringing level), but all
      # modes in one C loop (MB::Sound::FastResonator.modes, exact Ruby mirror
      # .process_ruby).  Modes above 0.45 of the sample rate are silent, so
      # high notes lose their top modes instead of aliasing.
      #
      # Usually made by SynthesisMethods#resonate from a named preset
      # (ModalResonator::PRESETS: :bowl, :rin, :gong, :bell, :chime,
      # :tubular, :bar, :marimba, :vibes, :glass, :plate, :membrane), or
      # from a mode list.  #resonate adds the presets' pitch glides (a node
      # moving the frequency) and bloom twins (see .expand).
      #
      # When the input ends the bank rings out, then ends once its ringing has
      # fallen below -120 dB (see Resonator#sample).
      class ModalResonator < Resonator
        # A named set of modes (see PRESETS).  +modes+: [ratio, amplitude,
        # decay share, beat multiple, bloom share] for each mode; a mode with
        # a beat multiple gets a partner at +beat+ times it Hz higher, at
        # PARTNER_AMP of its amplitude and PARTNER_DECAY of its decay (a
        # doublet: two nearly equal modes of a slightly uneven object, which
        # beat); a mode with a bloom share swells in instead of starting at
        # full level (see .expand).  +decay+: seconds to -60 dB for a decay
        # share of 1.  +pitch+: a typical frequency in Hz for the object
        # (used when #resonate gets none).  +glide+: semitones the pitch
        # starts above where it settles for a strike of 1, falling back over
        # +glide_time+ seconds (to -60 dB) as the vibration calms (a gong's
        # or drum's tension glide); 0 for none.  +about+: what it is and
        # where the numbers come from.
        Preset = Struct.new(:modes, :decay, :beat, :pitch, :glide, :glide_time, :about, keyword_init: true) do
          def initialize(glide: 0, glide_time: 1.0, **kw)
            super
          end
        end

        # A doublet partner's share of its mode's amplitude.
        PARTNER_AMP = 0.7

        # A doublet partner's share of its mode's decay.
        PARTNER_DECAY = 0.8

        # Values per mode in the kernel's table.
        FIELDS = 4

        # The kernel's limit on modes (doublet partners count).
        MAX_MODES = 128

        # Modes at or above this share of the sample rate are silent.
        CEILING = 0.45

        # Mode ratios are from the physics of each object (ideal shapes, or
        # measurements where real objects differ); amplitudes and decay
        # shares are chosen by ear within what the physics suggests (higher
        # modes quieter and shorter).
        PRESETS = {
          bowl: Preset.new(
            modes: [[1.0, 1.0, 1.0, 1.0], [2.77, 0.45, 0.46, 2**1.3], [5.15, 0.22, 0.25, 3**1.3], [8.1, 0.1, 0.15, 4**1.3]],
            decay: 24, beat: 0.7, pitch: 220,
            about: 'a singing bowl: the (2,0)..(5,0) shell modes at measured bowl ratios (1 : 2.77 : 5.15 : 8.1), ' \
                   'each a beating doublet, wider above (bin/synths/ambient.rb\'s bowl)'
          ),
          rin: Preset.new(
            modes: [[1.0, 1.0, 1.0, 1.0], [2.77, 0.45, 0.46, 2**1.3], [5.15, 0.22, 0.25, 3**1.3], [8.1, 0.1, 0.15, 4**1.3]],
            decay: 24, beat: 1.6, pitch: 880,
            about: 'a rin (small temple bowl): the bowl\'s modes with faster beating'
          ),
          gong: Preset.new(
            modes: [
              [1.0, 1.0, 1.0, 1.0], [1.73, 0.8, 0.85, nil], [2.33, 0.7, 0.75, 1.0], [3.91, 0.5, 0.9, nil, 0.12],
              [4.11, 0.5, 0.9, 1.0, 0.15], [6.3, 0.45, 1.05, nil, 0.21], [6.71, 0.42, 1.05, 1.0, 0.24], [7.34, 0.4, 1.12, nil, 0.3],
              [8.95, 0.36, 1.2, nil, 0.36], [11.1, 0.32, 1.2, nil, 0.42], [12.73, 0.28, 1.2, nil, 0.48], [14.6, 0.26, 1.2, nil, 0.54],
              [16.84, 0.24, 1.2, nil, 0.6], [19.3, 0.2, 1.2, nil, 0.66],
            ],
            decay: 14, beat: 0.35, pitch: 110, glide: 0.8, glide_time: 2.5,
            about: 'a tam-tam: a free circular plate\'s modes (2,0) (0,1) (3,0) (1,1) (4,0) (5,0) (2,1) (0,2) (6,0) (7,0) ' \
                   '(Rossing) and a denser inharmonic cluster above; the pitch starts 0.8 semitones high and settles as ' \
                   'the plate calms, and the upper modes bloom in over a second or two as the energy cascades upward'
          ),
          bell: Preset.new(
            modes: [
              [0.5, 0.5, 1.0, 1.0], [1.0, 0.6, 0.65, 1.0], [1.2, 0.55, 0.5, 1.0], [1.5, 0.25, 0.25, nil],
              [2.0, 1.0, 0.35, 1.5], [2.5, 0.35, 0.2, nil], [2.67, 0.3, 0.18, nil], [3.0, 0.3, 0.16, nil],
              [4.0, 0.25, 0.12, nil], [5.33, 0.12, 0.08, nil],
            ],
            decay: 14, beat: 0.6, pitch: 262,
            about: 'a church bell (minor-third tuning), the prime on the note: hum 0.5, prime 1, tierce 1.2 (a minor third), ' \
                   'quint 1.5, nominal 2 (loudest at the strike), then the major tenth, eleventh, twelfth, double ' \
                   'octave, and upper fourth; the hum rings longest, the upper partials fade fast, and the nominal, twelfth, and ' \
                   'double octave (2 : 3 : 4) put the strike note on the prime'
          ),
          chime: Preset.new(
            modes: [[1.0, 0.8, 1.0, 1.0], [2.756, 1.0, 0.75, 1.0], [5.404, 0.45, 0.5, nil], [8.933, 0.22, 0.35, nil], [13.34, 0.1, 0.25, nil]],
            decay: 7, beat: 0.15, pitch: 880,
            about: 'a wind chime: an aluminum tube hanging free, whose bending modes follow the free-free beam ' \
                   '(1 : 2.756 : 5.404 : 8.933 : 13.34); the fundamental and the bright second mode ring long, with a slight beat'
          ),
          tubular: Preset.new(
            modes: [[0.617, 0.15, 1.0, nil], [1.21, 0.4, 1.0, nil], [2.0, 1.0, 0.8, nil], [2.988, 0.8, 0.6, nil], [4.173, 0.5, 0.4, nil], [5.556, 0.25, 0.3, nil]],
            decay: 6, beat: 0, pitch: 440,
            about: 'an orchestral tubular bell: a free tube\'s bending modes, (2n+1)^2 for n = 2..7; modes 4-6 sit near 2 : 3 : 4, ' \
                   'so the ear hears a pitch an octave below mode 4 (ratio 1, which no mode plays); bell-like (:chime until textures-2)'
          ),
          bar: Preset.new(
            modes: [[1.0, 1.0, 1.0, nil], [2.756, 0.5, 0.5, nil], [5.404, 0.25, 0.3, nil], [8.933, 0.12, 0.2, nil], [13.34, 0.06, 0.12, nil]],
            decay: 3, beat: 0, pitch: 1760,
            about: 'an untuned metal bar (free-free beam): 1 : 2.756 : 5.404 : 8.933 : 13.34, a glockenspiel without tuning cuts'
          ),
          marimba: Preset.new(
            modes: [[1.0, 1.0, 1.0, nil], [3.99, 0.35, 0.35, nil], [9.14, 0.12, 0.15, nil]],
            decay: 1.2, beat: 0, pitch: 440,
            about: 'a marimba bar: wood cut under the middle to tune the modes to about 1 : 4 : 9.1; short, dark'
          ),
          vibes: Preset.new(
            modes: [[1.0, 1.0, 1.0, nil], [4.0, 0.3, 0.45, nil], [10.0, 0.08, 0.2, nil]],
            decay: 6, beat: 0, pitch: 440,
            about: 'a vibraphone bar: aluminum tuned to 1 : 4 : 10, ringing long (add a tremolo with .at(5.hz.lfo.at(0.6..1)))'
          ),
          glass: Preset.new(
            modes: [[1.0, 1.0, 1.0, 1.0], [2.32, 0.3, 0.5, 1.5], [4.25, 0.12, 0.3, 2.0], [6.63, 0.05, 0.2, nil]],
            decay: 8, beat: 0.4, pitch: 660,
            about: 'a wine glass: the rim\'s (2,0)..(5,0) modes at measured ratios 1 : 2.32 : 4.25 : 6.63 (Rossing), ' \
                   'slightly uneven glass splitting them into slow beats; real wine glasses ring at about 400-1000 Hz ' \
                   '(G4-B5), so lower notes are giants\' glasses'
          ),
          plate: Preset.new(
            modes: [
              [1.0, 1.0, 1.0, nil], [2.014, 0.7, 0.75, nil], [2.987, 0.58, 0.6, nil], [3.703, 0.52, 0.55, nil],
              [4.0, 0.5, 0.5, nil], [5.69, 0.42, 0.42, nil], [6.07, 0.4, 0.4, nil], [6.3, 0.4, 0.4, nil],
              [7.31, 0.37, 0.37, nil], [8.05, 0.35, 0.35, nil], [9.0, 0.33, 0.33, nil], [9.11, 0.33, 0.33, nil],
            ],
            decay: 5, beat: 0, pitch: 200,
            about: 'a sheet of metal (a thin rectangular plate, sides 1 : 1.4, edges held): modes m^2 + (n / 1.4)^2, ' \
                   'dense and clangy; the plate reverb\'s raw material'
          ),
          membrane: Preset.new(
            modes: [
              [1.0, 1.0, 1.0, nil], [1.594, 0.7, 0.7, nil], [2.136, 0.5, 0.55, nil], [2.296, 0.45, 0.5, nil],
              [2.653, 0.35, 0.45, nil], [2.918, 0.3, 0.4, nil], [3.156, 0.25, 0.35, nil], [3.501, 0.2, 0.3, nil],
            ],
            decay: 0.5, beat: 0, pitch: 100,
            about: 'a drum head (an ideal circular membrane): Bessel-function zeros 1 : 1.594 : 2.136 : 2.296 : 2.653 ...; ' \
                   'short, tom-like'
          ),
        }.freeze

        # Preset names (and aliases) for error messages and help.
        ALIASES = { singing_bowl: :bowl, tam_tam: :gong, tamtam: :gong, wine_glass: :glass, tube: :chime, wind_chime: :chime,
                    tubular_bell: :tubular, tubular_bells: :tubular, church_bell: :bell,
                    glockenspiel: :bar, vibraphone: :vibes, sheet: :plate, plate_metal: :plate, drum: :membrane }.freeze

        # Returns the Preset named +name+ (a PRESETS key or ALIASES name),
        # raising with suggestions otherwise.
        def self.preset(name)
          key = ALIASES.fetch(name, name)
          PRESETS.fetch(key) {
            names = PRESETS.keys + ALIASES.keys
            hint = DidYouMean::SpellChecker.new(dictionary: names).correct(name).first
            raise ArgumentError, "Unknown resonator preset #{name.inspect}#{hint ? " (did you mean #{hint.inspect}?)" : ''}; " \
                                 "presets are #{PRESETS.keys.map(&:inspect).join(', ')}"
          }
        end

        # Expands mode lists into kernel rows [ratio, offset Hz, amplitude,
        # decay share] (Floats), adding doublet partners at +beat+ Hz times
        # each mode's beat multiple (none when +beat+ is 0).  +modes+ are
        # [ratio, amplitude, decay share, beat multiple, bloom share] (the
        # last three optional: 1, none, none).
        #
        # A bloom share b makes the mode (and its partner) swell in: each
        # gets a twin row of the opposite amplitude falling 60 dB in b times
        # the decay, so a strike rings A (e^(-t/T) - e^(-t/Tb)), starting
        # from silence and peaking after about Tb ln(T / Tb) (the energy of
        # a gong cascading into its upper modes).  The twins come right
        # after their rows.
        def self.expand(modes, beat, bloom: true)
          expand_groups(modes, beat, bloom: bloom).flatten(1)
        end

        # Like .expand, but each mode's rows (the mode, its partner, and
        # their bloom twins) as one Array, for keeping a mode on one side
        # of a stereo bank.
        def self.expand_groups(modes, beat, bloom: true)
          raise ArgumentError, "Modes must be a non-empty Array of [ratio, amplitude, decay share, beat] (got #{modes.inspect})" unless modes.is_a?(Array) && !modes.empty?
          raise ArgumentError, "Resonator beat must be a number of Hz (got #{beat.inspect})" unless beat.is_a?(Numeric) && beat.real?

          count = 0
          groups = modes.map do |m|
            m = Array(m)
            ratio, amp, share, mult, rise = m
            unless m.length <= 5 && [ratio, amp].all? { |v| v.is_a?(Numeric) && v.real? } && [share, mult, rise].all? { |v| v.nil? || (v.is_a?(Numeric) && v.real?) }
              raise ArgumentError, "Each mode must be [ratio, amplitude, decay share, beat multiple, bloom share] numbers (got #{m.inspect})"
            end
            raise ArgumentError, "A mode's bloom share must be above 0 (got #{rise})" if rise && rise <= 0
            share = (share || 1.0).to_f
            rows = [[ratio.to_f, 0.0, amp.to_f, share]]
            rows << [ratio.to_f, beat.to_f * mult, amp.to_f * PARTNER_AMP, share * PARTNER_DECAY] if mult && beat != 0
            rows = rows.flat_map { |r| [r, [r[0], r[1], -r[2], rise.to_f]] } if rise && bloom
            count += rows.length
            rows
          end
          raise ArgumentError, "At most #{MAX_MODES} modes, doublet partners and bloom twins included (got #{count})" if count > MAX_MODES
          groups
        end

        # The kernel rows (see .expand), each [ratio, offset, amplitude,
        # decay share].
        attr_reader :mode_rows

        # Creates a modal bank pinged by +input+ at +freq+ (Hz: a number,
        # node, or Pitch) with kernel rows +modes+ (see .expand) and +decay+
        # (seconds to -60 dB for a decay share of 1: a number, Length,
        # Duration, or node).  +gain+ scales every amplitude.
        def initialize(input, freq:, modes:, decay:, gain: 1.0, sample_rate: nil)
          super(input, freq: freq, decay: decay, phase: 0, sample_rate: sample_rate)
          @mode_rows = modes.map { |r| r.map(&:to_f) }.freeze
          @gain = gain.to_f
          @table = Numo::DFloat.cast(@mode_rows.map { |ratio, offset, amp, share| [ratio, offset, amp * @gain, share] }.flatten)
          @amps = @mode_rows.map { |r| (r[2] * @gain).abs }
          @state = Numo::DFloat.zeros(2 * @mode_rows.length)
          @node_type_name = 'Modal Resonator'
        end

        # The ringing's largest possible output (each mode's amplitude times
        # the size of its state, summed).
        def ringing_level
          z = @state
          sum = 0.0
          @amps.each_with_index do |a, k|
            sum += a * Math.hypot(z[2 * k], z[2 * k + 1])
          end
          sum
        end

        def to_s
          f = @freq.is_a?(Numeric) ? "#{MB::M.sigfigs(@freq, 4)} Hz" : 'node Hz'
          "Modal Resonator #{f}, #{@mode_rows.length} modes, decay #{@decay_source}"
        end

        # The exact Ruby mirror of MB::Sound::FastResonator.modes (same
        # arguments; see ext/mb/sound/fast_resonator/fast_resonator.c).
        def self.process_ruby(out, input, freq, decay, modes, state, rate)
          n = out.length
          x_in = signal_values(input, n)
          f_in = signal_values(freq, n)
          d_in = signal_values(decay, n)
          fs = rate.to_f
          raise ArgumentError, 'Sample rate must be positive' unless fs > 0

          table = modes.to_a
          m = table.length / FIELDS
          raise ArgumentError, "Modes must have #{FIELDS} values per mode" if m == 0 || table.length % FIELDS != 0
          raise ArgumentError, "State must be a contiguous Numo::DFloat of 2 values per mode" unless state.length == 2 * m

          z = state.to_a
          coef = Array.new(2 * m, 0.0)
          radius = Array.new(m, 0.0)
          last_f = last_d = nil

          n.times do |i|
            x = x_in.is_a?(Array) ? x_in[i] : x_in
            f = f_in.is_a?(Array) ? f_in[i] : f_in
            d = d_in.is_a?(Array) ? d_in[i] : d_in

            new_d = d != last_d
            if new_d
              m.times do |k|
                dk = d * table[k * FIELDS + 3]
                radius[k] = dk > 0 ? Math.exp(-LN_1000 / dk) : 0.0
              end
              last_d = d
            end

            if new_d || f != last_f
              m.times do |k|
                ratio, offset = table[k * FIELDS, 2]
                fk = f * ratio + offset
                r = radius[k]
                if fk > 0 && fk < CEILING * fs && r > 0
                  w = 2.0 * Math::PI * fk / fs
                  coef[2 * k] = r * Math.cos(w)
                  coef[2 * k + 1] = r * Math.sin(w)
                else
                  coef[2 * k] = 0.0
                  coef[2 * k + 1] = 0.0
                end
              end
              last_f = f
            end

            sum = 0.0
            m.times do |k|
              c = coef[2 * k]
              s = coef[2 * k + 1]
              zr = z[2 * k]
              zi = z[2 * k + 1]
              nr = c * zr - s * zi + x
              ni = s * zr + c * zi
              if nr.abs < FLUSH && ni.abs < FLUSH
                nr = 0.0
                ni = 0.0
              end
              z[2 * k] = nr
              z[2 * k + 1] = ni
              sum += table[k * FIELDS + 2] * ni
            end

            out[i] = sum
          end

          state[0..] = z
          out
        end

        private

        def run_kernel(out, x, f, d)
          MB::Sound::FastResonator.modes(out, x, f, d, @table, @state, @sample_rate)
        end
      end
    end
  end
end

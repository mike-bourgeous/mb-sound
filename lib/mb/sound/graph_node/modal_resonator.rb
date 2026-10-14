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
      # (ModalResonator::PRESETS: :bowl, :rin, :gong, :bell, :chime, :bar,
      # :marimba, :vibes, :glass, :plate, :membrane), or from a mode list.
      #
      # When the input ends the bank rings out, then ends once its ringing has
      # fallen below -120 dB (see Resonator#sample).
      class ModalResonator < Resonator
        # A named set of modes (see PRESETS).  +modes+: [ratio, amplitude,
        # decay share, beat multiple] for each mode; a mode with a beat
        # multiple gets a partner at +beat+ times it Hz higher, at
        # PARTNER_AMP of its amplitude and PARTNER_DECAY of its decay (a
        # doublet: two nearly equal modes of a slightly uneven object, which
        # beat).  +decay+: seconds to -60 dB for a decay share of 1.  +about+:
        # what it is and where the numbers come from.
        Preset = Struct.new(:modes, :decay, :beat, :about, keyword_init: true)

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
            decay: 24, beat: 0.7,
            about: 'a singing bowl: the (2,0)..(5,0) shell modes at measured bowl ratios (1 : 2.77 : 5.15 : 8.1), ' \
                   'each a beating doublet, wider above (bin/synths/ambient.rb\'s bowl)'
          ),
          rin: Preset.new(
            modes: [[1.0, 1.0, 1.0, 1.0], [2.77, 0.45, 0.46, 2**1.3], [5.15, 0.22, 0.25, 3**1.3], [8.1, 0.1, 0.15, 4**1.3]],
            decay: 24, beat: 1.6,
            about: 'a rin (small temple bowl): the bowl\'s modes with faster beating'
          ),
          gong: Preset.new(
            modes: [
              [1.0, 1.0, 1.0, 1.0], [1.73, 0.8, 0.85, nil], [2.33, 0.7, 0.75, 1.0], [3.91, 0.45, 0.55, nil],
              [4.11, 0.45, 0.5, 1.0], [6.3, 0.3, 0.35, nil], [6.71, 0.28, 0.32, 1.0], [7.34, 0.22, 0.3, nil],
              [8.95, 0.16, 0.22, nil], [11.1, 0.1, 0.16, nil],
            ],
            decay: 14, beat: 0.35,
            about: 'a tam-tam: a free circular plate\'s modes (2,0) (0,1) (3,0) (1,1) (4,0) (5,0) (2,1) (0,2) (6,0) (7,0) ' \
                   '(Rossing), dense and inharmonic, with slow beating'
          ),
          bell: Preset.new(
            modes: [
              [0.25, 0.4, 1.0, 1.0], [0.5, 0.5, 0.7, 1.0], [0.6, 0.45, 0.55, 1.0], [0.75, 0.2, 0.4, nil],
              [1.0, 1.0, 0.4, 1.0], [1.25, 0.35, 0.25, nil], [1.335, 0.3, 0.22, nil], [1.5, 0.25, 0.2, nil], [2.0, 0.15, 0.15, nil],
            ],
            decay: 12, beat: 0.5,
            about: 'a church bell (minor-third tuning): hum, prime, tierce, quint, nominal (the strike note, ratio 1), ' \
                   'major third, fourth, twelfth, upper octave; the hum rings longest'
          ),
          chime: Preset.new(
            modes: [[0.617, 0.15, 1.0, nil], [1.21, 0.4, 1.0, nil], [2.0, 1.0, 0.8, nil], [2.988, 0.8, 0.6, nil], [4.173, 0.5, 0.4, nil], [5.556, 0.25, 0.3, nil]],
            decay: 6, beat: 0,
            about: 'a tubular chime: a free tube\'s bending modes, (2n+1)^2 for n = 2..7; modes 4-6 sit near 2 : 3 : 4, ' \
                   'so the ear hears a pitch an octave below mode 4 (ratio 1, which no mode plays)'
          ),
          bar: Preset.new(
            modes: [[1.0, 1.0, 1.0, nil], [2.756, 0.5, 0.5, nil], [5.404, 0.25, 0.3, nil], [8.933, 0.12, 0.2, nil], [13.34, 0.06, 0.12, nil]],
            decay: 3, beat: 0,
            about: 'an untuned metal bar (free-free beam): 1 : 2.756 : 5.404 : 8.933 : 13.34, a glockenspiel without tuning cuts'
          ),
          marimba: Preset.new(
            modes: [[1.0, 1.0, 1.0, nil], [3.99, 0.35, 0.35, nil], [9.14, 0.12, 0.15, nil]],
            decay: 1.2, beat: 0,
            about: 'a marimba bar: wood cut under the middle to tune the modes to about 1 : 4 : 9.1; short, dark'
          ),
          vibes: Preset.new(
            modes: [[1.0, 1.0, 1.0, nil], [4.0, 0.3, 0.45, nil], [10.0, 0.08, 0.2, nil]],
            decay: 6, beat: 0,
            about: 'a vibraphone bar: aluminum tuned to 1 : 4 : 10, ringing long (add a tremolo with .at(5.hz.lfo.at(0.6..1)))'
          ),
          glass: Preset.new(
            modes: [[1.0, 1.0, 1.0, 1.0], [2.32, 0.3, 0.5, 1.5], [4.25, 0.12, 0.3, 2.0], [6.63, 0.05, 0.2, nil]],
            decay: 8, beat: 0.4,
            about: 'a wine glass: the rim\'s (2,0)..(5,0) modes at measured ratios 1 : 2.32 : 4.25 : 6.63 (Rossing), ' \
                   'slightly uneven glass splitting them into slow beats'
          ),
          plate: Preset.new(
            modes: [
              [1.0, 1.0, 1.0, nil], [2.014, 0.7, 0.75, nil], [2.987, 0.58, 0.6, nil], [3.703, 0.52, 0.55, nil],
              [4.0, 0.5, 0.5, nil], [5.69, 0.42, 0.42, nil], [6.07, 0.4, 0.4, nil], [6.3, 0.4, 0.4, nil],
              [7.31, 0.37, 0.37, nil], [8.05, 0.35, 0.35, nil], [9.0, 0.33, 0.33, nil], [9.11, 0.33, 0.33, nil],
            ],
            decay: 5, beat: 0,
            about: 'a sheet of metal (a thin rectangular plate, sides 1 : 1.4, edges held): modes m^2 + (n / 1.4)^2, ' \
                   'dense and clangy; the plate reverb\'s raw material'
          ),
          membrane: Preset.new(
            modes: [
              [1.0, 1.0, 1.0, nil], [1.594, 0.7, 0.7, nil], [2.136, 0.5, 0.55, nil], [2.296, 0.45, 0.5, nil],
              [2.653, 0.35, 0.45, nil], [2.918, 0.3, 0.4, nil], [3.156, 0.25, 0.35, nil], [3.501, 0.2, 0.3, nil],
            ],
            decay: 0.5, beat: 0,
            about: 'a drum head (an ideal circular membrane): Bessel-function zeros 1 : 1.594 : 2.136 : 2.296 : 2.653 ...; ' \
                   'short, tom-like'
          ),
        }.freeze

        # Preset names (and aliases) for error messages and help.
        ALIASES = { singing_bowl: :bowl, tam_tam: :gong, tamtam: :gong, wine_glass: :glass, tube: :chime,
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
        # [ratio, amplitude, decay share, beat multiple] (the last two
        # optional: 1 and none).
        def self.expand(modes, beat)
          raise ArgumentError, "Modes must be a non-empty Array of [ratio, amplitude, decay share, beat] (got #{modes.inspect})" unless modes.is_a?(Array) && !modes.empty?
          raise ArgumentError, "Resonator beat must be a number of Hz (got #{beat.inspect})" unless beat.is_a?(Numeric) && beat.real?

          rows = []
          modes.each do |m|
            m = Array(m)
            ratio, amp, share, mult = m
            unless [ratio, amp].all? { |v| v.is_a?(Numeric) && v.real? } && (share.nil? || share.is_a?(Numeric)) && (mult.nil? || mult.is_a?(Numeric))
              raise ArgumentError, "Each mode must be [ratio, amplitude, decay share, beat multiple] numbers (got #{m.inspect})"
            end
            share = (share || 1.0).to_f
            rows << [ratio.to_f, 0.0, amp.to_f, share]
            rows << [ratio.to_f, beat.to_f * mult, amp.to_f * PARTNER_AMP, share * PARTNER_DECAY] if mult && beat != 0
          end
          raise ArgumentError, "At most #{MAX_MODES} modes, doublet partners included (got #{rows.length})" if rows.length > MAX_MODES
          rows
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
          last_f = last_d = nil

          n.times do |i|
            x = x_in.is_a?(Array) ? x_in[i] : x_in
            f = f_in.is_a?(Array) ? f_in[i] : f_in
            d = d_in.is_a?(Array) ? d_in[i] : d_in

            if f != last_f || d != last_d
              m.times do |k|
                ratio, offset, _amp, share = table[k * FIELDS, FIELDS]
                fk = f * ratio + offset
                dk = d * share
                if fk > 0 && fk < CEILING * fs && dk > 0
                  w = 2.0 * Math::PI * fk / fs
                  r = Math.exp(-LN_1000 / dk)
                  coef[2 * k] = r * Math.cos(w)
                  coef[2 * k + 1] = r * Math.sin(w)
                else
                  coef[2 * k] = 0.0
                  coef[2 * k + 1] = 0.0
                end
              end
              last_f = f
              last_d = d
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

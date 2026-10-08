module MB
  module Sound
    module GraphNode
      # Methods that append filters to a graph (see MB::Sound::Filter).
      # Included in GraphNode.
      module FilterMethods
        # The filter structures #filter, #peq, and #bandpass_series build
        # cookbook responses with: :svf (MB::Sound::Filter::SVF, the
        # default; smooth when the cutoff, quality, or gain move) or :biquad
        # (MB::Sound::Filter::Cookbook, the direct form biquad graphs used
        # until 2026-10-08, which thumps when its cutoff dives quickly to low
        # values; kept for that sound, e.g. drums).
        FILTER_STRUCTURES = [:svf, :biquad].freeze

        # The default for +structure:+ (see FILTER_STRUCTURES).
        DEFAULT_FILTER_STRUCTURE = :svf

        # Applies the given filter (creating the filter if given a filter type)
        # to this sample source or sample chain.  If given a filter type, then a
        # dynamically updating filter is created where the cutoff, quality, and
        # gain are controlled by the given sample sources (e.g. numeric value,
        # tone generator, audio input, or ADSR envelope).
        #
        # Defaults to generating a low-pass filter if given a frequency in Hz.
        #
        # Filter types are the cookbook responses (:lowpass, :highpass,
        # :bandpass (0 dB peak), :bandpass_skirt (peak gain = quality),
        # :notch, :allpass, :peak, :lowshelf, :highshelf; +gain:+ is a linear
        # gain for the last three and an output gain for the bandpasses) and
        # the four-pole types (FOUR_POLE_TYPES, see #lp4).
        #
        # Cookbook responses (types, and Cookbook objects such as
        # `150.hz.highpass(quality: 4)`) run as a state-variable filter
        # (Filter::SVF) unless +structure: :biquad+ asks for the direct form
        # biquad (Filter::Cookbook) graphs used before 2026-10-08: the same
        # static response, but a cutoff that dives quickly toward 0 Hz makes
        # the biquad thump (a DC bump), which the SVF doesn't (see
        # FILTER_STRUCTURES).  With the biquad, +gain:+ must be a number.
        #
        # Example:
        #     # Simple low-pass filter at 1200Hz center frequency
        #     MB::Sound.play 500.hz.ramp.filter(1200.hz)
        #
        #     # Low-pass filter with center frequency sweeping between 500 and 1000 Hz
        #     MB::Sound.play 500.hz.ramp.filter(cutoff: 0.2.hz.at(500), quality: 4)
        #
        #     # High-pass filter controlled by envelopes
        #     MB::Sound.play 500.hz.ramp.filter(:highpass, frequency: adsr() * 1000 + 100, quality: adsr() * -5 + 6)
        #
        #     # A peaking EQ whose boost swells and fades
        #     MB::Sound.play 110.hz.ramp.filter(:peak, cutoff: 900, quality: 3, gain: 0.25.hz.lfo.at(0.25..6))
        #
        #     # The old direct form biquad (thumps on fast dives, e.g. drums)
        #     MB::Sound.play 220.hz.ramp.filter(:lowpass, cutoff: 0.5.hz.lfo.square.at(20..4000), structure: :biquad)
        #
        #     # CEM3379-style 4-pole lowpass (see #lp4); takes resonance: 0..1
        #     MB::Sound.play 110.hz.ramp.filter(:lp4, cutoff: 0.2.hz.lfo.at(300..3000), resonance: 0.47)
        #
        # TODO: support SampleWrapper inputs argument
        def filter(filter_or_type = :lowpass, cutoff: nil, quality: nil, gain: nil, resonance: nil, structure: nil, in_place: false)
          f = filter_or_type

          if FOUR_POLE_TYPES.include?(f)
            raise ArgumentError, 'Cutoff frequency must be given when creating a filter by type' if cutoff.nil?
            raise ArgumentError, "Four-pole filters take resonance: 0..1 or quality:, not gain:" if gain
            raise ArgumentError, 'Four-pole filters have no structure: option' if structure
            return lp4(cutoff, resonance: resonance, quality: quality, mode: f == :four_pole ? :lp4 : f)
          end
          raise ArgumentError, "Only four-pole filters (#{FOUR_POLE_TYPES.join(', ')}) take resonance:" if resonance

          f = f.hz if f.is_a?(Numeric)
          f = f.lowpass if f.is_a?(Tone) || f.is_a?(Pitch)

          if structure && !(f.is_a?(Symbol) || f.is_a?(MB::Sound::Filter::Cookbook))
            raise ArgumentError, "structure: applies to filter types and Cookbook filters (got #{filter_or_type.inspect})"
          end
          structure = filter_structure(structure)

          if f.respond_to?(:sample_rate)
            if f.sample_rate != self.sample_rate
              if f.respond_to?(:sample_rate=)
                f.sample_rate = self.sample_rate
              elsif f.respond_to?(:at_rate)
                f = f.at_rate(self.sample_rate)
              else
                warn "Filter #{f} sample rate is #{f.sample_rate} while node #{self} sample rate is #{self.sample_rate}"
              end
            end
          end

          case
          when f.is_a?(Symbol)
            raise 'Cutoff frequency must be given when creating a filter by type' if cutoff.nil?

            quality = quality || 0.5 ** 0.5

            if structure == :biquad
              raise ArgumentError, 'The biquad structure takes a numeric gain: (use the default SVF for gain nodes)' if gain && !gain.is_a?(Numeric)
              f = MB::Sound::Filter::Cookbook.new(filter_or_type, sample_rate, 1, quality: 1, db_gain: gain&.to_db)
              MB::Sound::Filter::SampleWrapper.new(f, self, inputs: { cutoff: cutoff, quality: quality })
            else
              raise ArgumentError, "Invalid filter type #{filter_or_type.inspect}" unless MB::Sound::Filter::SVF::FILTER_TYPE_IDS.include?(f)
              gain_node = gain.respond_to?(:sample) ? gain : nil
              f = MB::Sound::Filter::SVF.new(
                filter_or_type, sample_rate, 1, quality: 1,
                gain: gain_node ? 1.0 : gain&.to_f
              )
              inputs = { cutoff: cutoff, quality: quality }
              inputs[:gain] = gain_node if gain_node
              MB::Sound::Filter::SampleWrapper.new(f, self, inputs: inputs)
            end

          when f.is_a?(MB::Sound::Filter::Cookbook) || f.is_a?(MB::Sound::Filter::SVF)
            # TODO: Support graph node sources for filter gain
            raise 'Only specify gain when creating a new filter' if gain

            inputs = { cutoff: cutoff || f.cutoff, quality: quality || f.quality || 0.5 ** 0.5 }
            f = MB::Sound::Filter::SVF.from_cookbook(f) if f.is_a?(MB::Sound::Filter::Cookbook) && structure == :svf
            MB::Sound::Filter::SampleWrapper.new(f, self, inputs: inputs)

          when f.respond_to?(:wrap)
            if cutoff || quality || gain
              raise 'Cutoff, gain, and quality should only be specified when creating a new filter by type'
            end

            f.wrap(self, in_place: in_place)

          when f.respond_to?(:process)
            if cutoff || quality || gain
              raise 'Cutoff, gain, and quality should only be specified when creating a new filter by type'
            end

            MB::Sound::SampleWrapper.new(f, self, in_place: in_place)

          else
            raise "Unsupported filter type: #{filter_or_type.inspect}"
          end
        end

        # Filter types for #filter that make a four-pole filter (#lp4).
        FOUR_POLE_TYPES = [:four_pole, :lp4, :lp2, :bp2, :bp4, :hp2, :hp4].freeze # Filter::FourPole::MODES

        # A CEM3379-style 4-pole resonant lowpass (24 dB/octave), the filter
        # of the Ensoniq SQ-80 and many analog polysynths (see
        # MB::Sound::Filter::FourPole and GraphNode::FourPole).
        #
        # +cutoff+ is in Hz (a number, a Pitch such as `800.hz`, or a node,
        # e.g. Notes#cutoff); +resonance+ is 0..1 (a number or node).  Both
        # are read per sample, so audio-rate filter FM works.
        #
        # Like the SQ-80 it never self-oscillates by default: full resonance
        # rings strongly and keeps most of the bass (about -6 dB, from the
        # CEM3379's passband compensation; +compensation: 0+ gives the
        # classic 12 dB loss).  +self_oscillate: true+ gives the resonance
        # its own curve, like a classic emphasis knob: the filter rings more
        # and more up to 0.9, oscillates above it, and the rest of the knob
        # sets how strongly (level growing about linearly to ~0.22 peak at 1;
        # Filter::FourPole.self_oscillate_gain), with the drive's saturation
        # (+drive:+ 1 unless given) setting the level.  +drive:+
        # (nil = linear) is the saturation level (unity gain for small
        # signals, limited above about 1 / drive), and +drive_mode:+ where it
        # acts: :input (default; the cascade input), :stages (every stage,
        # OTA style), or :feedback (only the resonance feedback, MS-20
        # style; +clip: :soft+ or :hard), the last two with drive 1 unless
        # given.  +mode:+ picks another tap mix: :lp2, :bp2, :bp4, :hp2,
        # :hp4.
        #
        # +resonance_curve: :db+ (default) makes the gain at the cutoff
        # rise linearly in dB with +resonance+ (-12 dB to +33.8 dB; the peak
        # about 4.5 dB per 0.1 above 0.2); :linear is the loop gain itself
        # (round 1: +7.5 dB at 0.5; Filter::FourPole.db_resonance converts
        # its values, e.g. 0.5 -> 0.33, 0.75 -> 0.51, 0.9 -> 0.68).
        # +quality:+ (a number or node, e.g. Notes#quality) instead of
        # +resonance:+ gives the gain at the cutoff of a 2-pole filter of
        # that Q (see Filter::FourPole.quality_to_resonance).  In synth voices,
        # Notes#reso follows CC 71 (resonance) like Notes#quality.
        #
        # Examples:
        #     play 110.hz.ramp.lp4(800, resonance: 0.4)
        #     play 55.hz.ramp.lp4(0.25.hz.lfo.at(100..4000), resonance: 0.68, drive: 3)
        #     # A synth voice (v from synth_script or midi.synth)
        #     v.hz.saw.lp4(v.cutoff(300, keytrack: 1), resonance: 0.33) * v.amp_env
        #     # Resonance on CC 71, centered on 0.6
        #     v.hz.saw.lp4(v.cutoff(300), resonance: v.reso(0.6)) * v.amp_env
        #     # MS-20-style clipped resonance on the 2-pole tap
        #     play 110.hz.ramp.lp4(0.2.hz.lfo.at(200..3000), resonance: 0.9, mode: :lp2, drive_mode: :feedback, drive: 2) * 0.3
        #     # Self-oscillating sine at the cutoff
        #     play 0.constant.lp4(440, resonance: 1, self_oscillate: true)
        #     # Emphasis swept through the onset (0.9): ringing, then a growing whistle
        #     play 110.hz.ramp.at(0.3).lp4(1200, resonance: 0.1.hz.lfo.triangle.at(0.7..1), self_oscillate: true)
        def lp4(
          cutoff, resonance: nil, quality: nil, mode: :lp4, drive: nil, self_oscillate: false, compensation: nil,
          resonance_curve: :db, drive_mode: :input, clip: :soft
        )
          raise ArgumentError, 'Give lp4 resonance: or quality:, not both' if resonance && quality

          f = MB::Sound::Filter::FourPole.new(
            mode: mode, drive: drive, self_oscillate: self_oscillate, compensation: compensation,
            resonance_curve: resonance_curve, drive_mode: drive_mode, clip: clip,
            sample_rate: sample_rate
          )
          resonance = MB::Sound::GraphNode::FourPole.quality_resonance(quality, resonance_curve) if quality
          resonance ||= 0.0
          MB::Sound::GraphNode::FourPole.new(self, f, cutoff: cutoff, resonance: resonance)
        end
        alias four_pole lp4
        alias lowpass4 lp4

        # Adds a filter chain that applies parametric peaking EQ.  The +pairs+
        # parameter should be a Hash mapping a frequency in Hz (or a Tone) to a
        # linear gain, or an Array with gain and bandwith in octaves (the default
        # bandwidth is 1/3 octave).
        #
        # Example:
        #     # Reduce second harmonic (or first if you count from zero)
        #     100.hz.ramp.peq(200.hz => -6.db)
        #
        #     # Cut mids
        #     100.hz.ramp.peq(500.hz => [-10.db, 4])
        #
        # +structure:+ is :svf (default) or :biquad (see FILTER_STRUCTURES;
        # the static responses are the same).  Ruby passes a Hash without
        # braces as keywords, so +freq_pairs+ collects it.
        def peq(pairs = nil, structure: nil, **freq_pairs)
          pairs ||= freq_pairs
          structure = filter_structure(structure)
          raise "PEQ frequency/gain pairs must be a Hash from frequency to gain (got #{pairs.class})" unless pairs.is_a?(Hash)

          filters = pairs.map { |freq, gain|
            freq = freq.frequency if freq.is_a?(Tone) || freq.is_a?(Pitch)
            freq = freq.to_f

            case gain
            when Array
              gain, bandwidth = gain

            when Hash
              bandwidth = gain[:width] || 1.0 / 3.0
              gain = gain[:gain] || 1.0

            else
              bandwidth = 1.0 / 3.0
            end

            if structure == :biquad
              MB::Sound::Filter::Cookbook.new(:peak, self.sample_rate, freq, db_gain: gain.to_db, bandwidth_oct: bandwidth)
            else
              MB::Sound::Filter::SVF.new(:peak, self.sample_rate, freq, db_gain: gain.to_db, bandwidth_oct: bandwidth)
            end
          }

          # TODO: Expose PEQ parameters for MIDI control
          chain = MB::Sound::Filter::FilterChain.new(filters)

          self.filter(chain)
        end

        # Creates a harmonic series of peaking filters starting at the given
        # +fundamental_hz+, arranged in series.
        #
        # +:count+ - The number of filters to create.
        # +:ratio+ - The increment between harmonics (1.0 for integer harmonics).
        # +:gain+ - The gain of the peaking filters.
        # +:width+ - The bandwidth of the filters in octaves.
        def peq_series(fundamental_hz, count: 5, ratio: 1.0, gain: 0.db, width: 0.1, structure: nil)
          # TODO: support GraphNode inputs like in #bandpass_series
          pairs = Array.new(count) do |idx|
            g = gain.respond_to?(:call) ? gain.call(idx) : gain
            w = width.respond_to?(:call) ? width.call(idx) : width
            [fundamental_hz * (1 + ratio * idx), { gain: g, width: w }]
          end

          peq(pairs.to_h, structure: structure)
        end

        # Creates a harmonic series of bandpass filters starting at the given
        # +fundamental_hz+, arranged in parallel.
        #
        # +fundamental_hz+ - The first filter frequency (Proc, GraphNode, or Numeric).
        # +:count+ - The number of filters to create (Integer).
        # +:ratio+ - The increment between harmonics (1.0 for integer harmonics)
        #            (Proc, GraphNode, or Numeric).
        # +:gain+ - The linear gain for the bandpass filters (Proc or Numeric).
        # +:quality+ - The Q factor (higher is narrower; 0.001 octaves =>
        #              Q~=1414; 1 octave => Q~=1.414) (Proc, GraphNode, or
        #              Numeric).
        #
        # Example:
        #     # Filter pinging bell ringing
        #     play 0.5.hz.ramp.at(50).filter(:lowpass, cutoff: 1000, quality: 0.5).bandpass_series(440, quality: 1414, count: 20, ratio: 1.7).softclip(0.9)
        #
        #     # MIDI controlled
        #     play (midi.env(0.0, 0.00005, 0, 0.00005) * 100).bandpass_series(midi.frequency, quality: 500, count: 16, ratio: midi.cc(1, range: 1..4)).softclip(0.9).oversample(4)
        #
        # +structure:+ is :svf (default) or :biquad (see FILTER_STRUCTURES).
        def bandpass_series(fundamental_hz, count: 5, ratio: 1.0, quality: 14.14, gain: 0.db, structure: nil)
          filter_class = filter_structure(structure) == :biquad ? MB::Sound::Filter::Cookbook : MB::Sound::Filter::SVF
          # TODO: figure out why lower frequencies ping softer with a single impulse

          fs = MB::Sound::Filter::FilterSum.new(
            Array.new(count) do |idx|
              f_hz = fundamental_hz
              f_hz = f_hz.call(idx) if f_hz.respond_to?(:call)

              r = ratio
              r = r.call(idx) if r.respond_to?(:call)

              q = quality
              q = q.call(idx) if q.respond_to?(:call)

              g = gain
              g = g.call(idx) if g.respond_to?(:call)

              freq = f_hz * (1 + r * idx)

              if freq.respond_to?(:sample) || q.respond_to?(:sample)
                f = filter_class.new(:bandpass, self.sample_rate, 1000, quality: 1, db_gain: g.to_db)
                {
                  filter: f,
                  inputs: {
                    cutoff: freq,
                    quality: q,
                  },
                }
              else
                filter_class.new(:bandpass, self.sample_rate, freq, quality: q, db_gain: g.to_db)
              end
            end
          )

          self.filter(fs)
        end

        # Checks a +structure:+ option (nil for DEFAULT_FILTER_STRUCTURE).
        private def filter_structure(structure)
          structure ||= DEFAULT_FILTER_STRUCTURE
          unless FILTER_STRUCTURES.include?(structure)
            raise ArgumentError, "Filter structure must be one of #{FILTER_STRUCTURES.map(&:inspect).join(', ')} (got #{structure.inspect})"
          end
          structure
        end

        # Applies an IIR phase difference network to remove negative frequencies
        # and produce a Complex-valued analytic signal.
        #
        # See MB::Sound::Filter::HilbertIIR.
        def hilbert_iir(sample_rate: self.sample_rate)
          filter(MB::Sound::Filter::HilbertIIR.new(sample_rate: sample_rate))
        end

        # Adds a MB::Sound::Filter::Smoothstep filter to the chain, smoothing
        # over +length+: seconds or any length (e.g. `60.samples`, `100.ms`,
        # `1.n16` at the current tempo).
        #
        # With +reset:+ (a graph node of triggers, e.g. a note-on trigger), the
        # output jumps to the input at every nonzero sample of +reset+ instead
        # of gliding, so only changes without a reset glide (e.g. portamento
        # for legato notes only).
        #
        # With +curve:+ (an MB::Sound::Curve name such as :elastic, :bounce,
        # :back, :squiggle, a Curve, or a Proc), each change follows that
        # curve instead of the smoothstep, e.g. a springy knob.
        #
        # Examples:
        #     midi.number.smooth(0.1)
        #     120.hz.square.smooth(60.samples)
        #     clip.number.smooth(0.05, reset: clip.trigger)
        #     midi.cc(74).smooth(300.ms, curve: :elastic)   # an elastic knob
        #
        # TODO: instead of reacting to step changes in the input, use an FIR
        # filter whose step response is the smoothstep function.
        def smooth(length, reset: nil, curve: nil)
          if length.is_a?(MB::Sound::Length::Samples)
            f = MB::Sound::Filter::Smoothstep.new(sample_rate: sample_rate, samples: length.value, curve: curve)
          else
            f = MB::Sound::Filter::Smoothstep.new(sample_rate: sample_rate, seconds: MB::Sound::Length.seconds(length, sample_rate: sample_rate), curve: curve)
          end

          return filter(f) if reset.nil?

          raise ArgumentError, "Smooth reset must be a graph node of triggers (got #{reset.inspect})" unless reset.respond_to?(:sample)

          MB::Sound::Filter::SampleWrapper.new(f, self, inputs: { reset: reset })
        end

        # Hard-clips the slope of the output of this node to the given +max_rise+
        # and +max_fall+, in units per second.  If only one value is specified,
        # then the other value will be set to its negative.
        #
        # A value of zero for +max_fall+ outputs a cumulative maximum value, and
        # similarly for +max_rise+.
        #
        # The +:reset+ parameter may be used to set an initial value for the
        # output before any slope limiting is applied.
        #
        # This method is useful for interpolating changes to constant values (see
        # also #smooth and #filter).
        #
        # Uses MB::Sound::Filter::LinearFollower.
        def clip_rate(max_rise, max_fall = nil, reset: nil, sample_rate: self.sample_rate)
          max_fall ||= -max_rise
          max_rise ||= -max_fall
          f = MB::Sound::Filter::LinearFollower.new(sample_rate: sample_rate, max_rise: max_rise, max_fall: max_fall)
          f.reset(reset) if reset
          self.filter(f)
        end
      end
    end
  end
end

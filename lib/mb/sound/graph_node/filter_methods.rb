module MB
  module Sound
    module GraphNode
      # Methods that append filters to a graph (see MB::Sound::Filter).
      # Included in GraphNode.
      module FilterMethods
        # Applies the given filter (creating the filter if given a filter type)
        # to this sample source or sample chain.  If given a filter type, then a
        # dynamically updating filter is created where the cutoff and quality are
        # controlled by the given sample sources (e.g. numeric value, tone
        # generator, audio input, or ADSR envelope).
        #
        # Defaults to generating a low-pass filter if given a frequency in Hz.
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
        # TODO: support SampleWrapper inputs argument
        def filter(filter_or_type = :lowpass, cutoff: nil, quality: nil, gain: nil, in_place: false)
          f = filter_or_type
          f = f.hz if f.is_a?(Numeric)
          f = f.lowpass if f.is_a?(Tone)

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
            # TODO: Support graph node sources for filter gain
            f = MB::Sound::Filter::Cookbook.new(filter_or_type, sample_rate, 1, quality: 1, db_gain: gain&.to_db)
            MB::Sound::Filter::SampleWrapper.new(f, self, inputs: { cutoff: cutoff, quality: quality })

          when f.is_a?(MB::Sound::Filter::Cookbook)
            # TODO: Support graph node sources for filter gain
            raise 'Only specify gain when creating a new filter' if gain

            MB::Sound::Filter::SampleWrapper.new(f, self, inputs: { cutoff: cutoff || f.cutoff, quality: quality || f.quality })

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
        def peq(pairs)
          raise "PEQ frequency/gain pairs must be a Hash from frequency to gain (got #{pairs.class})" unless pairs.is_a?(Hash)

          filters = pairs.map { |freq, gain|
            freq = freq.frequency if freq.is_a?(Tone)
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

            MB::Sound::Filter::Cookbook.new(:peak, self.sample_rate, freq, db_gain: gain.to_db, bandwidth_oct: bandwidth)
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
        def peq_series(fundamental_hz, count: 5, ratio: 1.0, gain: 0.db, width: 0.1)
          # TODO: support GraphNode inputs like in #bandpass_series
          pairs = Array.new(count) do |idx|
            g = gain.respond_to?(:call) ? gain.call(idx) : gain
            w = width.respond_to?(:call) ? width.call(idx) : width
            [fundamental_hz * (1 + ratio * idx), { gain: g, width: w }]
          end

          peq(pairs.to_h)
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
        #     play 0.5.hz.ramp.at(50).filter(:lowpass, cutoff: 1000, quality: 0.5).bandpass_series(440, quality: 1414, count: 20, ratio: 1.7).softclip(0.9).forever
        #
        #     # MIDI controlled
        #     play (midi.env(0.0, 0.00005, 0, 0.00005) * 100).bandpass_series(midi.frequency, quality: 500, count: 16, ratio: midi.cc(1, range: 1..4)).softclip(0.9).oversample(4)
        def bandpass_series(fundamental_hz, count: 5, ratio: 1.0, quality: 14.14, gain: 0.db)
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
                f = MB::Sound::Filter::Cookbook.new(:bandpass, self.sample_rate, 1000, quality: 1, db_gain: g.to_db)
                {
                  filter: f,
                  inputs: {
                    cutoff: freq,
                    quality: q,
                  },
                }
              else
                MB::Sound::Filter::Cookbook.new(:bandpass, self.sample_rate, freq, quality: q, db_gain: g.to_db)
              end
            end
          )

          self.filter(fs)
        end

        # Applies an IIR phase difference network to remove negative frequencies
        # and produce a Complex-valued analytic signal.
        #
        # See MB::Sound::Filter::HilbertIIR.
        def hilbert_iir(sample_rate: 48000)
          filter(MB::Sound::Filter::HilbertIIR.new(sample_rate: sample_rate))
        end

        # Adds a MB::Sound::Filter::Smoothstep filter to the chain, smoothing
        # over the given number of samples or seconds.
        #
        # TODO: instead of reacting to step changes in the input, use an FIR
        # filter whose step response is the smoothstep function.
        def smooth(samples: nil, seconds: nil, sample_rate: 48000)
          filter(MB::Sound::Filter::Smoothstep.new(sample_rate: sample_rate, samples: samples, seconds: seconds))
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
        def clip_rate(max_rise, max_fall = nil, reset: nil, sample_rate: 48000)
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

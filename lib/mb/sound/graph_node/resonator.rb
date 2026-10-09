module MB
  module Sound
    module GraphNode
      # A struck resonator ("ping"): each impulse of the input rings as a
      # decaying sine at +freq+ Hz whose amplitude is the impulse's height
      # (so a trigger valued at its velocity rings at that level), falling
      # 60 dB in +decay+ seconds.  Strikes add to whatever is still ringing,
      # like a struck drum head or a bridged-T circuit.
      #
      # The frequency (and decay) may move every sample without changing the
      # ringing level: the state is a complex number that each sample
      # rotates by 2 pi f / fs and shrinks by the decay factor (a complex
      # one-pole filter; C kernel MB::Sound::FastResonator.ping, exact Ruby
      # mirror .process_ruby).  A resonant bandpass swept the same way rings
      # louder: a constant-Q filter's ring scales with its frequency at the
      # strike (+45% for an 808 kick's pitch sigh), and a direct-form biquad
      # adds about 1 dB more from coefficients changing under a ringing
      # state (measured 2026-10-08: peaks biquad 1.23, SVF 1.09, ping 0.74).
      # The ring height here is the strike's at any frequency.
      #
      # Any signal may be the input: impulses (Notes#trigger, Tone#wraps)
      # ping it; a continuous input is filtered by a resonance whose peak
      # gain is about 1 / (1 - r) (r = 1000 ** (-1 / (decay * fs))), so keep
      # continuous inputs quiet.  +phase+ (radians) is where each ring
      # starts: 0 (default) a sine starting at zero, Math::PI / 2 a cosine
      # starting at its peak (clickier).
      #
      # When the input ends the resonator rings out, then ends once its
      # state has fallen below -120 dB.
      #
      # Examples (bin/sound.rb):
      #     clip = grid(16, 'x..x..x.').loop
      #     play clip.trigger.ping(55, decay: 0.6)                         # a plain 808-ish kick
      #     play clip.trigger.ping(55 * (clip.trigger.adsr(0, 0.03, 0, 0, curve: 0) * 0.5 + 1), decay: 0.6)  # with a pitch sigh
      #     play noise.at(0.01).ping(440, decay: 2)                        # a resonating noise "string"
      class Resonator
        include GraphNode
        include SampleRateHelper

        # ln(1000), as in the C kernel: the state falls 60 dB in +decay+.
        LN_1000 = 6.907755278982137

        # The kernel flushes states smaller than this (both parts) to zero.
        FLUSH = 1e-30

        # The node ends this quiet (-120 dB) once its input has ended.
        QUIET = 1e-6

        # The input node (a sampler branch).
        attr_reader :input

        # The frequency in Hz: a Numeric or a node (a sampler branch).
        attr_reader :freq

        # The decay as given (a Length::Source holds it).
        attr_reader :decay

        # The starting phase of each ring, in radians.
        attr_reader :phase

        # Creates a resonator pinged by +input+ (see the class description).
        # +freq+ is Hz: a number, a node, or a Pitch/Note.  +decay+ is the
        # time to fall 60 dB: seconds, a Length, a Duration (follows the
        # tempo), or a node of seconds.
        def initialize(input, freq:, decay:, phase: 0, sample_rate: nil)
          raise ArgumentError, "Resonator input must be a graph node (got #{input.inspect})" unless input.respond_to?(:sample)

          @input = input.get_sampler
          freq = freq.oscillator_frequency if freq.is_a?(MB::Sound::Pitch)
          raise ArgumentError, "Resonator frequency must be a number, node, or Pitch (got #{freq.inspect})" unless freq.is_a?(Numeric) || freq.respond_to?(:sample)

          @freq = freq.is_a?(Numeric) ? freq.to_f : freq.get_sampler
          @decay = decay
          @decay_source = Length::Source.new(decay)
          @phase = Phase.radians(phase).to_f # radians, or e.g. 0.25.cycles
          @cos_phase = Math.cos(@phase)
          @sin_phase = Math.sin(@phase)
          @sample_rate = (sample_rate || input.sample_rate).to_f
          @state = Numo::DFloat.zeros(2)
          @input_ended = false
          @buf = nil
          @node_type_name = 'Resonator'
        end

        # Returns +count+ samples of the ringing, or nil once the input has
        # ended and the ringing has died away (or the frequency or decay
        # node ended).
        def sample(count)
          x = @input_ended ? nil : @input.sample(count)
          if x.nil? || x.empty?
            @input_ended = true
            return nil if ringing_level < QUIET
            x = 0.0
          else
            count = x.length
          end

          f = @freq.is_a?(Numeric) ? @freq : @freq.sample(count)
          return nil if f.nil? || (f.is_a?(Numo::NArray) && f.empty?)
          d = @decay_source.samples(count, @sample_rate)
          return nil if d.nil?

          if f.is_a?(Numo::NArray) && f.length < count
            count = f.length
            x = x[0...count] if x.is_a?(Numo::NArray)
          end

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          MB::Sound::FastResonator.ping(@buf, x, f, d, @state, @sample_rate, @cos_phase, @sin_phase)
        end

        # The magnitude of the ringing state (the amplitude of the ring).
        def ringing_level
          Math.hypot(@state[0], @state[1])
        end

        # Silences the ringing.
        def reset
          @state.fill(0)
          self
        end

        def sources
          s = { input: @input }
          s[:freq] = @freq unless @freq.is_a?(Numeric)
          s[:decay] = @decay_source.node if @decay_source.node?
          s
        end

        def to_s
          f = @freq.is_a?(Numeric) ? "#{MB::M.sigfigs(@freq, 4)} Hz" : 'node Hz'
          "Resonator #{f}, decay #{@decay_source}"
        end

        # The exact Ruby mirror of MB::Sound::FastResonator.ping (same
        # arguments; see that kernel): the same double operations in the same
        # order, so specs compare the two for equality.  Inputs are read as
        # float32 values like the kernel's.
        def self.process_ruby(out, input, freq, decay, state, rate, cos_phi, sin_phi)
          n = out.length
          x_in = signal_values(input, n)
          f_in = signal_values(freq, n)
          d_in = signal_values(decay, n)
          fs = rate.to_f

          zr = state[0]
          zi = state[1]
          last_f = last_d = nil
          c = s = 0.0

          n.times do |i|
            x = x_in.is_a?(Array) ? x_in[i] : x_in
            f = f_in.is_a?(Array) ? f_in[i] : f_in
            d = d_in.is_a?(Array) ? d_in[i] : d_in

            if f != last_f || d != last_d
              w = 2.0 * Math::PI * f / fs
              r = d > 0 ? Math.exp(-LN_1000 / d) : 0.0
              c = r * Math.cos(w)
              s = r * Math.sin(w)
              last_f = f
              last_d = d
            end

            nr = c * zr - s * zi + x
            ni = s * zr + c * zi
            if nr.abs < FLUSH && ni.abs < FLUSH
              nr = 0.0
              ni = 0.0
            end
            zr = nr
            zi = ni

            out[i] = zi * cos_phi + zr * sin_phi
          end

          state[0] = zr
          state[1] = zi
          out
        end

        # A signal input as the kernel reads it: a Float, or an Array of
        # float32 values (real parts of complex inputs).
        def self.signal_values(value, n)
          case value
          when nil then 0.0
          when Numeric then value.to_f
          when Numo::NArray
            raise ArgumentError, 'array length does not match sample buffer length' unless value.length == n
            v = value.is_a?(Numo::SComplex) || value.is_a?(Numo::DComplex) ? value.real : value
            Numo::SFloat.cast(v).to_a
          else
            raise ArgumentError, "Expected a number or NArray (got #{value.class})"
          end
        end
        private_class_method :signal_values
      end
    end
  end
end

module MB
  module Sound
    module GraphNode
      # An additive oscillator whose harmonic spectrum can change while it
      # plays: every +update+ samples it builds a one-cycle
      # MB::Sound::Wavetable from the current harmonic amplitudes (and
      # phases), keeping only the harmonics that stay below the table's
      # alias ceiling at the current pitch, and crossfades from the previous
      # table to the new one over the next +update+ samples (as two frames
      # of one table, scanned by a ramp, so the crossfade costs nothing
      # extra).  The phase runs on through rebuilds.
      #
      # The spectrum is an Array of amplitudes (numbers or graph nodes, read
      # at each update; the first is harmonic 1), or anything that responds
      # to #call, called at each update with the time in seconds since the
      # oscillator started and returning amplitudes, or [amplitudes, phases]
      # (Arrays or NArrays).  +phases+ (radians, sine phase) may also be
      # given as an Array.
      #
      # Examples (bin/sound.rb):
      #     play 110.hz.harmonics([1, 0.5.hz.lfo.at(0..1), 0, 0.3.hz.lfo.at(0..0.5)]).at(0.3)
      #     # A spectrum that brightens over 4 seconds (32 harmonics, 1/h rolloff)
      #     play 55.hz.harmonics(->(t) { Array.new(32) { |i| [t / 4, 1].min**i / (i + 1) } }).at(0.3)
      #
      # See Pitch#harmonics.
      class HarmonicTable
        include GraphNode
        include GraphNode::SampleRateHelper

        # The default number of samples between table rebuilds (about 11 ms
        # at 48 kHz).  Each rebuild builds a Wavetable in Ruby: with YJIT a
        # 32-harmonic oscillator costs about 2% of realtime at 512, 3.4% at
        # 256, and 6.4% at 128.
        DEFAULT_UPDATE = 512

        # The most harmonics a rebuilt table keeps.
        MAX_HARMONICS = 1023

        # The spectrum (see the class description).
        attr_reader :spectrum

        # Samples between rebuilds.
        attr_reader :update

        # +frequency+ - Hz (a number or a graph node).
        # +spectrum+ - Amplitudes (an Array of numbers or nodes) or a
        #              callable (see the class description).
        # +phases+ - Radians per harmonic (an Array), or nil for 0.
        # +update+ - Samples between rebuilds (and the crossfade length).
        # +interpolation+ - See MB::Sound::Wavetable (default :optimal).
        def initialize(frequency:, spectrum:, phases: nil, update: DEFAULT_UPDATE, interpolation: nil, sample_rate: 48000)
          unless frequency.is_a?(Numeric) || frequency.respond_to?(:sample)
            raise ArgumentError, "Frequency must be a number or a graph node (got #{frequency.inspect})"
          end
          unless spectrum.respond_to?(:call) || spectrum.is_a?(Array) || spectrum.is_a?(Numo::NArray)
            raise ArgumentError, 'Spectrum must be an Array of amplitudes (numbers or nodes) or respond to #call'
          end
          raise ArgumentError, 'Update must be a positive number of samples' unless update.is_a?(Integer) && update > 0

          @frequency = frequency.respond_to?(:get_sampler) ? frequency.get_sampler : frequency
          @spectrum = spectrum.is_a?(Numo::NArray) ? spectrum.to_a : spectrum
          if @spectrum.is_a?(Array)
            @spectrum = @spectrum.map { |a| a.respond_to?(:get_sampler) ? a.get_sampler : a }
          end
          @phases = phases
          @update = update
          @interpolation = interpolation
          @sample_rate = sample_rate.to_f

          @state = [0.0]
          @tstate = [0.0, 0.0, 0, 0.0, 0.0]
          @prev = nil
          @current = nil
          @table = nil
          @countdown = 0
          @fade = 0
          @time = 0
          @buf = nil
        end

        # The table read now (two frames: the previous spectrum and the
        # current one), or nil before the first sample.
        attr_reader :table

        def sources
          srcs = { frequency: (@frequency if @frequency.respond_to?(:sample)) }
          if @spectrum.is_a?(Array)
            @spectrum.each_with_index { |a, i| srcs[:"harmonic_#{i + 1}"] = a if a.respond_to?(:sample) }
          end
          srcs.compact
        end

        # Returns +count+ samples; ends when the frequency or a spectrum node
        # ends.
        def sample(count)
          freq = @frequency
          if freq.respond_to?(:sample)
            freq = freq.sample(count)
            return nil if freq.nil? || freq.empty?

            count = freq.length
          end

          values = node_amplitudes(count)
          return nil if values == :ended

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          out = @buf.inplace!

          pos = 0
          while pos < count
            if @countdown <= 0
              rebuild(values, freq, @time + pos)
              @countdown = @update
            end

            n = [count - pos, @countdown].min
            f = freq.is_a?(Numo::NArray) ? freq[pos...(pos + n)] : freq
            # Crossfade from the previous spectrum to the current one over
            # the first +update+ samples after a rebuild
            scan = (Numo::SFloat.new(n).seq + (@update - @countdown + 1)) / @update
            scan = scan.clip(0, 1)
            @table.oscillate(out[pos...(pos + n)].inplace!, f, 1.0 / @sample_rate, 1.0, 0.0, @state, @tstate, 0, nil, scan, @interpolation, @sample_rate, false)

            pos += n
            @countdown -= n
          end

          @time += count
          out.not_inplace!
        end

        private

        # The current amplitudes of spectrum nodes (read every buffer, so
        # they advance with the graph), or the numbers; :ended if a node
        # ended.
        def node_amplitudes(count)
          return nil unless @spectrum.is_a?(Array)

          @spectrum.map { |a|
            if a.respond_to?(:sample)
              data = a.sample(count)
              return :ended if data.nil? || data.empty?

              data[-1].real.to_f
            else
              a.to_f
            end
          }
        end

        # Builds the next table from the amplitudes now: frames [previous,
        # current], harmonics limited to those below the alias ceiling at the
        # highest frequency of +freq+ (and MAX_HARMONICS).  The current
        # spectrum is kept whole, so harmonics come back if the pitch falls.
        def rebuild(values, freq, time)
          amps, phases = current_spectrum(values, time)
          top = freq.is_a?(Numo::NArray) ? freq.abs.max.to_f : freq.to_f.abs
          # Harmonics that stay below the alias ceiling at the top frequency
          alias_limit = MAX_HARMONICS
          if top > 0
            ceiling = 1.0 - MB::Sound::Wavetable::AUDIBLE_LIMIT / @sample_rate
            ceiling = 0.5 if ceiling < 0.5
            alias_limit = [alias_limit, (ceiling * @sample_rate / top).floor].min
          end
          wanted = [amps.length, @current ? @current[0].length : 0].max
          limit = [[alias_limit, wanted].min, 1].max
          full = [amps, phases]

          amps = amps.first(limit)
          phases = phases&.first(limit)
          amps = amps + [0.0] * (limit - amps.length) if amps.length < limit
          phases = phases + [0.0] * (limit - phases.length) if phases && phases.length < limit

          prev_amps, prev_phases = @current || full
          prev_amps = (prev_amps + [0.0] * limit).first(limit)
          prev_phases = (prev_phases + [0.0] * limit).first(limit) if prev_phases
          @current = full

          all_phases = phases || prev_phases ? [prev_phases || [0.0] * limit, phases || [0.0] * limit] : nil
          size = [64, 2 * limit + 2].max
          @table = MB::Sound::Wavetable.from_harmonics([prev_amps, amps], all_phases, size: size, mips: [limit], interpolation: @interpolation)
        end

        # [amplitudes, phases or nil] (Arrays of Floats) now.
        def current_spectrum(values, time)
          if @spectrum.respond_to?(:call)
            result = @spectrum.call(time / @sample_rate)
            if result.is_a?(Array) && result.length == 2 && (result[0].is_a?(Array) || result[0].is_a?(Numo::NArray))
              amps, phases = result
            else
              amps = result
              phases = @phases
            end
          else
            amps = values
            phases = @phases
          end

          amps = amps.to_a.map(&:to_f)
          phases = phases&.to_a&.map(&:to_f)
          [amps, phases]
        end
      end
    end
  end
end

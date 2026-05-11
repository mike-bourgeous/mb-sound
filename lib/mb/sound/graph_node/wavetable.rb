module MB
  module Sound
    module GraphNode
      # Implementation of a wavetable waveshaper/synthesizer based on a wave
      # table stored as a 2D Numo::NArray.
      #
      # See bin/make_wavetable.rb.
      # See MB::Sound::Wavetable.
      # See MB::Sound::GraphNode#wavetable.
      class Wavetable
        include GraphNode
        include GraphNode::SampleRateHelper

        # The 2D Numo::NArray wavetable data used for sampling.
        attr_reader :table

        # The interpolation mode -- :cubic or :linear
        attr_accessor :lookup

        # The wrapping mode -- :wrap, :clamp, :bounce, or :zero
        attr_accessor :wrap

        # Creates a new wavetable node.
        #
        # +:wavetable+ - A 2D Numo::NArray with time as columns and waves as
        #                rows, the filename of a previously saved wavetable, or
        #                a Hash of args to MB::Sound::Wavetable.load_wavetable.
        # +:number+ - A GraphNode to control the wave number (e.g. `3.constant`).
        # +:phase+ - A GraphNode to control the wave phase (e.g. `120.hz.ramp.at(1)`).
        def initialize(wavetable:, number:, phase:, sample_rate:, lookup:, wrap:)
          raise 'Number must be a GraphNode' unless number.is_a?(GraphNode)
          raise 'Phase must be a GraphNode' unless phase.is_a?(GraphNode)

          case wavetable
          when Hash
            filename = wavetable.fetch(:wavetable)
            args = wavetable.reject { |k, _| k == :wavetable }
            wavetable = MB::Sound::Wavetable.load_wavetable(filename, **args)

          when String
            wavetable = MB::Sound::Wavetable.load_wavetable(wavetable)

          else
            unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2
              raise 'Wavetable must be a 2D NArray or a wavetable filename' unless wavetable.ndim == 2
            end
          end

          number = number.get_sampler if number.respond_to?(:get_sampler)
          phase = phase.get_sampler if phase.respond_to?(:get_sampler)

          @table = wavetable
          @number = number
          @phase = phase
          @sample_rate = sample_rate
          @lookup = lookup
          @wrap = wrap
        end

        # The inputs to this node for wave number and wave phase.
        def sources
          {
            number: @number,
            phase: @phase,
          }
        end

        # Creates +count+ total copies of this Wavetable and its upstream phase
        # source, with the upstream phase source detuned as in Tone#unison.
        # The phase source must respond to #unison.
        #
        # See Tone#unison.
        #
        # Example:
        #     play 50.hz.wavetable(wavetable: 'sounds/synth0.flac', number: 0).unison(0.2, 8).each_slice(2).to_a.transpose.map(&:sum).map(&:softclip)
        def unison(semitones = 0.1, count = 2)
          orig_phase = climb_tee_tree(@phase)
          raise 'Wavetable phase must respond to #unison' unless orig_phase.respond_to?(:unison)

          phases = orig_phase.unison(semitones, count)

          Array.new(count) { |idx|
            (idx == 0 ? self : self.dup).tap { |w|
              w.instance_variable_set(:@phase, phases[idx])
            }
          }
        end

        # Returns +count+ samples based on a wavetable lookup using the wave
        # number and phase from upstream graph sources given to the constructor.
        def sample(count)
          rho = @number.sample(count)
          phi = @phase.sample(count)
          return nil if rho.nil? || phi.nil? || rho.empty? || phi.empty?

          rho = MB::M.zpad(rho, count) if rho.length < count
          phi = MB::M.zpad(phi, count) if phi.length < count

          # TODO: dynamic parameters for lookup mode and wrapping mode
          ::MB::Sound::Wavetable.wavetable_lookup(wavetable: @table, number: rho, phase: phi, lookup: @lookup, wrap: @wrap)
        end
      end
    end
  end
end

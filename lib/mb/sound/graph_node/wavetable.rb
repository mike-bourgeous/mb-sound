module MB
  module Sound
    module GraphNode
      # Implementation of a wavetable synthesizer based on a wave table stored as
      # a 2D Numo::NArray.
      #
      # See bin/make_wavetable.rb.
      class Wavetable
        include GraphNode
        include GraphNode::SampleRateHelper

        # Creates a new wavetable node.
        #
        # +:wavetable+ - A 2D Numo::NArray with time as columns and waves as rows.
        # +:number+ - A GraphNode to control the wave number (e.g. `3.constant`).
        # +:phase+ - A GraphNode to control the wave phase (e.g. `120.hz.ramp.at(1)`).
        def initialize(wavetable:, number:, phase:, sample_rate:)
          raise 'Number must be a GraphNode' unless number.is_a?(GraphNode)
          raise 'Phase must be a GraphNode' unless phase.is_a?(GraphNode)
          unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2
            raise 'Wavetable must be a 2D NArray'
          end

          @wavetable = wavetable
          @number = number
          @phase = phase
          @sample_rate = sample_rate
        end

        # The inputs to this node for wave number and wave phase.
        def sources
          {
            number: @number,
            phase: @phase,
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

          self.class.wavetable_lookup(wavetable: @wavetable, number: rho, phase: phi)
        end

        # Performs a fractional wavetable lookup with wraparound
        # :number - A 1D Numo::NArray with the wave number over time
        # :phase - A 1D Numo::NArray with the wave phase over time
        def self.wavetable_lookup(wavetable:, number:, phase:)
          raise 'Number and phase must be the same size array' unless number.length == phase.length

          number.map_with_index do |num, idx|
            phi = phase[idx]
            outer_lookup(wavetable: wavetable, number: num, phase: phi)
          end
        end

        # Blends two columns within a single row of the wavetable.
        #
        # :number - The wave number, which should be an integer.
        # :phase - Time index from 0 to 1.
        #
        # TODO: wrapping or bouncing?
        def self.inner_lookup(wavetable:, number:, phase:)
          row = number.floor

          fcol = (phase % 1.0) * wavetable.shape[1]
          col1 = fcol.floor
          col2 = fcol.ceil
          col1 %= wavetable.shape[1]
          col2 %= wavetable.shape[1]

          ratio = fcol - col1

          val1 = wavetable[row, col1]
          val2 = wavetable[row, col2]

          val2 * ratio + val1 * (1.0 - ratio)
        end

        # Blends two waves using #inner_lookup.
        #
        # :number - Fractional wave number
        # :phase - Time index from 0 to 1
        def self.outer_lookup(wavetable:, number:, phase:)
          frow = number % wavetable.shape[0]
          row1 = frow.floor
          row2 = frow.ceil
          row1 %= wavetable.shape[0]
          row2 %= wavetable.shape[0]

          ratio = frow - row1

          val1 = inner_lookup(wavetable: wavetable, number: row1, phase: phase)
          val2 = inner_lookup(wavetable: wavetable, number: row2, phase: phase)

          val2 * ratio + val1 * (1.0 - ratio)
        end
      end
    end
  end
end

require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Uses an MxN matrix (provided as an Array of Arrays, a Matrix, or a 2D
      # Numo::NArray) to combine N inputs to M outputs.
      class MatrixMixer
        # Represents a single output node of the matrix's N outputs.
        class MatrixOutput
          extend Forwardable
          include GraphNode
          include GraphNode::SampleRateHelper

          def_delegators :@matrix, :sample_rate

          # Creates an output node with the given +:matrix+ that owns it, and
          # the given +:index+.
          def initialize(matrix:, index:)
            @matrix = matrix
            @index = index
          end

          def sample(count)
            @matrix.sample_internal(count, @index)
          end

          # Sets the sample rate of the upstream inputs for the entire matrix
          # to the given +rate+.
          def sample_rate=(rate)
            @matrix.sample_rate = rate
          end

          def sources
            # TODO: show the matrix as the upstream node
            {}
          end
        end

        attr_reader :outputs, :sample_rate

        def initialize(matrix:, inputs:, sample_rate:)
          matrix = Matrix[*matrix.to_a]
          @procmatrix = ::MB::Sound::ProcessingMatrix.new(matrix, inputs: inputs.map(&:to_s))

          unless @procmatrix.input_channels == inputs.length
            raise "Matrix column count must equal the number of inputs (got #{matrix.length} rows and #{inputs.length} inputs)"
          end

          # TODO: abstract or consolidate with the code in Tee that tracks
          # which branches have been read
          @inputs = inputs
          @sampled_set = Set.new
          @data = nil
          @sample_rate = sample_rate.to_f

          @outputs = Array.new(@procmatrix.output_channels) do |idx|
            MatrixOutput.new(matrix: self, index: idx)
          end.freeze

          @inputs.each do |inp|
            inp.sample_rate = @sample_rate
          end
        end

        # Called by MatrixOutput#sample to update the upstream data and
        # retrieve the sample data for that output.
        def sample_internal(count, index)
          if @sampled_set.include?(index) || @data.nil?
            if @sampled_set.length != 0 && @sampled_set.length != @inputs.length
              warn "Matrix output #{index} sampled again before other outputs"
            end

            @sampled_set.clear

            @input_data = @inputs.map { |c| c.sample(count) }
            @output_data = @procmatrix.process(@input_data)
          end

          @output_data[index]
        end

        # Sets the sample rate of all inputs to the matrix to the given +rate+.
        # Usually called by MatrixOutput#sample_rate=.
        def sample_rate=(rate)
          @sample_rate = rate.to_f
          @inputs.each do |inp|
            inp.sample_rate = @sample_rate
          end
        end
      end
    end
  end
end

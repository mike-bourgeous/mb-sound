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
            self
          end

          def sources
            { matrix: @matrix }
          end

          def to_s
            "Matrix output #{@index} of #{@matrix.count}"
          end
        end

        attr_reader :outputs, :sample_rate, :count

        # Initializes a matrix mixer with the given +:matrix+, list of
        # +:inputs+, and +:sample_rate+.  The +:matrix+ may be a Matrix, Array
        # of Arrays, or 2D Numo::NArray.  Raises an error if the input list
        # length does not equal the number of columns in the matrix.
        def initialize(matrix:, inputs:, sample_rate:)
          matrix = Matrix[*matrix.to_a]
          @procmatrix = ::MB::Sound::ProcessingMatrix.new(matrix)

          unless @procmatrix.input_channels == inputs.length
            raise "Matrix column count must equal the number of inputs (got #{@procmatrix.input_channels} columns and #{inputs.length} inputs)"
          end

          # TODO: abstract or consolidate with the code in Tee that tracks
          # which branches have been read
          @inputs = inputs.map.with_index { |c, idx|
            c.get_sampler.named("Matrix input #{idx + 1}")
          }
          @sampled_set = Set.new
          @input_data = nil
          @output_data = nil
          @sample_rate = sample_rate.to_f

          @outputs = Array.new(@procmatrix.output_channels) do |idx|
            MatrixOutput.new(matrix: self, index: idx)
          end.freeze

          @count = @outputs.count

          @inputs.each do |inp|
            # FIXME: ArrayInput and FFMPEGInput need sample_rate= methods
            inp.sample_rate = @sample_rate unless inp.sample_rate == @sample_rate
          end
        end

        def sources
          # FIXME: node graph iteration is reporting possible infinite loops on large graphs
          @inputs.map.with_index { |inp, idx|
            [:"input_#{idx + 1}", inp]
          }.to_h
        end

        # Called by MatrixOutput#sample to update the upstream data and
        # retrieve the sample data for that output.
        def sample_internal(count, index)
          if @sampled_set.include?(index) || @input_data.nil?
            if @sampled_set.length != 0 && @sampled_set.length != @inputs.length
              warn "Matrix output #{index} sampled again before other outputs"
            end

            @sampled_set.clear

            @input_data = @inputs.map { |c| c.sample(count).dup }
            return nil if @input_data.any?(&:nil?)

            @output_data = @procmatrix.process(@input_data)
          end

          return nil if @input_data.any?(&:nil?)

          @sampled_set << index

          @output_data[index].dup
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

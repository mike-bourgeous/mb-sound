require 'matrix'

module MB
  module Sound
    # Multiplies each sample of one or more incoming streams of time- or
    # frequency-domain data by a Ruby Matrix object, producing one or more output
    # streams (depending on the size of the Matrix).
    #
    # The incoming channels are treated as a column vector, which when
    # multiplied by the processing matrix results in another column vector for
    # the output channels.
    #
    # The number of input streams must match the number of columns in the
    # Matrix, and the number of output streams will match the number of rows.
    #
    # TODO: Show how this relates to equations for each channel
    #
    # TODO: Examples
    #
    # TODO: Should there be an extra 1.0 column for translation?
    # TODO: Allow changing the matrix?
    # TODO: Think of a better name?
    class MatrixProcess
      attr_reader :input_channels, :output_channels

      # Initializes a matrix processor with the given +matrix+, which must be a
      # Ruby Matrix.
      def initialize(matrix)
        raise "Processing matrix must be a Ruby Matrix class, not #{matrix.class}" unless matrix.is_a?(::Matrix)
        @matrix = matrix

        @input_channels = matrix.column_count
        @output_channels = matrix.row_count

        if @matrix.any? { |v| v.is_a?(Complex) || v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex) }
          @default_output_class = Numo::SComplex
        else
          @default_output_class = Numo::SFloat
        end
      end

      # Multiplies the list of channels by the processing matrix and returns
      # the result.  The +data+ should be given as an Array of Numo::NArray,
      # which should not be set to in-place modification (call
      # `Numo::NArray#not_inplace!` on the data before passing).
      def process(data)
        raise "Expected #{@input_channels} channels, got #{data.length}" unless data.length == @input_channels

        # TODO: Reuse buffers to reduce GC churn
        if data.any? { |d| d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex) }
          outputs = @output_channels.times.map { Numo::SComplex.zeros(data[0].length) }
        else
          outputs = @output_channels.times.map { @default_output_class.zeros(data[0].length) }
        end

        for idx in 0...data[0].length
          v = Vector[*data.map { |d| d[idx] }]
          o = @matrix * v

          for c in 0...@output_channels do
            outputs[c][idx] = o[c]
          end
        end

        outputs
      end
    end
  end
end

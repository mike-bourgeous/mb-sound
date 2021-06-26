require 'matrix'
require 'csv'
require 'yaml'
require 'json'

module MB
  module Sound
    # Multiplies each sample of one or more incoming streams of time- or
    # frequency-domain data by a Ruby Matrix object, producing one or more output
    # streams (depending on the size of the Matrix).
    #
    # The incoming data and the processing matrix may contain Complex numbers.
    #
    # The incoming channels are treated as a column vector, which when
    # multiplied by the processing matrix results in another column vector for
    # the output channels.
    #
    # The number of input streams must match the number of columns in the
    # Matrix, and the number of output streams will match the number of rows.
    #
    # This class is useful for producing output channels that are based on an
    # equation that combines the input channels.  In general, a system of
    # linear equations can be represented as a matrix.
    #
    # These equations:
    #
    #     f = A * x + B * y
    #     g = C * x + D * y
    #
    # Can be represented by this matrix multiplication:
    #
    #     [ f ] = [ A  B ] * [ x ]
    #     [ g ]   [ C  D ]   [ y ]
    #
    # In Ruby code form:
    #
    #     m = Matrix[
    #       [ A, B ],
    #       [ C, D ]
    #     ]
    #     input = Vector[x, y]
    #     output = m * input
    #     f, g = *output
    #
    # Examples:
    #
    #     # Pass-through of two channels
    #     p = MB::Sound::MatrixProcess.new(
    #       Matrix.identity(2) # Same thing as Matrix[[1, 0], [0, 1]]
    #     )
    #     p.process([Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6]])
    #     # => [Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6]]
    #
    #     # Swap channels
    #     p = MB::Sound::MatrixProcess.new(
    #       Matrix[
    #         [0, 1],
    #         [1, 0]
    #       ]
    #     )
    #     p.process([Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6]])
    #     # => [Numo::SFloat[4, 5, 6], Numo::SFloat[1, 2, 3]]
    #
    #     # Hafler circuit to generate rear ambience from stereo
    #     # Two input channels, four output channels
    #     # https://en.wikipedia.org/wiki/Hafler_circuit
    #     p = MB::Sound::MatrixProcess.new(
    #       Matrix[
    #         [1, 0], # Left
    #         [0, 1], # Right
    #         [1, -1], # Rear left
    #         [-1, 1], # Rear right
    #       ]
    #     )
    #     p.process([Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6]])
    #     # => [Numo::SFloat[4, 5, 6], Numo::SFloat[1, 2, 3], Numo::SFloat[-3, -3, -3], Numo::SFloat[3, 3, 3]]
    #
    #     # ElectroVoice Stereo-4 (1970) encoder
    #     # Four input channels, two output channels
    #     # https://en.wikipedia.org/wiki/Stereo-4
    #     p = MB::Sound::MatrixProcess.new(
    #       Matrix[
    #         [1.0, 0.3, 1.0, -0.5], # Left total
    #         [0.3, 1.0, -0.5, 1.0], # Right total
    #       ]
    #     )
    #     p.process([Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6], Numo::SFloat[-3, -4, -5], Numo::SFloat[-1, 0, 1]])
    #     # => [Numo::SFloat[-0.3, -0.5, -0.7], Numo::SFloat[4.8, 7.6, 10.4]]
    #
    # TODO: Should there be an extra 1.0 column for translation / DC bias?
    # TODO: Allow changing the matrix?
    # TODO: Think of a better name? -- ProcessingMatrix
    class MatrixProcess
      attr_reader :input_channels, :output_channels

      class MatrixTypeError < ArgumentError
        def initialize(msg = 'Data must be an Array of Numerics, or an Array of Arrays of Numerics')
          super(msg)
        end
      end

      # TODO: Maybe a .from_file method that can load from JSON, YML, or CSV?
      def self.from_file(filename)
        # TODO: Maybe merge with the similar code in mb-geometry and move into mb-util
        case File.extname(filename).downcase
        when '.json'
          data = JSON.parse(File.read(filename))

        when '.yml', '.yaml'
          data = YAML.load(File.read(filename))

        when '.csv'
          data = CSV.read(filename, converters: :numeric)

        when '.tsv'
          data = CSV.read(filename, col_sep: "\t", converters: :numeric)

        else
          raise "Unsupported extension on file #{filename.inspect}"
        end

        raise MatrixTypeError unless data.is_a?(Array)

        if data.all?(Array)
          data.map! { |d| convert_to_numbers(d) }
        else
          data = convert_to_numbers(data).map(&method(:Array))
        end

        MatrixProcess.new(Matrix[*data])
      end

      # Tries to convert every element of the array to Float if possible,
      # Complex if not.  Raises an error if any element could not be converted.
      # Modifies the array in-place.  Used by .from_file.
      def self.convert_to_numbers(arr)
        arr.map! { |v|
          begin
            v.is_a?(Numeric) ? v : (Float(v) rescue Complex(v.gsub(/\s+/, '')))
          rescue => e
            raise MatrixTypeError
          end
        }
      end

      # Initializes a matrix processor with the given +matrix+, which must be a
      # Ruby Matrix.
      #
      # TODO: should it be possible to give names to input and output channels
      # here?  Where would such names be used?
      def initialize(matrix)
        raise MatrixTypeError, "Processing matrix must be a Ruby Matrix class, not #{matrix.class}" unless matrix.is_a?(::Matrix)
        raise MatrixTypeError, 'Processing matrix must have at least one row and one column' if matrix.empty?
        @matrix = matrix

        @input_channels = matrix.column_count
        @output_channels = matrix.row_count
      end

      # Multiplies the list of channels by the processing matrix and returns
      # the result.  The +data+ should be given as an Array of Numo::NArray,
      # which should not be set to in-place modification (call
      # `Numo::NArray#not_inplace!` on the data before passing).
      def process(data)
        raise ArgumentError, "Expected #{@input_channels} channels, got #{data.length}" unless data.length == @input_channels
        (@matrix * Vector[*data]).to_a
      end
    end
  end
end

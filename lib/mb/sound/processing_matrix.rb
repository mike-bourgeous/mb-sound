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
    #     p = MB::Sound::ProcessingMatrix.new(
    #       Matrix.identity(2) # Same thing as Matrix[[1, 0], [0, 1]]
    #     )
    #     p.process([Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6]])
    #     # => [Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6]]
    #
    #     # Swap channels
    #     p = MB::Sound::ProcessingMatrix.new(
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
    #     p = MB::Sound::ProcessingMatrix.new(
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
    #     p = MB::Sound::ProcessingMatrix.new(
    #       Matrix[
    #         [1.0, 0.3, 1.0, -0.5], # Left total
    #         [0.3, 1.0, -0.5, 1.0], # Right total
    #       ]
    #     )
    #     p.process([Numo::SFloat[1, 2, 3], Numo::SFloat[4, 5, 6], Numo::SFloat[-3, -4, -5], Numo::SFloat[-1, 0, 1]])
    #     # => [Numo::SFloat[-0.3, -0.5, -0.7], Numo::SFloat[4.8, 7.6, 10.4]]
    #
    # TODO: Should there be an extra 1.0 column for translation / DC bias?
    # TODO: Allow changing the matrix?  e.g. for logic decoder methods that
    # alter the matrix instead of altering the output gains
    # TODO: consider ways to specify a channel layout or channel names in a
    # matrix, so the correct channel layout can be given to FFMPEG when
    # exporting audio.
    class ProcessingMatrix
      class MatrixTypeError < ArgumentError
        def initialize(msg = 'Data must be a Hash with :matrix, an Array of Numerics, or an Array of Arrays of Numerics')
          super(msg)
        end
      end

      # Creates a ProcessingMatrix instance from a 2D array of numbers (real or
      # complex) loaded from the given +filename+, which may be CSV, TSV, JSON,
      # or YAML.  The file may also contain a Hash with a :matrix key, and
      # optional :inputs and :outputs keys.
      #
      # See example matrix files in the matrices/ directory at the top of the
      # project.
      def self.from_file(filename, decode: false)
        # TODO: Maybe merge with the similar code in mb-geometry and move into mb-util
        case File.extname(filename).downcase
        when '.json'
          data = JSON.parse(File.read(filename), symbolize_names: true)

        when '.yml', '.yaml'
          data = YAML.load(File.read(filename), symbolize_names: true)

        when '.csv'
          data = CSV.read(filename, converters: :numeric)

        when '.tsv'
          data = CSV.read(filename, col_sep: "\t", converters: :numeric)

        else
          raise "Unsupported extension on file #{filename.inspect}"
        end

        from_hash_or_array(data, decode: decode)
      end

      # Creates a ProcessingMatrix instance from a 1D or 2D Array of Numerics,
      # or a Hash containing such an Array under the :matrix key, and optional
      # :inputs and :outputs keys to name input and output channels.
      def self.from_hash_or_array(data, decode: false)
        raise MatrixTypeError unless data.is_a?(Array) || (data.is_a?(Hash) && data.include?(:matrix))

        if data.is_a?(Hash)
          inputs = data[:inputs]
          outputs = data[:outputs]
          data = data[:matrix]
        end

        if data.all?(Array)
          data = data.map { |d| convert_to_numbers(d, conjugate: decode) }
        else
          data = convert_to_numbers(data, conjugate: decode).map(&method(:Array))
        end

        matrix = Matrix[*data]

        if decode
          matrix = matrix.transpose
          inputs, outputs = outputs, inputs
        end

        ProcessingMatrix.new(matrix, inputs: inputs, outputs: outputs)
      end

      # Tries to convert every element of the array to Float if possible,
      # Complex if not.  Raises an error if any element could not be converted.
      # Modifies the array in-place.  Used by .from_file.
      #
      # If +:conjugate+ is true, then all values will be replaced with their
      # complex conjugate.  That is, the imaginary component will be negated,
      # so (1+1i) becomes (1-1i).  This turns a positive rotation into a
      # negative rotation, and vice versa.
      def self.convert_to_numbers(arr, conjugate: false)
        arr.map! { |v|
          begin
            v = (Float(v) rescue Complex(v.gsub(/\s+/, ''))) unless v.is_a?(Numeric)
            v = v.conj if conjugate
            v
          rescue => e
            raise MatrixTypeError
          end
        }
      end

      attr_reader :input_channels, :output_channels
      attr_reader :inputs, :outputs

      # Initializes a matrix processor with the given +matrix+, which must be a
      # Ruby Matrix.  The +:inputs+ and +:outputs+ may be named by passing
      # Arrays of Strings of the correct length.
      def initialize(matrix, inputs: nil, outputs: nil)
        raise MatrixTypeError, "Processing matrix must be a Ruby Matrix class, not #{matrix.class}" unless matrix.is_a?(::Matrix)
        raise MatrixTypeError, 'Processing matrix must have at least one row and one column' if matrix.empty?
        @matrix = matrix.freeze

        @input_channels = matrix.column_count
        @output_channels = matrix.row_count

        inputs ||= 1.upto(@input_channels).to_a
        raise "Expected #{@input_channels} input names, but received #{inputs.length}" if inputs.length != @input_channels
        @inputs = inputs.freeze

        outputs ||= 1.upto(@output_channels).to_a
        raise "Expected #{@output_channels} output names, but received #{outputs.length}" if outputs.length != @output_channels
        @outputs = outputs.freeze
      end

      # Multiplies the list of channels by the processing matrix and returns
      # the result.  The +data+ should be given as an Array of Numo::NArray,
      # which should not be set to in-place modification (call
      # `Numo::NArray#not_inplace!` on the data before passing).
      def process(data)
        raise ArgumentError, "Expected #{@input_channels} channels, got #{data.length}" unless data.length == @input_channels
        (@matrix * Vector[*data]).to_a
      end

      # Returns the matrix coefficients as an Array.
      def to_a
        @matrix.to_a
      end

      # Prints the matrix coefficients as a table with input and output names.
      def table(print: true)
        MB::U.table(
          to_a.map.with_index { |row, idx| ["\e[1m#{outputs[idx].to_s.rjust(12)}\e[0m", *row] },
          header: ["\u2193 Out \\ In \u2192", *inputs],
          print: print,
          variable_width: true
        )
      end
    end
  end
end

module MB
  module Sound
    module GraphNode
      class ChannelMixer
        # Mixes N inputs into M outputs with any M×N matrix (one row per
        # output, one column per input).  Entries are numbers, complex
        # numbers (inputs then become analytic signals; see ChannelMixer), or
        # graph nodes giving a gain per sample.
        #
        # Created with GraphNode#matrix.
        #
        # Examples (bin/sound.rb):
        #     l, r = stereo(a, b).matrix([[1, 0.5], [0.5, 1]])     # a bit of crossfeed
        #     c = stereo(a, b).matrix([[0.5, 0.5]])                # 2 -> 1
        #     l, r = stereo(a, b).matrix([[1, 0], [0, 2.hz.lfo]])  # a node gain
        class Matrix < ChannelMixer
          channels :any => :any

          # The matrix rows as given (numbers and graph nodes).
          attr_reader :matrix

          # Creates a matrix mixer for +inputs+ with +matrix+: an Array of
          # Arrays, a Ruby ::Matrix, a 2D Numo::NArray, or a
          # MB::Sound::ProcessingMatrix.  Pass +complex: true+ if node entries
          # produce complex gains.
          def initialize(inputs, matrix:, complex: false, sample_rate: nil)
            super(inputs, sample_rate: sample_rate, matrix: matrix, complex: complex)
          end

          def gains_for(**values)
            @rows.map { |row| row.map { |g| g.is_a?(Symbol) ? values.fetch(g) : g } }
          end

          def to_s
            name = "Matrix #{@rows.length}x#{@rows.first.length}"
            nodes = @param_values.length
            nodes > 0 ? "#{name} (#{nodes} node gain#{nodes == 1 ? '' : 's'})" : name
          end

          private

          def setup(inputs, settings)
            @complex_nodes = settings.delete(:complex)
            @matrix = rows_of(settings.delete(:matrix))

            unless @matrix.all? { |row| row.length == inputs.length }
              raise ArgumentError, "The matrix needs one column per input (#{inputs.length}; got rows of #{@matrix.map(&:length).uniq.join(', ')})"
            end

            # Node entries become parameters named by position (m<row>_<column>)
            @rows = @matrix.map.with_index { |row, j|
              row.map.with_index { |g, i|
                if g.respond_to?(:sample)
                  name = :"m#{j + 1}_#{i + 1}"
                  add_param(name, g)
                  name
                elsif g.is_a?(Numeric)
                  g.is_a?(Complex) && g.imag == 0 ? g.real : g
                else
                  raise ArgumentError, "Matrix entries must be numbers or graph nodes (got #{g.inspect})"
                end
              }.freeze
            }.freeze
          end

          def output_channels
            @rows.length
          end

          def complex_gains?
            @complex_nodes || @rows.flatten.any? { |g| g.is_a?(Complex) }
          end

          def rows_of(matrix)
            rows = case matrix
                   when MB::Sound::ProcessingMatrix then matrix.to_a
                   when ::Matrix then matrix.to_a
                   when Numo::NArray
                     raise ArgumentError, 'A matrix NArray must be 2D' unless matrix.ndim == 2
                     matrix.to_a
                   when Array then matrix.map { |row| row.is_a?(Array) ? row : [row] }
                   else raise ArgumentError, "Give the matrix as an Array of rows, a Matrix, or a 2D NArray (got #{matrix.class})"
                   end
            raise ArgumentError, 'The matrix needs at least one row and column' if rows.empty? || rows.first.empty?
            rows
          end
        end
      end
    end
  end
end

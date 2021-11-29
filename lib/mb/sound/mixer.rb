module MB
  module Sound
    # Sums zero or more inputs that have a #sample method that takes a buffer
    # size parameter, such as an Oscillator.  One example use of this is as the frequency input.
    #
    # This is taking a step further into the territory of composable signal
    # graphs.  If I redesigned mb-sound from scratch, I would definitely design
    # everything as nodes within a signal graph, kind of like some of my old
    # (unreleased) projects, or like Pure Data.
    class Mixer
      # The constant value added to the output sum before any summands.
      attr_accessor :constant

      # Creates a Mixer with the given inputs, which must be either Numeric
      # values or objects that have a #sample method.  Each input may have an
      # associated gain.  The summands, gains, or numeric constants may all
      # have complex values.  At present, no attempt is made to detect cycles
      # in the signal graph.
      #
      # The +summands+ must be either an Array of objects responding to
      # :sample, in which case every summand will have a gain of 1.0, an Array
      # of two-element Arrays of the form [summand, gain], or a Hash from
      # summand to gain (yes, this is a bit redundant for Numeric summands).
      #
      # The +:buffer_size+ is used as an initial buffer size, but the buffer
      # will resize if #sample is given a different number of samples.
      def initialize(summands, buffer_size: 800)
        @constant = 0
        @summands = []

        summands.each_with_index do |(s, gain), idx|
          gain ||= 1.0

          if s.is_a?(Numeric)
            @constant += s * gain
          elsif s.respond_to?(:sample)
            @summands << [s, gain]
          else
            raise ArgumentError, "Summand #{s.inspect} at index #{idx} is not a Numeric and does not respond to :sample"
          end
        end

        @complex = @constant.is_a?(Complex)

        setup_buffer(buffer_size)
      end

      # Calls the #sample methods of all summands, applies gains, adds them all
      # to the initial #constant value, and returns the result.
      def sample(count)
        inputs = @summands.each do |s, gain|
          v = s.sample(count).not_inplace!
          @complex = true if v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex)
          [v, gain]
        end

        setup_buffer(count)

        @buf.fill(@constant)

        inputs.each do |v, gain|
          @tmpbuf.fill(gain).inplace * v
          @buf.inplace + @tmpbuf
        end

        @buf.not_inplace!
      end

      private

      def setup_buffer(length)
        @complex ||= @constant.is_a?(Complex)
        @bufclass = @complex ? Numo::SComplex : Numo::SFloat

        if @buf.nil? || @buf.length != length || @bufclass != @buf.class
          @buf = @bufclass.zeros(length)
          @tmpbuf = @bufclass.zeros(length)
        end
      end
    end
  end
end

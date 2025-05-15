require 'forwardable'

module MB
  module Sound
    # Reads audio data from another I/O and yields it to a block given to the
    # constructor before returning it in #read.  This allows audio to be e.g.
    # filtered before being passed to another class that expects an I/O object.
    class ProcessReader
      extend Forwardable

      def_delegators :@input_stream, :sample_rate, :channels, :buffer_size

      def initialize(input_stream, &process)
        raise 'Input stream must respond to #read' unless input_stream.respond_to?(:read)
        raise 'Input stream must respond to #buffer_size' unless input_stream.respond_to?(:buffer_size)
        raise 'A processing block must be given' unless block_given?

        @input_stream = input_stream
        @process = process
      end

      # Reads from the input stream.  The +size+ defaults to the input stream's
      # buffer size, and should generally be omitted.
      def read(size = nil)
        @process.call(
          @input_stream.read(size || @input_stream.buffer_size)
        )
      end
    end
  end
end

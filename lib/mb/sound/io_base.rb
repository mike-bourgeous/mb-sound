module MB
  module Sound
    # Base class for IOInput and IOOutput with shared code for setting buffer
    # sizes, etc.  Use IOInput or IOOutput instead of using this directly.
    class IOBase
      attr_reader :buffer_size, :frame_bytes, :channels

      DEFAULT_BUFFER = 1024

      # Called from IOInput and IOOutput.  The first parameter is either an IO
      # object, or an array with the arguments to #run.  Buffer size is in
      # samples per channel per buffer.
      def initialize(io_or_popen_args, channels, buffer_size)
        raise 'Channels must be an int >= 1' unless channels.is_a?(Integer) && channels >= 1
        raise 'Buffer size must be an int >= 1' if buffer_size && (!buffer_size.is_a?(Integer) || buffer_size < 1)

        @channels = channels
        @frame_bytes = channels * 4
        @buffer_size = buffer_size || DEFAULT_BUFFER

        if io_or_popen_args.is_a?(Array)
          @io = run(*io_or_popen_args)
        else
          @io = io_or_popen_args
        end
      end

      # Returns true if the input or output has been closed.
      def closed?
        @io.nil? || @io.closed?
      end

      # Closes the input or output.  Returns the process exit status object if
      # the IO object was opened by popen.
      def close
        return unless @io

        old_result = $?
        @io.close
        @io = nil
        new_result = $?

        new_result.equal?(old_result) ? nil : new_result
      end

      private

      # Wraps popen to set kernel internal pipe buffer size based on audio
      # buffer size, and to start the process in a different process group so
      # Ctrl-C doesn't interrupt it.
      #
      # +command+ is a String or an Array, +direction+ is 'r' or 'w'.
      #
      # If +command+ is an Array, any Procs in the array will be called and the
      # Proc's return value used in their place (works with anything that
      # responds to :call).  This allows referencing instance variables like
      # @buffer_size that aren't set until after the command array has to be
      # built.
      def run(command, direction)
        if command.is_a?(Array)
          command = command.map { |v| v.respond_to?(:call) ? v.call : v }
        end

        IO.popen(command, direction, pgroup: 0).tap { |pipe|
          size = @buffer_size * @channels * 4
          MB::Sound::U.pipe_size(pipe, size)
        }
      end
    end
  end
end

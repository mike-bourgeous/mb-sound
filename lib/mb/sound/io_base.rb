module MB
  module Sound
    # Base class for IOInput and IOOutput with shared code for setting buffer
    # sizes, etc.  Use IOInput or IOOutput instead of using this directly.
    class IOBase
      attr_reader :buffer_size, :frame_bytes, :channels, :sample_rate

      DEFAULT_BUFFER = 1024

      # Called from IOInput and IOOutput.  The first parameter is either an IO
      # object, or an array with the arguments to #run.  Buffer size is in
      # samples per channel per buffer.
      def initialize(io_or_popen_args, channels, buffer_size, sample_rate:)
        raise 'Channels must be an int >= 1' unless channels.is_a?(Integer) && channels >= 1
        raise 'Buffer size must be an int >= 1' if buffer_size && (!buffer_size.is_a?(Integer) || buffer_size < 1)

        @channels = channels
        @frame_bytes = channels * 4
        @buffer_size = buffer_size || DEFAULT_BUFFER
        @sample_rate = sample_rate.to_f

        @child = nil
        if io_or_popen_args.is_a?(Array)
          @popen = true
          @io = run(*io_or_popen_args)
        else
          @popen = false
          @io = io_or_popen_args
        end
      end

      # True if this reads from or writes to a command it started (see
      # #run), not an IO object it was given.
      def runs_command?
        @popen
      end

      # Returns true if the input or output has been closed.
      def closed?
        @io.nil? || @io.closed?
      end

      # Closes the input or output.  Returns the process's exit status (a
      # Starter::Status) if the IO object was opened by running a command.
      def close
        return unless @io

        @io.close
        @io = nil

        if @popen
          @child&.wait
        else
          nil
        end
      end

      private

      # Starts +command+ with a pipe (through MB::Sound::Starter, so the
      # console doesn't fork while audio plays), sets the kernel's pipe
      # buffer size based on the audio buffer size, and starts the process
      # in a different process group so Ctrl-C doesn't interrupt it.
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

        direction = "#{direction}b" unless direction.end_with?('b')

        pipe, @child = Starter.popen(command, direction, pgroup: 0)
        MB::U.pipe_size(pipe, @buffer_size * @channels * 4)
        pipe
      end
    end
  end
end

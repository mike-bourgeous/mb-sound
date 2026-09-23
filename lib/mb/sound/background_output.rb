require 'forwardable'

module MB
  module Sound
    # Wraps an output stream (e.g. MB::Sound::FFMPEGOutput) with a background
    # thread that does the actual writing, and that writes silence whenever
    # the caller stops writing, so the output never runs dry.
    #
    # Some outputs misbehave after running out of data.  For example, ffmpeg's
    # macOS audiotoolbox output loses its realtime backpressure after an idle
    # gap, so later writes return early and playback falls out of sync with
    # the code that is writing (see also issue #68).
    #
    # Writes go into a bounded queue (like the port queues in
    # MB::Sound::JackFFI), so #write still blocks when the caller gets too far
    # ahead of playback.  Silence is paced against the wall clock so that no
    # more than about +:lead_time+ seconds of silence are queued in the
    # output, which limits the latency added when real audio starts again.
    #
    # Example:
    #     out = MB::Sound::BackgroundOutput.new(MB::Sound::FFMPEGOutput.new(...))
    #     out.write([Numo::SFloat.zeros(800)] * 2)
    #     out.close
    class BackgroundOutput
      extend Forwardable

      # Raised by #write or #close if the background thread stopped due to an
      # error.  The original error is available as #cause.
      class OutputThreadError < IOError; end

      def_delegators :@output, :sample_rate, :channels, :buffer_size

      # The wrapped output object.
      attr_reader :output

      # The number of times the output switched from written data to silence.
      attr_reader :underruns

      # Wraps the given +output+ (which must respond to #write, #sample_rate,
      # #channels, and #buffer_size) and starts the background writing
      # thread.  The thread starts writing silence immediately.
      #
      # +:queue_size+ - The number of written buffers that may wait for the
      #                 background thread before #write blocks.
      # +:lead_time+ - How far ahead of the wall clock, in seconds, to keep
      #                the output fed with silence.  Defaults to two buffers.
      def initialize(output, queue_size: 2, lead_time: nil)
        [:write, :sample_rate, :channels, :buffer_size].each do |req_method|
          raise ArgumentError, "Output #{output} must respond to #{req_method.inspect}" unless output.respond_to?(req_method)
        end

        @output = output
        @queue = SizedQueue.new(queue_size)
        @lead_time = lead_time&.to_f || 2.0 * buffer_size / sample_rate
        @silence = Array.new(channels) { Numo::SFloat.zeros(buffer_size) }.freeze
        @underruns = 0
        @error = nil
        @closed = false

        @thread = Thread.new do write_loop end
        @thread.name = "BackgroundOutput(#{output.class.name&.rpartition('::')&.last})"
        @thread.report_on_exception = false

        # Like MB::M::Plot, make sure the queue is drained before exit so the
        # end of the last sound isn't cut off.
        at_exit do
          close rescue nil
        end
      end

      # Queues a copy of +data+ (an Array of Numo::NArrays with one element per
      # channel, or a single Numo::NArray for a mono output) to be written by
      # the background thread.  Blocks if the queue is full.  Returns the
      # number of frames queued.
      #
      # Raises OutputThreadError if the background thread has stopped due to
      # an error.
      def write(data)
        check_error
        raise IOError, 'Output is closed' if @closed

        data = [data] if data.is_a?(Numo::NArray)
        raise ArgumentError, "Received #{data.length} channels when #{channels} were expected" if data.length != channels

        # Copy because callers (e.g. graph nodes) may reuse their buffers
        # before the background thread writes them.
        @queue.push(data.map(&:dup))

        data[0].length

      rescue ClosedQueueError
        check_error
        raise IOError, 'Output is closed'
      end

      # Stops accepting writes, waits up to +timeout+ seconds for queued data
      # to be written, then closes the wrapped output.  Raises
      # OutputThreadError if the background thread stopped due to an error.
      def close(timeout: 5)
        return if @closed
        @closed = true

        @queue.close
        @thread.kill unless @thread.join(timeout)
        @output.close if @output.respond_to?(:close)

        check_error
      end

      # Returns true if this output was closed, the background thread has
      # stopped, or the wrapped output was closed.
      def closed?
        @closed || !@thread.alive? || (@output.respond_to?(:closed?) && @output.closed?)
      end

      # Returns true if the wrapped output only accepts writes of exactly
      # #buffer_size frames (see OutputBufferWrapper#flush).
      def strict_buffer_size?
        !@output.respond_to?(:strict_buffer_size?) || @output.strict_buffer_size?
      end
      alias strict_buffer_size strict_buffer_size?

      private

      # Re-raises an error from the background thread in the calling thread
      # (the same approach as JackFFI#check_for_processing_error).
      def check_error
        if @error
          e = @error
          @error = nil
          raise OutputThreadError, "Error in background output thread: #{e.message}", cause: e
        end
      end

      # Background thread loop: writes queued data, or silence if nothing
      # arrives in time to keep the output fed.  Exits when the queue is
      # closed and empty.
      def write_loop
        # Estimated clock time when everything written so far will have played
        deadline = MB::U.clock_now
        starved = true

        loop do
          timeout = deadline - @lead_time - MB::U.clock_now
          data = @queue.pop(timeout: timeout > 0 ? timeout : 0)

          if data.nil?
            break if @queue.closed?

            @underruns += 1 unless starved
            starved = true
            data = @silence
          else
            starved = false
          end

          start = MB::M.max(deadline, MB::U.clock_now)
          @output.write(data)
          deadline = start + data[0].length.to_f / sample_rate
        end

      rescue Exception => e
        @error = e
        @queue.close
      end
    end
  end
end

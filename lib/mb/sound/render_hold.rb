module MB
  module Sound
    # An output wrapper for PlaybackMethods#render that holds back the last
    # buffer written, so a render can end inside it: on the frame its sounds
    # ended, or where a tail's quiet stretch completed, the same at any
    # buffer size (session-2, the maintainer's "Exact frame", 2026-10-31).
    # #trim drops frames from the end of the held buffer; #flush writes it;
    # #close flushes and closes the wrapped output.  Everything else goes to
    # the wrapped output.
    class RenderHold
      # The wrapped output.
      attr_reader :output

      # The held buffer (one Numo array per channel), or nil.
      attr_reader :held

      # Frames the render trimmed from the end (see PlaybackMethods#render_end), or nil.
      attr_accessor :trimmed

      def initialize(output)
        @output = output
        @held = nil
        @trimmed = nil
      end

      # Writes the buffer held before (if any) and holds a copy of +data+.
      def write(data)
        flush
        @held = data.map(&:dup)
      end

      # Frames in the held buffer.
      def held_frames
        @held && !@held.empty? ? @held[0].length : 0
      end

      # Drops the last +frames+ frames of the held buffer (at most all of
      # it).  Returns the number dropped.
      def trim(frames)
        n = MB::M.clamp(frames, 0, held_frames)
        return 0 if n == 0

        keep = held_frames - n
        @held = keep == 0 ? nil : @held.map { |c| c[0...keep] }
        n
      end

      # Writes the held buffer, if any.
      def flush
        held = @held
        @held = nil
        @output.write(held) if held && held_frames_of(held) > 0
      end

      def sample_rate
        @output.sample_rate
      end

      def close
        flush
        @output.close
      end

      def respond_to_missing?(name, include_private = false)
        @output.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **kwargs, &block)
        return super unless @output.respond_to?(name)
        @output.public_send(name, *args, **kwargs, &block)
      end

      private

      def held_frames_of(held)
        held.empty? ? 0 : held[0].length
      end
    end
  end
end

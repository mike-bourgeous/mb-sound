module MB
  module Sound
    # The +:from+ and +:to+ of PlaybackMethods#render: renders one part of
    # a song (a section of its form, a marker, or a bar) on the song's own
    # timeline.  See design/notes/scripts.md (render windows).
    #
    # With +preroll: true+ (the default) the song plays from its start and
    # the frames before +from+ are rendered without being written (a
    # pre-roll), so the file holds exactly the song's own samples from that
    # frame on: tails, held notes, form decisions (picks, gotos), and
    # random draws are what they are in the whole song.  With +preroll:
    # false+ the timeline seeks there first (Session#seek, like `seek :drop`
    # in the console), which is faster for a section late in a long song,
    # but starts with fresh state (no tails from before; the form plays on
    # from the section as a seek would).
    module RenderWindow
      # A render window edge the song doesn't have (scripts print it as one
      # line; see ScriptingMethods).
      class TargetError < ArgumentError; end

      # An output that drops what is written until #open!, so a render's
      # pre-roll isn't written (everything else goes to the wrapped output).
      class Gate
        # The wrapped output.
        attr_reader :output

        def initialize(output)
          @output = output
          @open = false
          @skip = 0
        end

        # Starts passing writes through, dropping the first +skip+ frames of
        # the next write (the pre-roll's part of the buffer holding the
        # window's first frame).
        def open!(skip = 0)
          @open = true
          @skip = skip
          self
        end

        # True once #open! was called.
        def open?
          @open
        end

        def write(data)
          return unless @open

          if @skip > 0
            data = data.map { |c| c[@skip..] }
            @skip = 0
          end
          @output.write(data)
        end

        def sample_rate
          @output.sample_rate
        end

        def close
          @output.close
        end

        def respond_to_missing?(name, include_private = false)
          @output.respond_to?(name, include_private) || super
        end

        def method_missing(name, *args, **kwargs, &block)
          return super unless @output.respond_to?(name)
          @output.public_send(name, *args, **kwargs, &block)
        end
      end

      module_function

      # Raises unless +target+ can be a render window edge on +session+
      # (after the song's block ran): a bar number (from 1), or a section or
      # label of the song form playing, or a marker (as for Session#seek;
      # with suggestions for misspelled names).  +form+ is a Form about to
      # play, checked instead of the one playing (ScriptRunner checks
      # --from/--to that way before the form's warm-up).
      def check_target(session, target, what, form: nil)
        if target.is_a?(Symbol)
          session.send(:check_seek_target, target, form: form)
        elsif !(target.is_a?(Numeric) && target >= 1)
          raise TargetError, "#{what} is a section, label, or marker name, or a bar number from 1 (got #{target.is_a?(Rational) && target.denominator == 1 ? target.to_i : target.inspect})"
        end
      rescue ArgumentError => e
        raise e if e.message.start_with?(what.to_s)
        raise TargetError, "#{what} #{e.message.sub(/\A./, &:downcase)}"
      end

      # The timeline position (whole notes) of +target+ at or after +after+
      # (whole notes), or nil while it isn't known yet: a bar number's
      # position through the meter map, or a marker's (sections and labels
      # set theirs when the form reaches them, half a bar ahead in renders).
      def position(session, target, after)
        if target.is_a?(Symbol)
          pos = session.markers.position(target)
          pos && pos >= after ? pos : nil
        else
          session.transport.bar_position(target)
        end
      end

      # Plays +session+ without writing (its output is a Gate) in whole
      # buffers of +buffer_size+ (the grid of a render from the start, so
      # every node sees the same buffers as there, buffer-size dependent
      # ones too) up to the buffer holding the frame where +from+ starts:
      # the frame holding its position (where launches there land; see
      # Session).  Raises if the song ends or +limit+ frames pass first.
      # Returns the frames of that buffer before +from+'s frame (the Gate
      # drops them).
      def preroll(session, from, buffer_size:, limit:, progress: nil)
        transport = session.transport
        rate = session.output.sample_rate
        start = transport.position
        frames = 0

        loop do
          pos = position(session, from, start)
          if pos
            per_sample = transport.whole_notes_per_second / rate.to_r
            k = ((pos - transport.position) / per_sample).floor
            if k < 0
              raise "render(from: #{from.inspect}): the timeline passed #{session.stamp(pos)} before it was known " \
                "(at #{session.stamp(transport.position)})"
            end
            return k if k < buffer_size
          end
          count = buffer_size

          if session.idle? && !session.schedule_due? && !session.schedule_waiting?(repeating: false)
            raise ArgumentError, "render(from: #{from.inspect}): the song ended at #{session.stamp(transport.position)} before getting there"
          end

          if frames + count > limit
            raise ArgumentError, "render(from: #{from.inspect}): not reached within #{(limit.to_f / rate).round} seconds"
          end

          session.process_buffer(count)
          frames += count
          progress&.update(:preroll, target: from)
        end
      end

      # Moves +session+'s timeline to +from+ through Session#seek (see
      # +preroll: false+) and lands it with an empty buffer.  Returns the
      # position it landed on.
      def seek(session, from)
        session.seek(from)
        session.process_buffer(0)
        session.transport.position
      end
    end
  end
end

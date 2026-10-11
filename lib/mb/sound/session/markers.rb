module MB
  module Sound
    class Session
      # The Session's marker table (interconnect contract K8): one table
      # from name to Marker, shared by song forms (each section registers a
      # :section marker where it starts), the performer (`marker :vo, at:
      # bar(5, beat: 2)`), and later imported marker files.
      #
      # Markers keep their kind: :section, :label (a form's labels, set
      # where the flow passes them), and :position markers are
      # timeline positions (whole notes; they follow the tempo), :time
      # markers are absolute times in seconds of timeline (they don't move
      # when the tempo changes; converted at the tempo in effect when they
      # are used, since tempo ramps don't exist yet).
      #
      # Blocks waiting on a marker (#on, used by `at_marker`) run when the
      # marker is next set to a time that hasn't passed.
      class Markers
        # Marker kinds.
        KINDS = [:section, :label, :position, :time].freeze

        # A marker: +name+, +kind+ (see KINDS), and either +pos+ (whole
        # notes, for :section, :label, and :position) or +seconds+ (for
        # :time).
        Marker = Data.define(:name, :kind, :pos, :seconds) do
          def to_s
            where = seconds ? "#{seconds.round(3)} s" : "pos #{pos}"
            "#{name.inspect} (#{kind}) at #{where}"
          end
        end

        def initialize(session)
          @session = session
          @markers = {}
          @waiting = Hash.new { |h, k| h[k] = [] }
          @mutex = Mutex.new
        end

        # Sets marker +name+: a timeline position +pos+ (whole notes) or a
        # time +seconds+.  Returns the Marker.  Runs blocks waiting for it
        # (see #on) if the marker's time hasn't passed.
        def set(name, kind: nil, pos: nil, seconds: nil)
          raise ArgumentError, "Marker names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, 'Give a marker pos: or seconds:, not both' if pos && seconds
          raise ArgumentError, 'Give a marker pos: or seconds:' if pos.nil? && seconds.nil?
          kind ||= seconds ? :time : :position
          raise ArgumentError, "Marker kinds are #{KINDS.map(&:inspect).join(', ')} (got #{kind.inspect})" unless KINDS.include?(kind)
          raise ArgumentError, ':time markers take seconds:' if kind == :time && seconds.nil?
          raise ArgumentError, "#{kind.inspect} markers take pos:" if kind != :time && pos.nil?

          m = Marker.new(name: name, kind: kind, pos: pos&.to_r, seconds: seconds&.to_f)
          waiting = @mutex.synchronize {
            @markers[name] = m
            pos_of(m) >= @session.now ? @waiting.delete(name) || [] : []
          }
          waiting.each { |block| block.call(m, pos_of(m)) }
          m
        end

        # The Marker named +name+, or nil.
        def [](name)
          @mutex.synchronize { @markers[name] }
        end

        # The timeline position (whole notes) of marker +name+ (or a
        # Marker), or nil if there is no such marker.
        def position(name)
          m = name.is_a?(Marker) ? name : self[name]
          m && pos_of(m)
        end

        # Removes marker +name+.  Returns it (or nil).
        def delete(name)
          @mutex.synchronize { @markers.delete(name) }
        end

        # Every marker by name (a copy).
        def to_h
          @mutex.synchronize { @markers.dup }
        end

        # Calls the block with the Marker and its position the next time
        # marker +name+ is at or after Session#now: right away if it already
        # is, else when it is next set.  Returns true if it ran right away.
        def on(name, &block)
          m = self[name]
          if m && pos_of(m) >= @session.now
            block.call(m, pos_of(m))
            true
          else
            @mutex.synchronize { @waiting[name] << block }
            false
          end
        end

        # A listing: name => "bar 9 (section)".
        def info
          to_h.transform_values { |m|
            pos = pos_of(m)
            st = @session.stamp(pos)
            m.kind == :time ? "#{m.seconds.round(3)} s = #{st} (time)" : "#{st} (#{m.kind})"
          }
        end

        private

        # A marker's timeline position (seconds converted at the current
        # tempo).
        def pos_of(m)
          m.pos || m.seconds.to_r * @session.transport.whole_notes_per_second
        end
      end
    end
  end
end

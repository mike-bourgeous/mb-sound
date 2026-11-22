module MB
  module Sound
    class Session
      # A map from Sessions to values that each Session holds itself (in
      # Session#side_data), for subsystems that keep something per Session:
      # generator track clips, hand-tune refinements.
      #
      # A WeakKeyMap keyed by the Session looks like the same thing, but its
      # values are strong references, so a value that reaches back to its
      # Session (a track clip's knobs, a refinement's @session) kept the
      # Session and everything it played alive for good (fixes-18: every
      # closed Session that had played a generator on a track).  Here the
      # value goes when its Session goes.  Not for the render thread.
      #
      #     CLIPS = Session::PerSession.new(:generator_track_clips)
      #     cache = (CLIPS[session] ||= {})
      class PerSession
        # +key+ names this map's slot in each Session's #side_data.
        def initialize(key)
          @key = key
        end

        # The value for +session+, or nil.
        def [](session)
          session.side_data[@key]
        end

        # Sets the value for +session+.
        def []=(session, value)
          session.side_data[@key] = value
        end

        # Removes and returns the value for +session+.
        def delete(session)
          session.side_data.delete(@key)
        end

        # True if +session+ has a value.
        def key?(session)
          session.side_data.key?(@key)
        end
      end
    end
  end
end

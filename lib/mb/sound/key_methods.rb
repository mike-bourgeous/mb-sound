module MB
  module Sound
    # Console methods for the session key (midi-consol-2; MusicalKey,
    # Session::KeyChanges): `key :ab` sets the root, `mode :phrygian` the
    # scale, `key :ab, :phrygian` both, and bare `key` / `mode` read them
    # back.  Changes take launch points like knob turns (right away by
    # default), work in scheduled blocks, scenes (`scene :drop, key: [:a,
    # :minor]`), and sections (`drop 8, key: :d, mode: :dorian`), and are
    # journaled and undoable.  Scale transforms (`degrees`, `snap`,
    # `lock`), `scale(:dorian)` without a root, and bare `scale` follow
    # the key.  MB::Sound extends itself with this module.
    #
    # Example (bin/sound.rb):
    #     key                      # => C major
    #     key :ab                  # Ab major
    #     mode :phrygian           # Ab phrygian
    #     key :d, :dorian, on: :bar
    #     key :lydian              # a mode name alone changes the mode
    #     scale                    # => the session's Scale (D dorian)
    module KeyMethods
      # With no arguments, returns the session key (a MusicalKey, printing
      # as "Ab phrygian").  Otherwise changes the root (+root+: :ab, 'Ab',
      # 'F#', a Note like Ab2 for its pitch class, or 0..11) and, if given,
      # the mode (+mode+: a scale name such as :dorian, :minor_pentatonic)
      # at the launch point (+on:+, +in:+, +at:+; right away by default).
      # A mode name alone (`key :lydian`) changes the mode.  Returns the
      # change's journal entry.
      def key(root = nil, mode = nil, at: nil, on: nil, in: nil)
        session = Session.current
        return session.transport.key(session.now) if root.nil? && mode.nil?

        if mode.nil? && MusicalKey.mode_name?(root)
          mode = root
          root = nil
        end
        point = LaunchPoint.of(binding) or return nil
        MusicalKey.parse_root(root) unless root.nil?
        mode = MusicalKey.check_mode(mode) unless mode.nil?
        label = "key #{[root, mode].compact.map(&:inspect).join(', ')}"
        session_command(nil, label: label, kind: :key) { |s, time|
          s.change_key(root: root, mode: mode, at: point, start_time: point.given? ? nil : time)
        }
      end

      # Locks live MIDI input and the virtual keyboard to the key (the
      # Session's input lock; MIDI::Lock::Style) by intent:
      # - :mash - every key a scale degree, flowing (black keys silent):
      #   mash anything, it's in key.
      # - :play - degrees fitted to the octave (the root on every C), black
      #   keys passing notes: play it like a keyboard in the key.
      # - :along - every key to the nearest scale note, the layout kept.
      # - :chord - every key to the current chord's tones (+from:+ a clip
      #   of chords or degrees like [1, 4, 5, 1]; extend :above).
      # - :off - keys as played.
      # Keyword overrides change one option (`lock :chord, extend: true`,
      # `lock :play, scale: :lydian`, `lock :mash, black: :passing`); the
      # style may be a param (`lock knob(:style).choose(:mash, :play)`).
      # With no arguments, returns the lock (a Style, or nil).  Recordings
      # and takes keep the notes as they sounded.  Streams have the same
      # styles: `stream.lock(:play)`.
      #
      #     key :d, :dorian; lock :play
      #     lock :chord, from: [1, 6, 4, 5], bass: :root_fifth
      #     lock :off
      def lock(style = nil, **overrides)
        session = Session.current
        return session.input_lock if style.nil? && overrides.empty?
        lock = MIDI::Lock::Style[style || :play, **overrides]
        session.input_lock = lock
        session.input_lock || MIDI::Lock::Style.new(:off)
      end

      # With no arguments, returns the session key's mode (a scale name).
      # Otherwise changes the mode to +name+ (a scale name, :dorian,
      # :phrygian, :minor_pentatonic, ...) at the launch point, keeping the
      # root (see #key).  Returns the change's journal entry.
      def mode(name = nil, at: nil, on: nil, in: nil)
        return key.mode if name.nil?
        point = LaunchPoint.of(binding) or return nil
        key(nil, name, at: point)
      end
    end
  end
end

module MB
  module Sound
    class Session
      # The gain stage of each player's strip (contract K7: fade, then
      # gain, then mute/solo, then the routes; design/notes/arrangement.md
      # "Track levels"): a player name's level is the Session knob
      # :"name/level" (a linear gain, 0..MAX_LEVEL, default 1), made the
      # first time something sets it (#level, a scene or section value, a
      # turn of the track's name, a trigger track's route), so a Session
      # that never sets a level renders as before and saves no level knobs.
      # Being a knob, a level turns at launch points and over ramps,
      # follows nodes and knobs, is journaled (:turn changes), undoable,
      # replayed by takes, saved by set documents (a `knob :"bass/level"`
      # header line), and listed by #knob_info.
      #
      # Levels belong to names like mute flags: a graph replacing :bass
      # plays at :bass's level, and an armed track's monitor (:"lead/live")
      # and a cue player (:"lead/cue") play at their track's level.  Readers
      # (`duck(:kick)`, `bus(:kick)`) hear the player after its level, before
      # its mute: a trigger track's level is how much it pumps (`level :pump,
      # 0` turns a pump off).
      module Faders
        # The highest level: +12 dB.
        MAX_LEVEL = 4.0

        # The range of every level knob.
        LEVEL_RANGE = (0.0..MAX_LEVEL).freeze

        # The name of player name +name+'s level knob (:"bass/level").
        def level_name(name)
          Name.level(name)
        end

        # The level knob of player name +name+ (or of the track whose
        # monitor or cue player it is), or nil if none was made.
        def fader(name)
          owner = Name[name].strip_owner
          level = @fader_names[owner] ||= Name.level(owner)
          @knob_lock.synchronize { @knobs[level] }
        end

        # The level knob of player name +name+, made at unity if there is
        # none (see the module comment).  Returns nil if the name is taken
        # by something else (after MB::Sound.live_error).
        def fader!(name)
          raise ArgumentError, "Player names must be Symbols or Integers (got #{name.inspect})" unless name.is_a?(Symbol) || name.is_a?(Integer)
          fader(name) || knob(level_name(Name[name].strip_owner), 1.0, range: LEVEL_RANGE)
        end

        # Sets player name +name+'s level (see the module comment) to
        # +value+: a linear gain (`-6.db`, 0.5, 0 for silence, up to
        # MAX_LEVEL), a knob name, or a node to follow; right away with a
        # short glide, at a launch point (+on:+, +in:+, +at:+), or over
        # +over:+ (a ramp, shaped by +curve:+, from where it is or +from:+).
        # Without a value, returns the level as a Decibels (0.db when none
        # was set).  Returns the :turn Change otherwise.
        def level(name, value = nil, at: nil, on: nil, in: nil, over: nil, curve: nil, from: nil, smooth: nil, start_time: nil)
          if value.nil?
            k = fader(name)
            return level_db(k ? k.value.to_f : 1.0)
          end
          point = LaunchPoint.of(binding) or return nil
          check_level_value(value)
          k = fader!(name) or return nil
          turn(k.name, value, at: point, over: over, curve: curve, from: from, smooth: smooth, start_time: start_time)
        end

        # The levels that were set: player name => Decibels (a held value,
        # or where a ramp or follow is now).
        def levels
          @knob_lock.synchronize { @knobs.dup }.each_with_object({}) { |(n, k), h|
            nm = Name[n]
            h[nm.owner] = level_db(k.value.to_f) if nm.level?
          }
        end

        private

        # Linear gain +g+ as Decibels (to 0.01 dB; -Infinity.db for 0).
        def level_db(g)
          MB::Sound::Decibels.new(g > 0 ? (20 * Math.log10(g)).round(2) : -Float::INFINITY)
        end

        def init_faders
          @fader_names = {} # player name => its level knob's name (built once)
        end

        def check_level_value(value)
          case value
          when Numeric
            unless value.real? && value.finite? && value >= 0
              raise ArgumentError, "Levels are linear gains from 0 to #{MAX_LEVEL.round} (write -6.db for -6 dB; got #{value.inspect})"
            end
          when Symbol
            knob!(value)
          else
            raise ArgumentError, "A level is a gain (e.g. -6.db), a knob name, or a node (got #{value.inspect})" unless value.respond_to?(:sample) && value.respond_to?(:get_sampler)
          end
        end

        # Player +p+'s level over the frames [+frame+, +frame+ + +frames+):
        # nil at unity (or with no level knob), else a frozen SFloat.
        def fader_levels(p, frame, frames)
          k = fader(p.name) or return nil
          v = k.read(frame, frames)
          if v.is_a?(Numeric)
            return nil if v == 1
            return Numo::SFloat.new(frames).fill(v)
          end
          v.is_a?(Numo::SFloat) ? v : Numo::SFloat.cast(v)
        end
      end
    end
  end
end

module MB
  module Sound
    module UI
      class Keyboard
        # Tells presses from autorepeats for terminals that send no key
        # releases (legacy encoding): a held key sends one press, then
        # after the OS repeat delay (X11 660 ms, GNOME 500 ms, macOS often
        # 375 ms or less) a press every repeat interval (25-40 ms); a key
        # released sends nothing.  So a key counts as held while its
        # repeats keep coming, and as released a little after they stop.
        #
        # - A key's second event sooner than 0.6 of the repeat delay is a
        #   new strike (a person tapping), later ones are repeats; the
        #   delay and interval are learned from the repeats seen (starting
        #   at DELAY and INTERVAL).
        # - Deadlines (#deadlines): until the first repeat, the delay plus
        #   FIRST_SLACK after the press (so a tap sounds about that long);
        #   after a repeat, 2.5 intervals plus REPEAT_SLACK after it.
        # - Operating systems repeat only the last key pressed, so keys
        #   pressed within CHORD seconds of each other form a chord that
        #   holds as long as any of them repeats.
        #
        # Only the times of key events count (no wall clock), so specs
        # drive it with made-up times.
        class HoldTracker
          # Repeat delay and interval (seconds) assumed until measured.
          DELAY = 0.5
          INTERVAL = 0.035

          # Extra time after the expected first repeat, and after a repeat.
          FIRST_SLACK = 0.12
          REPEAT_SLACK = 0.03

          # Keys pressed within this many seconds hold together.
          CHORD = 0.06

          # The repeat delay and interval (learned).
          attr_reader :delay, :interval

          def initialize(delay: DELAY, interval: INTERVAL)
            @delay = delay
            @interval = interval
            @keys = {}
            @group = 0
          end

          # A key event for +key+ at +now+: :new (a first press), :strike
          # (pressed again before it could be a repeat), or :repeat.
          # +repeat: true+ when the terminal says it is a repeat.
          def press(key, now, repeat: false)
            s = @keys[key]
            s = nil if s && now > expires(s)
            if s.nil?
              @keys[key] = { at: now, last: now, repeats: 0, group: group_for(now) }
              return :new
            end

            dt = now - s[:last]
            if !repeat && s[:repeats] == 0 && dt < @delay * 0.6
              s[:at] = s[:last] = now
              return :strike
            end

            learn(s, dt)
            s[:repeats] += 1
            s[:last] = now
            :repeat
          end

          # When each of +keys+ should end ({key => time}), chords taking
          # their latest member's time.
          def deadlines(keys)
            times = {}
            groups = Hash.new(-Float::INFINITY)
            keys.each do |k|
              s = @keys[k] or next
              t = expires(s)
              times[k] = t
              groups[s[:group]] = t if t > groups[s[:group]]
            end
            times.to_h { |k, _| [k, groups[@keys[k][:group]]] }
          end

          # Forgets every key.
          def clear
            @keys.clear
          end

          private

          # The time after which +s+'s key counts as released.
          def expires(s)
            s[:repeats] == 0 ? s[:at] + @delay + FIRST_SLACK : s[:last] + @interval * 2.5 + REPEAT_SLACK
          end

          # Joins a chord of keys pressed within CHORD seconds (not yet
          # repeating), else starts a group.
          def group_for(now)
            near = @keys.each_value.find { |s| s[:repeats] == 0 && (now - s[:at]).abs <= CHORD }
            near ? near[:group] : (@group += 1)
          end

          # Follows the OS's repeat timing from the gaps between events.
          def learn(s, dt)
            if s[:repeats] == 0
              @delay = (@delay * 0.5 + dt * 0.5).clamp(0.15, 1.0) if dt.between?(0.15, 1.2)
            elsif dt.between?(0.008, 0.2)
              @interval = (@interval * 0.8 + dt * 0.2).clamp(0.008, 0.2)
            end
          end
        end
      end
    end
  end
end

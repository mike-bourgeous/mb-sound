module MB
  module Sound
    module UI
      class Keyboard
        # Tells presses from autorepeats for terminals that send no key
        # releases (legacy encoding): a held key sends one press, then
        # after the OS repeat delay (X11 660 ms, KDE 600 ms, GNOME 500 ms,
        # macOS often 375 ms or less, many vim users 200-300 ms) a press
        # every repeat interval (25-40 ms); a key released sends nothing.
        #
        # Each key is a small state machine (STATES, TRANSITIONS; specs
        # walk every pair):
        #
        # - :idle (no record, or its time ran out) --press--> :pressed
        #   (returns :new)
        # - :pressed --press after a short gap (<= #repeat_gap: no person
        #   strikes one key that fast) or about the learned repeat delay
        #   (within #tolerance)--> :repeating (:repeat); any other gap is a
        #   new strike, staying :pressed (:strike)
        # - :repeating --press after a short gap--> :repeating (:repeat);
        #   a longer gap --> :pressed (:strike)
        # - any --terminal-reported repeat (kitty)--> :repeating (:repeat)
        #
        # Learning: the interval from repeats; the delay from the gap
        # before the first repeat, including retroactively: a press counted
        # as a strike (or a new press soon after the key's last event) that
        # is followed by a short-gap repeat was the OS delay all along, so
        # the next hold is recognized (Konsole, ux-1 round 3 item 9: with
        # delays outside the old fixed window every repeat looked like a
        # strike and retriggered, in every note-off mode).
        #
        # Deadlines (#deadlines): until the first repeat, the delay plus
        # FIRST_SLACK after the press; after a repeat, 2.5 intervals plus
        # REPEAT_SLACK after it.  Operating systems repeat only the last key
        # pressed, so keys pressed within CHORD seconds of each other form a
        # chord that holds as long as any of them repeats.
        #
        # Only the times of key events count (no wall clock), so specs
        # drive it with made-up times.
        class HoldTracker
          # Repeat delay and interval (seconds) assumed until measured
          # (between GNOME's 500 ms and KDE's 600 ms).
          DELAY = 0.55
          INTERVAL = 0.035

          # How far from the delay a first repeat may arrive: before the
          # delay is learned (covers 470-630 ms), and after.
          TOLERANCE = 0.08
          LEARNED_TOLERANCE = 0.04

          # Gaps at most this long are always repeats (about 11 per second:
          # faster than anyone re-strikes one key).
          REPEAT_GAP = 0.09

          # Extra time after the expected first repeat, and after a repeat.
          FIRST_SLACK = 0.12
          REPEAT_SLACK = 0.03

          # Keys pressed within this many seconds hold together.
          CHORD = 0.06

          # Gaps longer than this are never a repeat delay.
          MAX_DELAY = 1.2

          # Per-key states and what a press does in each ([result, next]).
          STATES = %i[idle pressed repeating].freeze
          TRANSITIONS = {
            [:idle, :press] => %i[new pressed],
            [:pressed, :short_gap] => %i[repeat repeating],
            [:pressed, :delay_gap] => %i[repeat repeating],
            [:pressed, :other_gap] => %i[strike pressed],
            [:pressed, :reported_repeat] => %i[repeat repeating],
            [:repeating, :short_gap] => %i[repeat repeating],
            [:repeating, :delay_gap] => %i[strike pressed],
            [:repeating, :other_gap] => %i[strike pressed],
            [:repeating, :reported_repeat] => %i[repeat repeating],
            [:idle, :reported_repeat] => %i[repeat repeating],
          }.freeze

          # The repeat delay and interval (learned).
          attr_reader :delay, :interval

          # True once the delay was measured from a repeat.
          def learned? = @learned

          def initialize(delay: DELAY, interval: INTERVAL)
            @delay = delay
            @interval = interval
            @learned = false
            @keys = {}
            @group = 0
          end

          # Sets the repeat delay (seconds) outright, as learned.
          def delay=(seconds)
            @delay = seconds.to_f
            @learned = true
          end

          # Gaps at most this long are repeats.
          def repeat_gap = [REPEAT_GAP, @interval * 1.8].max

          # How far from the delay a first repeat may come.
          def tolerance = @learned ? LEARNED_TOLERANCE : TOLERANCE

          # The state of +key+ at +now+ (:idle, :pressed, :repeating).
          def state(key, now)
            s = @keys[key]
            s.nil? || now > expires(s) ? :idle : s[:state]
          end

          # A key event for +key+ at +now+: :new (a first press), :strike
          # (pressed again, not a repeat), or :repeat.  +repeat: true+ when
          # the terminal says it is a repeat.
          def press(key, now, repeat: false)
            s = @keys[key]
            state = s.nil? || now > expires(s) ? :idle : s[:state]
            gap = s && now - s[:last]
            event = classify(state, gap, repeat)
            result, nxt = TRANSITIONS.fetch([state, event])

            case result
            when :new
              # (a key struck again soon after its record ran out: that gap
              # may still turn out to be the repeat delay)
              @keys[key] = { state: nxt, at: now, last: now, repeats: 0, group: group_for(now), maybe_delay: gap && gap <= MAX_DELAY ? gap : nil }
            when :strike
              s.merge!(state: nxt, at: now, last: now, repeats: 0, maybe_delay: gap <= MAX_DELAY ? gap : nil)
            when :repeat
              s ||= (@keys[key] = { state: nxt, at: now, last: now, repeats: 0, group: group_for(now), maybe_delay: nil })
              learn(s, gap, event) if gap
              s[:state] = nxt
              s[:repeats] += 1
              s[:last] = now
              s[:maybe_delay] = nil
            end
            result
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

          # The event class of a press in +state+ after +gap+ seconds.
          def classify(state, gap, reported)
            return :reported_repeat if reported
            return :press if state == :idle
            return :short_gap if gap <= repeat_gap
            return :delay_gap if (gap - @delay).abs <= tolerance
            :other_gap
          end

          # The time after which +s+'s key counts as released.
          def expires(s)
            if s[:state] == :pressed
              s[:at] + @delay + [FIRST_SLACK, tolerance].max
            else
              s[:last] + @interval * 2.5 + REPEAT_SLACK
            end
          end

          # Joins a chord of keys pressed within CHORD seconds (not yet
          # repeating), else starts a group.
          def group_for(now)
            near = @keys.each_value.find { |s| s[:repeats] == 0 && (now - s[:at]).abs <= CHORD }
            near ? near[:group] : (@group += 1)
          end

          # Follows the OS's repeat timing from the gaps between events.
          def learn(s, gap, event)
            if s[:repeats] == 0 && event == :delay_gap
              learn_delay(gap)
            elsif s[:repeats] == 0 && s[:maybe_delay]
              # The press before this short-gap repeat was the OS's first repeat
              learn_delay(s[:maybe_delay])
            end
            @interval = (@interval * 0.8 + gap * 0.2).clamp(0.008, 0.2) if event == :short_gap && s[:repeats] > 0 && gap.between?(0.008, 0.2)
          end

          def learn_delay(gap)
            return unless gap.between?(0.15, MAX_DELAY)
            @delay = @learned ? (@delay * 0.5 + gap * 0.5) : gap
            @learned = true
          end
        end
      end
    end
  end
end

module MB
  module Sound
    module UI
      # Turning knobs from a pane's keys (the racks pane since ux-r4b, the
      # inspector since sound-design-ui-1; one implementation, so both turn
      # alike): a held turn key is a live sweep (PaneKeys::Preview, the
      # screen's Session#preview_turn) and ONE journaled console line when
      # the keys stop (PaneKeys::Commit, Session#gesture_line), through a
      # UI::TurnGesture; a set value is one `turn :name, value` line
      # (PaneKeys::Run).  The value a key set stands in for the knob for
      # PENDING seconds, until the snapshot catches up.
      #
      # A pane including it defines `picked(state)`: the knob its keys
      # turn as [knob name, KnobValue] (from the snapshot it drew), or nil.
      # Its class gets a settable clock (monotonic seconds; specs set their
      # own).
      module KnobTurns
        # Position steps of a turn: coarse and fine (Shift).
        STEP = 0.02
        FINE = 0.002

        # Seconds a turned value is used over the snapshot's, until the
        # snapshot catches up.
        PENDING = 0.6

        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          attr_writer :clock

          # The gestures' clock.
          def clock = @clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        end

        # The value one turn by +step+ (a position step: STEP, FINE, or
        # their negatives) gives a knob at +value+ with Knob::Spec +spec+:
        # +step+ along the knob's curve (so a cutoff moves evenly in pitch),
        # within the range; stepped knobs (Integer ranges) move one step.
        def self.turned(spec, value, step)
          param = spec.respond_to?(:param) ? spec.param : nil
          if param.respond_to?(:stepped?) && param.stepped?
            return (value.to_f.round + (step <=> 0)).clamp(spec.range.begin, spec.range.end).to_f
          end
          Float(TurnGesture.number(spec.clamp(spec.value((spec.position(value) + step).clamp(0.0, 1.0)))))
        end

        # A turn key: starts or extends the gesture on the picked knob
        # (another knob's gesture goes out first) with a live Preview;
        # its Commit comes from #key_tick when the keys stop (or #flush).
        def key_turn(state, step)
          cell = picked(state) or return no_knob_note
          kn, k = cell
          now = self.class.clock.call
          g = (state[:gesture] ||= TurnGesture.new)
          out = g.turning? && g.knob != kn ? flush(state) : nil
          v = g.turning? ? g.value : (pending(state, kn) || k.value)
          [*out, g.step(kn, v, KnobTurns.turned(k.spec, v, step), now)]
        end

        # The picked knob back to its default (one `turn` line).
        def key_reset(state)
          cell = picked(state) or return no_knob_note
          kn, k = cell
          [*flush(state), set(state, kn, k.spec.default)]
        end

        # Time passes (the screen calls it while #key_wait says so): the
        # gesture's Commit once its keys stopped, else nil.
        def key_tick(state)
          g = state[:gesture] or return nil
          run = g.tick(self.class.clock.call)
          remember(state, g) if run
          run
        end

        # Seconds until #key_tick has a Commit, or nil.
        def key_wait(state) = state[:gesture]&.wait(self.class.clock.call)

        # The screen ran the lines a key or #tick returned.
        def lines_ran(state)
          state[:gesture]&.ran
        end

        # The value to show for knob +kn+ (KnobValue +k+): a turning
        # gesture's target, else a value a key just set, else the
        # snapshot's.  Returns [value, turning?].
        def shown_value(state, kn, k)
          g = state[:gesture]
          return [g.value, true] if g&.turning? && g.knob == kn
          [pending(state, kn) || k&.value, false]
        end

        private

        def no_knob_note = 'no knob to turn here'

        # The gesture's Commit now (another key), as an Array (empty
        # without one).
        def flush(state)
          g = state[:gesture] or return []
          run = g.flush(self.class.clock.call) or return []
          remember(state, g)
          [run]
        end

        # The gesture's last value stands in for the knob until the
        # snapshot catches up.
        def remember(state, g)
          (state[:pending] ||= {})[g.knob] = [g.value, self.class.clock.call]
        end

        # A `turn` line setting knob +kn+ to +value+.
        def set(state, kn, value)
          (state[:pending] ||= {})[kn] = [value, self.class.clock.call]
          v = TurnGesture.number(value)
          PaneKeys::Run["turn #{kn.inspect}, #{v}", "#{kn} #{v}"]
        end

        def pending(state, kn)
          v, at = state[:pending]&.[](kn)
          v if at && self.class.clock.call - at < PENDING
        end
      end
    end
  end
end

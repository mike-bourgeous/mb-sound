require 'prism'

module MB
  module Sound
    module UI
      # Turning knobs from a pane's keys (the racks pane since ux-r4b, the
      # inspector since sound-design-ui-1, the knobs pane since
      # knobs-pane-keys-1; one implementation, so all turn alike): a held
      # turn key is a live sweep (PaneKeys::Preview, the screen's
      # Session#preview_turn) and ONE journaled console line when
      # the keys stop (PaneKeys::Commit, Session#gesture_line), through a
      # UI::TurnGesture; a set value (0: the default; Enter: a typed one,
      # #key_ask) is one `turn :name, value` line (PaneKeys::Turn).  The
      # value a key set stands in for the knob for PENDING seconds, until
      # the snapshot catches up (UI::CarriedValues).  Turn lines never
      # print in the REPL pane: the latest shows on the pane's last row
      # (#turn_line_canvas; inspector-headers-1).
      #
      # A pane including it defines `picked(state)`: the knob its keys
      # turn as [knob name, KnobValue] (from the snapshot it drew), or nil.
      # Its class gets a settable clock (monotonic seconds; specs set their
      # own), and the carried values of UI::CarriedValues.
      module KnobTurns
        include CarriedValues

        # Position steps of a turn: coarse and fine (Shift).
        STEP = 0.02
        FINE = 0.002

        # Seconds a turned value is used over the snapshot's, until the
        # snapshot catches up (CarriedValues::PENDING).
        PENDING = CarriedValues::PENDING

        def self.included(base)
          base.extend(CarriedValues::ClassMethods)
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

        # Enter: type the picked knob's value (a prompt line starting with
        # its value, selected so typing replaces it); #key_typed runs it.
        def key_ask(state)
          cell = picked(state) or return no_knob_note
          kn, k = cell
          value, = shown_value(state, kn, k)
          [*flush(state), PaneKeys::Ask["turn #{kn.inspect}, ", TurnGesture.number(value), :typed, select: true]]
        end

        # The typed answer to #key_ask: one `turn` line with it (Ruby:
        # 3000, 3000.hz, -6.db).
        def key_typed(state, text)
          cell = picked(state) or return no_knob_note
          text = text.to_s.strip
          return 'nothing typed' if text.empty?
          problem = KnobTurns.typed_problem(text) and return "#{cell[0]}: #{problem}"
          PaneKeys::Turn["turn #{cell[0].inspect}, #{text}", "#{cell[0]} #{text}"]
        end

        # What fits the value prompt, for its messages.
        TYPED_FITS = 'type a number (3000), a value with its unit (3000.hz, -6.db, 250.ms, 1.bars), or a knob\'s name to follow (:mix)'

        # Why +text+ typed into the value prompt can't be a turn's value,
        # or nil (sd-ux-fixes-1, the review's #15: junk gave a raw
        # NameError "for module MB::Sound" or a SyntaxError "(eval at
        # take.rb:267)"): read with Prism, never run.  Numbers, numbers
        # with a unit method, Symbols, and other expressions pass; a
        # syntax error, several statements, a number method that doesn't
        # exist, or a bare name the console doesn't know get words.
        def self.typed_problem(text)
          r = Prism.parse(text)
          return "#{text.inspect} isn't a value (#{r.errors.first.message}); #{TYPED_FITS}" unless r.errors.empty?
          body = r.value.statements&.body || []
          return "#{text.inspect} is #{body.length} statements; #{TYPED_FITS}" unless body.length == 1
          node = body[0]
          case node
          when Prism::CallNode
            recv = node.receiver
            if recv.nil? && node.arguments.nil? && node.block.nil?
              return nil if MB::Sound.respond_to?(node.name)
              return "#{node.name} isn't a console command or value; #{TYPED_FITS}"
            end
            number = recv.is_a?(Prism::IntegerNode) || recv.is_a?(Prism::FloatNode) || recv.is_a?(Prism::RationalNode)
            if number && node.arguments.nil? && !1.respond_to?(node.name)
              near = DidYouMean::SpellChecker.new(dictionary: UNIT_WORDS).correct(node.name.to_s).first
              return "numbers have no .#{node.name}#{" (did you mean .#{near}?)" if near}; #{TYPED_FITS}"
            end
          when Prism::ConstantReadNode
            # (note names like C4 come from const_missing)
            known = begin
              MB::Sound.const_get(node.name)
              true
            rescue NameError
              false
            end
            return "#{node.name} isn't a constant of the console; #{TYPED_FITS}" unless known
          when Prism::StringNode, Prism::InterpolatedStringNode, Prism::ArrayNode, Prism::HashNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode
            return "#{text} isn't a number; #{TYPED_FITS}"
          end
          nil
        end

        # Unit words on numbers, for #typed_problem's did-you-mean.
        UNIT_WORDS = %w[hz khz db ms seconds samples bars beats cents semitones cycles bpm n1 n2 n4 n8 n16 n32 st oct].freeze

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

        # Rows a pane needs before its last one shows the turn line.
        TURN_LINE_ROWS = 4

        # The latest turn's line (the screen's `state[:turn_line]`, one
        # line, replaced on every turn) on +c+'s last row, dim, when there
        # is one and room; returns the canvas for the rest of the pane.
        def turn_line_canvas(c, state)
          line = state[:turn_line]
          return c if line.nil? || c.h < TURN_LINE_ROWS
          c.text(0, c.h - 1, c.fit(line, c.w), :dim)
          c.sub(0, 0, c.w, c.h - 1)
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
        def remember(state, g) = carry(state, g.knob, g.value)

        # A `turn` line setting knob +kn+ to +value+.
        def set(state, kn, value)
          carry(state, kn, value)
          v = TurnGesture.number(value)
          PaneKeys::Turn["turn #{kn.inspect}, #{v}", "#{kn} #{v}"]
        end

        def pending(state, kn) = carried(state, kn)
      end
    end
  end
end

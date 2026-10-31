module MB
  module Sound
    module Generative
      # A Markov chain over section names (or any Symbols) for long forms
      # (G4; console MB::Sound#markov): each state names the states that
      # may follow it with weights, and every draw is counter-based (Dice
      # over the seed and the draw's number), so the chain is a pure
      # function of its seed: draw 517 comes out the same computed cold
      # or after draws 0..516.
      #
      #     moods = markov(still: { drift: 3, hush: 1 }, drift: { bloom: 3, still: 1 },
      #                    bloom: { hush: 2, drift: 1 }, hush: { still: 1 }, seed: 7)
      #     moods.take(8)                  # => [:still, :drift, :bloom, ...]
      #     moods.flow(still: 6, drift: 8, bloom: 8, hush: 4)   # an endless flow
      #     moods.flow({ still: 6, ... }, sections: 12)         # the first 12, written out
      #
      # - Order 2: rules keyed by pairs `[before, state] => { ... }` win over
      #   the state's own rule when the chain came from +before+:
      #   `markov(a: { b: 1, c: 1 }, [:b, :a] => { c: 1 })`.
      # - Ends: a state with an empty rule (`outro: {}`) ends the chain; the
      #   next draw starts over at +start+ (so a flow that comes back to
      #   the chain plays a new song).  States must have a rule (or a pair
      #   rule ending with them).
      # - Steering (G3's decision points): weights may be moving params
      #   (`drift: { bloom: knob(:motion), still: 1 }`), read where a form
      #   decides the next section (its commit point: the start of the
      #   section's fill, else its end), so a turn before the commit point
      #   steers it and takes replay it.  A steered chain depends on the
      #   values it read, so #take and #flow with +sections:+ (which decide
      #   ahead) read the params' current values.
      #
      # Rules named like the options (:start, :seed) go in a Hash first:
      # `markov({ start: { a: 1 }, a: { start: 1 } }, start: :start)`.
      class Markov
        # The rules (frozen): state or [before, state] => { state => weight }.
        attr_reader :rules

        # The first state, the seed, and the order (1, or 2 with pair rules).
        attr_reader :start, :seed, :order

        # The most states #take returns, and the longest chain #[] walks.
        LIMIT = 1_000_000

        def initialize(rules, start: nil, seed:)
          raise ArgumentError, 'markov needs rules (state: { next_state: weight, ... })' unless rules.is_a?(Hash) && !rules.empty?
          @rules = rules.to_h { |k, v| [k.is_a?(Array) ? k.dup.freeze : k, check_rule(k, v)] }.freeze
          @order = @rules.keys.any?(Array) ? 2 : 1
          @start = start || @rules.keys.find { |k| k.is_a?(Symbol) } || @rules.keys.first.last
          @seed = Integer(seed)
          @steered = @rules.values.any? { |r| r.values.any? { |w| MIDI::Param.param?(w) } }
          check_states
          @walk = []
          @walk_tail = nil
          @finish_distances = nil
          @lock = Mutex.new
        end

        # The same chain with another seed.
        def reseed(seed)
          Markov.new(@rules, start: @start, seed: seed)
        end

        # True if a weight is a moving param (see the class comment).
        def steered?
          @steered
        end

        # Every state the chain may reach (rule keys and targets), in first
        # appearance order.
        def states
          @states ||= (@rules.keys.map { |k| k.is_a?(Array) ? k.last : k } + @rules.values.flat_map(&:keys) + [@start]).uniq.freeze
        end

        # True for states whose rule is empty (they end the chain).
        def terminal?(state)
          (r = @rules[state]) && r.empty?
        end

        # The first +count+ states (restarting at +start+ after an end).
        def take(count)
          draws(count).map(&:first)
        end

        # The first +count+ states with the number of the draw that gave
        # each ([state, n]; ends take a draw too): the numbers a flow's
        # generate step keys their lengths by.
        def draws(count)
          count = Integer(count)
          raise ArgumentError, "markov: at most #{LIMIT} states (got #{count})" if count > LIMIT
          self[count - 1] if count > 0
          @lock.synchronize { @walk.first(count) }
        end

        # State +n+ (from 0, the start), counting only states (not ends).
        # Memoized: a cold n walks the chain once (about 1 us a state).
        def [](n)
          n = Integer(n)
          raise ArgumentError, "markov#[]: n from 0 to #{LIMIT - 1} (got #{n})" if n < 0 || n >= LIMIT
          @lock.synchronize {
            draws, tail = @walk_tail || [0, form_start]
            while @walk.length <= n
              name, tail = form_next(tail, draws, ->(w) { MIDI::Param.peek { ValueSource.value_at(w, now) } })
              draws += 1
              @walk << [name, draws - 1].freeze if name
            end
            @walk_tail = [draws, tail]
            @walk[n][0]
          }
        end

        # A flow of the chain's states: with +sections:+ the first that many
        # written out (a Form to edit or play), else one `generate` step that
        # decides each next section as the flow plays (endless unless the
        # chain ends; +loop: true+ starts it over after an end, forever).
        # +bars+ (or keywords) gives each state's length: bars, a Duration,
        # a Range of bars or an Array drawn per occurrence (seeded).
        # +length:+ (bars) bounds each run of the chain: past it the chain
        # heads for its end the shortest way (#form_finish).
        def flow(bars = {}, sections: nil, loop: false, length: nil, **more)
          lengths = bars.merge(more)
          source = self
          if sections
            raise ArgumentError, 'markov#flow: length: bounds a generated flow; sections: writes the first sections out (give one)' if length
            Form.linear(draws(sections), lengths, seed: @seed)
          elsif loop
            Form.build { label :top; generate source, bars: lengths, length: length; goto :top }
          else
            Form.build { generate source, bars: lengths, length: length }
          end
        end

        ### The form source protocol (Form::Generate)

        # The chain before its first draw.
        def form_start
          [nil, nil].freeze
        end

        # The names Form::Generate may get (for checks).
        def form_states
          states
        end

        # False: every state is a section.
        def nonterminal?(_name)
          false
        end

        # Draw +n+ from +tail+ ([before, state]; [nil, nil] before the
        # first): the next state and the new tail, or [nil, start tail] at
        # an end (the chain starts over at the next draw).  +read+ reads
        # moving weights.
        def form_next(tail, n, read)
          before, state = tail
          return [@start, [nil, @start].freeze] if state.nil?

          rule = (@order == 2 && @rules[[before, state]]) || @rules[state]
          raise ArgumentError, "markov: no rule for #{state.inspect}#{before ? " (after #{before.inspect})" : ''}" if rule.nil?
          return [nil, form_start] if rule.empty?

          weights = steered? ? rule.transform_values { |w| read.call(w).to_f } : rule
          weights = weights.transform_values { |w| w.to_f.negative? ? 0.0 : w } if steered?
          # (a steered rule whose weights are all turned to zero ends the chain)
          return [nil, form_start] if weights.values.sum.zero?
          nxt = Dice.new(@seed, :markov).pick(weights, n)
          [nxt, [state, nxt].freeze]
        end

        # Draw +n+ like #form_next, heading for the chain's end by the
        # shortest way (a generate step's +length:+ bound, gen-midi-2):
        # among the next states with a weight above zero, only those
        # closest to an end (or, for a chain with no end, to drawing
        # +start+ again: the arch restarting) are drawn, by their weights.
        # A tail already one draw from its end ends (or draws +start+).
        def form_finish(tail, n, read)
          before, state = tail
          return form_next(tail, n, read) if state.nil?

          dist = finish_distances
          d = dist[tail]
          return form_next(tail, n, read) if d.nil? # (no way out from here)
          return [@start, [state, @start].freeze] if d == 0 && !ends?

          rule = (@order == 2 && @rules[[before, state]]) || @rules[state]
          return [nil, form_start] if rule.empty?

          weights = steered? ? rule.transform_values { |w| read.call(w).to_f } : rule
          weights = weights.select { |_, w| w.to_f > 0 }
          return [nil, form_start] if weights.empty?
          best = weights.keys.map { |x| dist[[state, x]] }.compact.min
          return form_next(tail, n, read) if best.nil?
          weights = weights.select { |x, _| dist[[state, x]] == best }
          nxt = Dice.new(@seed, :markov).pick(weights, n)
          [nxt, [state, nxt].freeze]
        end

        # True if +tail+ (after a draw) starts the chain's arc over, for a
        # chain with no end: the draw gave +start+ (a generate step's
        # +length:+ counts from there; a chain with an end counts from it).
        def form_restart?(tail)
          !ends? && tail[1] == @start
        end

        # True if the chain has an end (a state whose rule is empty).
        def ends?
          @rules.values.any?(&:empty?)
        end

        # The tail after the form forced +name+ (a performer's `goto` to a
        # generated section): the chain carries on from there.
        def form_force(tail, name)
          [tail[1], name].freeze
        end

        # Ruby that builds this chain again.
        def to_ruby(&value_text)
          # (moving weights print as the expression that made them: knob(:x))
          value_text ||= ->(v) { MIDI::Param.label(v) }
          reserved = @rules.keys.any? { |k| !k.is_a?(Symbol) || %i[start seed].include?(k) }
          rule = ->(h) { h.empty? ? '{}' : "{ #{h.map { |k, w| "#{k}: #{w.is_a?(Numeric) ? Form.ruby_value(w) : value_text.call(w)}" }.join(', ')} }" }
          body = if reserved
                   "{ #{@rules.map { |k, v| "#{k.inspect} => #{rule.(v)}" }.join(', ')} }"
                 else
                   @rules.map { |k, v| "#{k}: #{rule.(v)}" }.join(', ')
                 end
          start = @start == @rules.keys.find { |k| k.is_a?(Symbol) } ? '' : ", start: #{@start.inspect}"
          "markov(#{body}#{start}, seed: #{@seed})"
        end
        alias to_s to_ruby

        def inspect
          "#<Markov #{to_ruby}>"
        end

        def ==(other)
          other.is_a?(Markov) && other.to_ruby == to_ruby
        end
        alias eql? ==

        def hash
          to_ruby.hash
        end

        private

        # Tail ([before, state]) => draws to the chain's end (0: the next
        # draw ends it), for tails reachable from the start; a chain with
        # no end counts to drawing +start+ again (0: the next draw may).
        # Moving weights count as edges; zero weights don't.
        def finish_distances
          @finish_distances ||= begin
            rule_of = ->(t) { (@order == 2 && @rules[t]) || @rules[t[1]] }
            nexts = ->(t) { rule_of.(t).select { |_, w| MIDI::Param.param?(w) || w > 0 }.keys.map { |x| [t[1], x].freeze } }
            tails = [[nil, @start].freeze]
            seen = { tails[0] => true }
            tails.each { |t| nexts.(t).each { |u| next if seen[u]; seen[u] = true; tails << u } }
            target = ends? ? ->(t) { rule_of.(t).empty? } : ->(t) { nexts.(t).any? { |u| u[1] == @start } }
            dist = {}
            tails.each { |t| dist[t] = 0 if target.(t) }
            loop do
              changed = false
              tails.each do |t|
                next if dist.key?(t) && dist[t] == 0
                best = nexts.(t).map { |u| dist[u] }.compact.min
                next if best.nil? || (dist.key?(t) && dist[t] <= best + 1)
                dist[t] = best + 1
                changed = true
              end
              break unless changed
            end
            dist.freeze
          end
        end

        # The timeline position params are read at outside a form (the
        # default transport's).
        def now
          Sequence.current_transport.position
        rescue StandardError
          0
        end

        def check_rule(key, rule)
          unless key.is_a?(Symbol) || (key.is_a?(Array) && key.length == 2 && key.all?(Symbol))
            raise ArgumentError, "markov: rules are keyed by states (Symbols) or [before, state] pairs (got #{key.inspect})"
          end
          raise ArgumentError, "markov: #{key.inspect} => needs a Hash of next states and weights (got #{rule.inspect})" unless rule.is_a?(Hash)
          rule.each do |s, w|
            raise ArgumentError, "markov: next states are Symbols (got #{s.inspect} after #{key.inspect})" unless s.is_a?(Symbol)
            next if MIDI::Param.param?(w)
            unless w.is_a?(Numeric) && w.real? && w >= 0
              raise ArgumentError, "markov: weights are numbers of at least 0 or moving params like knob(:x) (got #{w.inspect} for #{key.inspect} => #{s.inspect})"
            end
          end
          if !rule.empty? && rule.values.none? { |w| MIDI::Param.param?(w) } && rule.values.sum.zero?
            raise ArgumentError, "markov: every weight after #{key.inspect} is zero (write #{key.inspect} => {} for an end)"
          end
          rule.dup.freeze
        end

        # Every state the chain may reach needs a rule (its own, or a pair
        # rule ending with it).
        def check_states
          ruled = @rules.keys.map { |k| k.is_a?(Array) ? k.last : k }
          missing = states - ruled
          return if missing.empty?
          hint = Form.suggest(missing.first, ruled.uniq)
          raise ArgumentError, "markov: no rule for #{missing.map(&:inspect).join(', ')} (give each state its next states, or {} to end the chain)#{hint}"
        end
      end
    end
  end
end

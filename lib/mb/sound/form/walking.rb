module MB
  module Sound
    class Form
      # A decision inside a form: the section that plays next (+section+ at
      # instruction +index+ of the form's program, pass +pass+; nil section
      # for the end), the goto and generate counts after getting there
      # (+counters+, adopted when the pass starts, so a re-decided commit
      # starts from the same counts), the +labels+ passed, and the pass's
      # +length+ and +times+ (a play's, or a generated section's).
      Step = Data.define(:index, :section, :pass, :counters, :labels, :length, :times) do
        def initialize(index:, section:, pass:, counters:, labels:, length: nil, times: nil)
          super
        end
      end

      # How a form decides what follows a pass: the walk from an
      # instruction through labels, gotos, picks, jumps, and generate steps
      # to the next section.  Shared by Playback (live, at commit points)
      # and Plan (the same decisions simulated ahead, for cold seeks), so
      # both make the same choices.  Includers set @program, @form, @seed,
      # @counters, @history (section names played, the current pass's
      # included), and @transport, and define #state_unlocked.
      module Walking
        # The most instructions one decision follows before giving up (a
        # loop of gotos and picks that never reaches a section).
        WALK_LIMIT = 10_000

        private

        # Follows the program from instruction +i+ (through labels, gotos,
        # picks, jumps, and generate steps) to the next section, returning
        # a Step.  Gotos and generate steps count in a copy of the counters;
        # chance draws from one generator per decision; moving params of a
        # steered source are read at timeline position +time+.  With
        # +peek+, returns nil instead of drawing random numbers, calling
        # Procs, or reading params (for previews).
        def walk(i, peek: false, time: nil)
          counters = @counters.dup
          labels = []
          rng = nil
          WALK_LIMIT.times do
            ins = @program[i]
            return Step.new(index: nil, section: nil, pass: nil, counters: counters.freeze, labels: labels.freeze) if ins.nil?

            case ins[0]
            when :play
              return Step.new(index: i, section: ins[1], pass: 1, counters: counters.freeze, labels: labels.freeze, length: ins[3], times: ins[2])
            when :label
              labels << ins[1]
              i += 1
            when :jump
              i = ins[1]
            when :generate
              step = generate_step(i, ins[1], counters, labels, peek, time)
              return nil if step == :unknown
              return step if step
              i += 1
            when :pick
              options = ins[1]
              if options.length == 1
                i = options[0][1]
              else
                return nil if peek
                rng ||= decision_rng
                i = weighted(options, rng)
              end
            when :goto
              _, target, times = ins
              n = counters[i] || 0
              if times && n >= times
                counters.delete(i) # fell through: the count starts over
                i += 1
                next
              end

              label = case target
                      when Symbol
                        target
                      when Hash
                        return nil if peek
                        rng ||= decision_rng
                        weighted(target, rng)
                      when Proc
                        return nil if peek
                        goto_proc(target)
                      end

              if label.nil? || label == Form::NEXT
                i += 1
              else
                counters[i] = n + 1 if times
                i = @form.labels.fetch(label)
              end
            end
          end
          raise "The flow went #{WALK_LIMIT} steps without reaching a section (gotos and picks with nothing to play?)"
        end

        # The next section of generate step +g+ (instruction +i+), as a
        # Step, updating +counters+ (the source's draws and tail under
        # [:gen, i], this visit's count under [:visit, i]); nil when the
        # visit is over (the source ended, or +sections+ played): the walk
        # then carries on.  :unknown for a peek at a steered source.
        def generate_step(i, g, counters, labels, peek, time)
          vkey = [:visit, i]
          visit = counters[vkey] || 0
          if g.sections && visit >= g.sections
            counters.delete(vkey)
            return nil
          end
          return :unknown if peek && g.source.steered?

          gkey = [:gen, i]
          n, tail = counters[gkey] || [0, g.source.form_start]
          read = ->(w) { MIDI::Param.value_at(w, time || 0, transport: @transport) }
          WALK_LIMIT.times do
            name, tail = g.source.form_next(tail, n, read)
            n += 1
            if name.nil?
              counters[gkey] = [n, tail].freeze
              counters.delete(vkey)
              return nil
            end
            next if g.source.nonterminal?(name) && !@form.sections.key?(name)

            counters[gkey] = [n, tail].freeze
            counters[vkey] = visit + 1
            sec = @form.sections.fetch(name) { raise ArgumentError, "generate: #{name.inspect} isn't a section of the form" }
            return Step.new(index: i, section: name, pass: 1, counters: counters.freeze, labels: labels.freeze,
                            length: g.length_for(name, n - 1, sec.length), times: sec.times)
          end
          raise "generate #{g.source.to_ruby} drew #{WALK_LIMIT} symbols without a section"
        end

        # A Step playing section +name+ of generate step +i+ next, as if its
        # source had drawn it (a performer's goto; the source carries on
        # from there), or nil if no generate step can give it.
        def forced_generate_step(name)
          i = @program.index { |ins| ins[0] == :generate && ins[1].source.form_states.include?(name) } or return nil
          sec = @form.sections[name] or return nil
          g = @program[i][1]
          counters = @counters.dup
          gkey = [:gen, i]
          n, tail = counters[gkey] || [0, g.source.form_start]
          counters[gkey] = [n + 1, g.source.form_force(tail, name)].freeze
          counters[[:visit, i]] = (counters[[:visit, i]] || 0) + 1
          Step.new(index: i, section: name, pass: 1, counters: counters.freeze, labels: [].freeze, length: g.length_for(name, n, sec.length), times: sec.times)
        end

        # The Step for the :play instruction at +index+ (pass 1).
        def play_step(index, counters, labels = [].freeze)
          ins = @program[index]
          Step.new(index: index, section: ins[1], pass: 1, counters: counters, labels: labels, length: ins[3], times: ins[2])
        end

        # The random number generator for one decision.
        def decision_rng
          Random.new(@seed * 1_000_003 + decision_count)
        end

        # The number of passes the next decision counts (the passes so far).
        def decision_count
          @history.length
        end

        # Picks a key of +weights+ (pairs of [key, weight] or [weight,
        # value] for picks) by weight.
        def weighted(weights, rng)
          pairs = weights.is_a?(Hash) ? weights.map { |k, w| [w, k] } : weights
          total = pairs.sum(&:first).to_f
          r = rng.rand * total
          pairs.find { |w, _| (r -= w) < 0 }&.last || pairs.last.last
        end

        # Calls a goto Proc, checking that it returns a label or nil.
        def goto_proc(target)
          label = target.call(state_unlocked)
          return label if label.nil? || label == Form::NEXT || @form.labels.key?(label)
          raise ArgumentError, "A goto Proc returned #{label.inspect}; return a label of the form (#{@form.labels.keys.map(&:inspect).join(', ')}) or nil (or :next) to carry on#{Form.suggest(label, @form.labels.keys)}"
        end

        # The length in whole notes of a section length (a Duration, or bars
        # counted from +from+).
        def length_from(length, from)
          length.is_a?(Sequence::Duration) ? length.to_r : @transport.bars_length(from, length)
        end

        # The length in whole notes of +length+ (a Duration, or bars)
        # ending at +to+.
        def length_before(length, to)
          return length.to_r if length.is_a?(Sequence::Duration)
          to - @transport.bar_position(@transport.bar_at(to) - length.to_r)
        end
      end
    end
  end
end

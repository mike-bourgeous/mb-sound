module MB
  module Sound
    module Generative
      # A stochastic L-system over section names (G4; console
      # MB::Sound#lsystem): an axiom (a word of Symbols) rewritten
      # +generations+ times, every symbol with a rule at once, so the word
      # grows self-similar (Lindenmayer 1968; Prusinkiewicz 1986 read such
      # words as music).  Rules rewrite a symbol to a word (an Array of
      # Symbols, or one Symbol) or to one of several words with weights
      # (drawn with counter-based Dice over the seed, generation, and
      # position, so a word is a pure function of the seed).
      #
      #     song = lsystem(%i[intro body outro],
      #                    body: { %i[build drop body] => 2, %i[build drop breakdown drop2] => 1 },
      #                    generations: 3, seed: 5)
      #     song.word                      # => [:intro, :build, :drop, :build, ...]
      #     song.flow(intro: 16, build: 8, drop: [16, 32], breakdown: 16, drop2: 32, outro: 16)
      #
      # Symbols with a rule are nonterminals: a flow skips them where they
      # are left in the final word unless they have a length (so `body`
      # above vanishes, and the word ends after its generations).  In a
      # flow's `generate` step the word plays once per visit; with +vary:
      # true+ each visit grows a new word (visit k draws with its own
      # keys), so `label :top; generate song; goto :top` never repeats.
      #
      # Rules named like the options (:generations, :seed, :vary) go in a
      # Hash: `lsystem(%i[a], { seed: %i[a b] }, generations: 2)`.
      class LSystem
        # The longest word (symbols) a rewrite may make.
        LIMIT = 4096

        attr_reader :axiom, :rules, :generations, :seed

        def initialize(axiom, rules, generations: 2, seed:, vary: false)
          @axiom = Array(axiom).freeze
          raise ArgumentError, "lsystem's axiom is a word of Symbols (got #{axiom.inspect})" if @axiom.empty? || !@axiom.all?(Symbol)
          raise ArgumentError, "lsystem's rules are a Hash of symbol => word (got #{rules.inspect})" unless rules.is_a?(Hash)
          @rules = rules.to_h { |k, v| [k, check_rule(k, v)] }.freeze
          raise ArgumentError, "lsystem generations: is an Integer from 0 to 32 (got #{generations.inspect})" unless generations.is_a?(Integer) && generations.between?(0, 32)
          @generations = generations
          @seed = Integer(seed)
          @vary = vary ? true : false
          @words = {}
          @lock = Mutex.new
        end

        # The same system with another seed.
        def reseed(seed)
          LSystem.new(@axiom, @rules.transform_values { |alts| alts.length == 1 && alts[0][1] == 1 ? alts[0][0] : alts.to_h },
                      generations: @generations, seed: seed, vary: @vary)
        end

        # True if every visit of a flow grows a new word.
        def vary?
          @vary
        end

        # The word after +generations+ rewrites (frozen; cached), for the
        # +visit+-th play when the system varies (else every visit's).
        def word(generations = @generations, visit: 0)
          visit = 0 unless @vary
          @lock.synchronize {
            @words[[generations, visit]] ||= grow(generations, visit)
          }
        end

        # Every symbol the system may write.
        def symbols
          @symbols ||= (@axiom + @rules.keys + @rules.values.flat_map { |alts| alts.flat_map(&:first) }).uniq.freeze
        end

        # True if +name+ has a rule (it stays in the word only as a
        # placeholder unless it has a length).
        def nonterminal?(name)
          @rules.key?(name)
        end

        # The word as a linear Form (sections in order, each with its
        # length from +bars+ or the keywords: bars, Durations, Ranges or
        # Arrays drawn per occurrence), nonterminals without a length left
        # out.
        def flow(bars = {}, generations: @generations, **more)
          lengths = bars.merge(more)
          # ([symbol, draw]: lengths are keyed by the position in the word,
          # as a generate step's first visit draws them)
          list = word(generations).each_with_index.reject { |s, _| nonterminal?(s) && !lengths.key?(s) }
          Form.linear(list, lengths, seed: @seed)
        end

        ### The form source protocol (Form::Generate)

        def form_start
          [0, 0].freeze
        end

        def form_states
          symbols
        end

        # Symbol +pos+ of the word of visit +visit+ (tail [visit, pos]), or
        # [nil, the next visit's start] past its end.
        def form_next(tail, _n, _read)
          visit, pos = tail
          w = word(visit: visit)
          return [nil, [visit + 1, 0].freeze] if pos >= w.length
          [w[pos], [visit, pos + 1].freeze]
        end

        # Like #form_next, heading for the word's end (a generate step's
        # +length:+ bound, gen-midi-2): the word's last symbol plays next
        # (if it is a section; else the word ends).
        def form_finish(tail, n, read)
          visit, pos = tail
          w = word(visit: visit)
          form_next([visit, [pos, w.length - 1].max].freeze, n, read)
        end

        # True after the first symbol of a word (each word is a new arc).
        def form_restart?(tail)
          tail[1] == 1
        end

        # A goto to a generated section plays it, then carries on in the
        # word where it was.
        def form_force(tail, _name)
          tail
        end

        def steered?
          false
        end

        def to_ruby(&value_text)
          reserved = @rules.keys.any? { |k| %i[generations seed vary].include?(k) }
          alt = ->(word) { word.length == 1 ? word[0].inspect : "%i[#{word.join(' ')}]" }
          rule = ->(alts) {
            alts.length == 1 && alts[0][1] == 1 ? alt.(alts[0][0]) : "{ #{alts.map { |w, wt| "#{alt.(w)} => #{Form.ruby_value(wt)}" }.join(', ')} }"
          }
          body = @rules.map { |k, v| reserved ? "#{k.inspect} => #{rule.(v)}" : "#{k}: #{rule.(v)}" }
          body = ["{ #{body.join(', ')} }"] if reserved
          opts = ["generations: #{@generations}", "seed: #{@seed}"]
          opts << 'vary: true' if @vary
          "lsystem(#{["%i[#{@axiom.join(' ')}]", *body, *opts].join(', ')})"
        end
        alias to_s to_ruby

        def inspect
          "#<LSystem #{to_ruby}>"
        end

        def ==(other)
          other.is_a?(LSystem) && other.to_ruby == to_ruby
        end
        alias eql? ==

        def hash
          to_ruby.hash
        end

        private

        # Rules as [[word, weight], ...].
        def check_rule(key, rule)
          raise ArgumentError, "lsystem's rules rewrite Symbols (got #{key.inspect})" unless key.is_a?(Symbol)
          alts = case rule
                 when Symbol then [[[rule], 1]]
                 when Array then [[rule, 1]]
                 when Hash then rule.map { |w, wt| [Array(w), wt] }
                 else raise ArgumentError, "lsystem: #{key} rewrites to a word (%i[a b]), a Symbol, or a Hash of words => weights (got #{rule.inspect})"
                 end
          alts.each do |w, wt|
            raise ArgumentError, "lsystem: #{key}'s words hold Symbols (got #{w.inspect})" unless w.all?(Symbol)
            raise ArgumentError, "lsystem: #{key}'s weights are numbers of at least 0 (got #{wt.inspect})" unless wt.is_a?(Numeric) && wt.real? && wt >= 0
          end
          raise ArgumentError, "lsystem: #{key} needs a word with weight above 0" if alts.sum(&:last).zero?
          alts.map { |w, wt| [w.dup.freeze, wt].freeze }.freeze
        end

        def grow(generations, visit)
          (1..generations).reduce(@axiom) { |w, g|
            dice = Dice.new(@seed, :lsystem, visit, g)
            out = w.each_with_index.flat_map { |sym, i|
              alts = @rules[sym]
              next [sym] unless alts
              next alts[0][0] if alts.length == 1
              ws = alts.map { |_, wt| wt.to_f }
              alts[Dice.index(ws, dice.rand(i)) || ws.rindex(&:positive?)][0]
            }
            raise ArgumentError, "lsystem: generation #{g} would be #{out.length} symbols (at most #{LIMIT}); use fewer generations" if out.length > LIMIT
            out
          }.freeze
        end
      end
    end
  end
end

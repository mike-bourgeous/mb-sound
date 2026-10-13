require 'set'

module MB
  module Sound
    module GraphNode
      module Recipe
        # Prints a recorded graph as Ruby DSL code (see GraphNode#to_ruby).
        #
        # Rules:
        # - Objects used more than once, named by a local variable in a build
        #   block, or used inside a block become variables (in the order of
        #   their last recorded touch); everything else stays a chain.
        # - Values print in their units (Lengths, Intervals, Durations, Notes,
        #   Pitches; floats exactly k/10 dB as k.db).
        # - Build blocks print with their parameter names; synth lane blocks
        #   print once, with per_voice(...) where lanes differ only in values
        #   (lane 0 and a warning if they differ in structure).
        # - Runtime blocks print as their own source text (Prism).
        # - Anything unrepresentable prints as `nil` with a
        #   `# FIXME(graph-io): ...` comment on its line and in the header.
        # - Free inputs (objects without a recipe that aren't values) are
        #   named from +inputs+ or automatically (midi, input, ...), and
        #   listed in the header.
        #
        # The output uses only literals, unit methods, recorded DSL calls,
        # local variables, and build blocks (no flow control), the subset a
        # later loader can read without eval.
        class RubyWriter
          # Operator precedence for parentheses.
          # (| and & join and layer clips; Ruby binds & tighter than |, both
          # looser than + and -)
          PREC = { :| => 0, :& => 1, :+ => 2, :- => 2, :* => 3, :/ => 3, :** => 5 }.freeze
          ATOM = 10
          UNARY = 4
          BINARY = PREC.keys.freeze

          IDENT = /\A[a-z_][a-zA-Z0-9_]*\z/
          KEYWORDS = %w[
            alias and begin break case class def defined? do else elsif end ensure false for if in module next nil
            not or redo rescue retry return self super then true undef unless until when while yield
          ].freeze

          # Free inputs by name (name => object).
          attr_reader :inputs

          # Problems: descriptions of what couldn't be printed.
          attr_reader :problems

          # Warnings (e.g. synth lanes that differ in structure).
          attr_reader :warnings

          # +root+ is the graph (a node, bundle, Synth, ...); +inputs+ names
          # free inputs ({ midi: notes }); +seeds: true+ prints the random
          # seeds drawn (seed: N) so the code rebuilds the same noise in any
          # order (off by default for reading; documents will include them);
          # +seeds: :marked+ (graph documents) prints them as
          # `seed: drawn_seed(N)`, so a loader can tell them from seeds the
          # code gave (GraphIO.load's seeds: :fresh redraws only those).
          # +knobs+ ({ 'drive' => 1.0 }) prints Constants named after a
          # knob with its value as the knob's bare name, as do the nodes of
          # +knob_nodes+ ({ node => 'drive' }; graph documents' params).
          #
          # +assets+ (a GraphIO::Assets, for bundles) names files for tables
          # that aren't library tables and for Strings naming sound or MIDI
          # files.
          def initialize(root, inputs: {}, seeds: false, knobs: {}, knob_nodes: {}, assets: nil)
            @root = root
            @assets = assets
            @given_inputs = inputs
            @seeds = seeds
            @knobs = knobs.transform_keys(&:to_s)
            @knob_nodes = knob_nodes.each_with_object({}.compare_by_identity) { |(k, v), h| h[k] = v.to_s }
          end

          # Knob names printed (see #initialize).
          def knobs_used
            to_s
            @knobs_used.to_a
          end

          # The text of a plain value (a literal or unit value), e.g. for a
          # document header.
          def literal(v)
            reset! unless @names
            leaf(v, '')
          end

          # The text split into [variable lines, the final expression's
          # lines] (without the header comments), for writers that put the
          # expression into a statement of their own (set documents).
          def parts
            to_s
            @parts
          end

          # The Ruby text.
          def to_s
            @text ||= begin
              reset!
              text = build
              if @seed_warning && @seeds
                # Some seeds can't be printed: print none, so every seed is
                # drawn in the original order
                @seeds = false
                @fallback = true
                reset!
                text = build
              end
              text
            end
          end

          private

          def reset!
            @names = {}.compare_by_identity
            @used = Set.new
            @inputs = {}
            @given_inputs.each do |name, obj|
              @names[obj] = name.to_s
              @used << name.to_s
              @inputs[name.to_s] = obj
            end
            @problems = []
            @warnings = []
            @fixmes = []
            @template = nil
            @locals = nil
            @scope = nil
            @seed_warning = false
            @output_owner = {}.compare_by_identity
            @given_inputs.each_value { |obj| register_outputs(obj) }
            @knobs_used = Set.new
            @used.merge(@knobs.keys)
            @used.merge(@knob_nodes.values)
          end

          # The knob name +o+ prints as, or nil (see #initialize).
          def knob_for(o)
            return @knob_nodes[o] if @knob_nodes.key?(o)
            return nil if @knobs.empty? || !o.is_a?(Constant)
            n = o.graph_node_name
            return nil unless n && @knobs.key?(n) && live_constant(o) == @knobs[n]
            n
          end

          def build
            roots = @root.is_a?(Array) ? @root : [@root]
            lines = emit_scope(nil, roots, [], '')
            final = Recipe.graph_object?(@root) ? expr(@root, top: true) : value(@root)
            @parts = [finish_lines(lines.join("\n").split("\n")), finish_lines(final.split("\n"))]
            lines << final
            body = finish_lines(lines.join("\n").split("\n"))

            header = []
            header << "# inputs: #{@inputs.keys.join(', ')}" unless @inputs.empty?
            header += @problems.uniq.map { |p| "# FIXME(graph-io): #{p}" }
            header += @warnings.uniq.map { |w| "# WARNING(graph-io): #{w}" }
            (header + body).join("\n")
          end

          # Replaces FIXME markers with nil and a comment at the line's end.
          def finish_lines(lines)
            lines.map { |l|
              notes = []
              l = l.gsub(/\u0003(\d+)\u0003/) { notes << @fixmes[$1.to_i]; 'nil' }
              l = l.gsub(/\u0004(\d+)\u0004/) { notes << @fixmes[$1.to_i]; '' }
              notes.empty? ? l : "#{l} # FIXME(graph-io): #{notes.uniq.join('; ')}"
            }
          end

          # A marker that adds a FIXME comment to its line (and the header).
          def note_fixme(problem)
            "\u0004#{fixme_index(problem)}\u0004"
          end

          # The index of +problem+ in @fixmes (the same for the same text, so
          # synth lanes with the same problem print alike).
          def fixme_index(problem)
            @problems << problem
            idx = @fixmes.index(problem)
            return idx if idx
            @fixmes << problem
            @fixmes.length - 1
          end

          # A placeholder that prints as nil with a FIXME comment.
          def fixme(problem)
            "\u0003#{fixme_index(problem)}\u0003"
          end

          ### Scopes and variables

          # Returns lines defining variables for objects made in block scope
          # +scope+ (nil for the top level) reachable from +roots+.
          def emit_scope(scope, roots, lines, indent)
            info = analyze(scope, roots)
            # Objects that drew random seeds are made in their original order
            # (seeds come from MB::Sound's generator in creation order)
            seeded = info[:order].select { |o| seeded_key(o) }
            seeded = [] if seeded.length < 2
            vars = info[:order].select { |o|
              next false if scope.nil? && o.equal?(@root)
              next false if knob_for(o) || o.is_a?(Knob) || o.is_a?(Knob::Reader) || o.is_a?(BusTap::Channel)
              info[:counts][o] > 1 || info[:forced].include?(o) || local_name(o) || seeded.include?(o)
            }
            vars.sort_by.with_index { |o, i| [order_key(o), i] }.each do |o|
              next if @names.key?(o)
              # The name first: in `noise = noise()`, the right side must
              # see the new local (see #call_text)
              name = unique(local_name(o) || base_name(o))
              text = expr(o, top: true, indent: indent)
              lines << "#{indent}#{name} = #{text}"
              @names[o] = name
            end
            lines
          end

          # Counts references to objects of +scope+ from +roots+, and finds
          # objects that blocks capture from this scope (they must be
          # variables).  Returns { order:, counts:, forced:, captures: }.
          def analyze(scope, roots)
            counts = Hash.new(0).compare_by_identity
            forced = Set.new.compare_by_identity
            captures = []
            order = []
            visit = nil
            visit = ->(o) {
              counts[o] += 1
              next if counts[o] > 1 || @names.key?(o)
              register_outputs(o)
              c = Recipe.call_of(o, scope)
              if c.nil?
                unrecorded_deps(o).each { |d| visit.(d) }
                next
              end
              if c.scope != scope
                captures << o
                next
              end
              deps(o, c).each { |d| visit.(d) }
              block_captures(c).each { |x|
                if Recipe.call_of(x, scope)&.scope == scope
                  visit.(x)
                  forced << x
                else
                  captures << x
                end
              }
              order << o
            }
            roots.each { |r| visit.(r) if r }
            { order: order, counts: counts, forced: forced, captures: captures }
          end

          # Objects from outer scopes that +call+'s build block invocations
          # use (each invocation's own captures).
          def block_captures(call)
            invs = call.invocations
            return [] unless invs && !invs.empty?

            invs.flat_map { |inv|
              saved = @names
              @names = @names.dup
              inv.args.each { |a| @names[a] = 'param' if Recipe.graph_object?(a) }
              info = analyze(inv, invocation_roots(inv))
              stmt = (inv.statements || []).flat_map { |s| block_captures(s) }
              @names = saved
              info[:captures] + stmt
            }.select { |o| !inv_arg?(call, o) }
          end

          def inv_arg?(call, o)
            call.invocations.any? { |inv| inv.args.any? { |a| a.equal?(o) } }
          end

          def invocation_roots(inv)
            roots = []
            roots << inv.result if Recipe.graph_object?(inv.result) || inv.result.is_a?(Array)
            roots
          end

          # Graph objects that +o+'s recipe refers to directly.
          def deps(o, c)
            list = objects_in([c.receiver, c.args, c.kwargs.values])
            Recipe.config_of(o).each { |k| list.concat(objects_in([k.args, k.kwargs.values])) }
            list
          end

          # Graph objects an unrecorded object prints through (a bundle made
          # by the library prints as channels(...) of its channels).
          def unrecorded_deps(o)
            return [@output_owner[o][0]] if @output_owner.key?(o)
            o.is_a?(Channels) && channels_printable?(o) ? o.to_a : []
          end

          # Remembers the outputs of multichannel node +o+ (not a bundle), so
          # a channel taken with o.outputs[i] prints that way.
          def register_outputs(o)
            return if o.is_a?(Channels) || o.is_a?(Array) || !o.respond_to?(:outputs) || !o.respond_to?(:channel_count)
            return unless o.channel_count > 1

            o.outputs.each_with_index { |out, i| @output_owner[out] ||= [o, i] unless out.equal?(o) }
          rescue StandardError
            nil
          end

          # The seq of the first call that drew a random seed for +o+, or nil.
          def seeded_key(o)
            ([Recipe.call_of(o, @scope)] + Recipe.config_of(o)).compact.select(&:seeds).map(&:seq).min
          end

          def objects_in(v, acc = [])
            case v
            when Array then v.each { |x| objects_in(x, acc) }
            when Hash then v.each { |k, x| objects_in(k, acc); objects_in(x, acc) }
            when Range then objects_in([v.begin, v.end], acc)
            when MB::Sound::Length::Seconds, MB::Sound::Length::Samples
              objects_in(v.origin[0], acc) if v.origin
              objects_in(v.value, acc)
            when MB::Sound::Phase then objects_in(v.cycles, acc) unless v.cycles.is_a?(Numeric)
            when ChannelValues then objects_in(v.values, acc)
            else acc << v if Recipe.graph_object?(v)
            end
            acc
          end

          # Order by the last recorded call touching an object.
          def order_key(o)
            seeded = seeded_key(o)
            return seeded if seeded
            c = Recipe.call_of(o, @scope)
            ([c&.seq || 0] + Recipe.config_of(o).map(&:seq)).max
          end

          def local_name(o)
            @locals&.[](o)
          end

          def unique(name)
            name = name.to_s.gsub(/[^a-zA-Z0-9_]/, '_').sub(/\A_+/, '').downcase
            name = "n_#{name}" unless name.match?(/\A[a-z_]/)
            name = "#{name}_" if KEYWORDS.include?(name)
            n = name
            i = 2
            while @used.include?(n)
              n = "#{name}#{i}"
              i += 1
            end
            @used << n
            n
          end

          # Methods whose results are effects (named fx).
          FX = %i[
            filter lp4 lowpass4 four_pole diode diode_ladder peq peq_series bandpass_series smooth hilbert_iir clip_rate
            delay feedback_delay multitap multitap_delay reverb chorus juno_chorus feedback fb oversample resample
            softclip clip asoftclip aclip quantize aquantize ease aease shape_curve ashape_curve
          ].freeze

          # A variable name for +o+: the name given with #named, else a role
          # (voice for synths, osc, lfo, env, notes, clip, kit, fx for effect results,
          # out for the final output, sig otherwise).
          def base_name(o)
            named = Recipe.config_of(o).reverse.find { |k| k.name == :named }
            return named.args[0].to_s if named && named.args[0] && !named.args[0].to_s.empty?
            return 'out' if o.equal?(@root)

            c = Recipe.call_of(o, @scope)
            case o
            when MB::Sound::Synth then 'voice'
            when MB::Sound::Tone then o.lfo? ? 'lfo' : 'osc'
            when MB::Sound::Envelope then 'env'
            when MB::Sound::Notes then 'notes'
            when MB::Sound::Sequence::Clip then 'clip'
            when MB::Sound::Sequence::Kit then 'kit'
            else
              c && FX.include?(c.name) ? 'fx' : 'sig'
            end
          end

          ### Expressions

          # The text of +o+ (the name if it has one).
          def expr(o, top: false, indent: '')
            text, _ = expr_p(o, indent: indent, arith: false)
            text
          end

          # [text, precedence] of +o+.  +arith+ is true where a number would
          # do (operands of arithmetic): an unrecorded Constant prints as its
          # value there.
          def expr_p(o, indent: '', arith: false)
            return [@names[o], ATOM] if @names.key?(o)
            if (k = knob_for(o))
              @knobs_used << k
              return [k, ATOM]
            end

            c = Recipe.call_of(o, @scope)
            return unrecorded(o, indent, arith) unless c

            c = live_call(o, c)
            if @seeds && o.is_a?(MB::Sound::Sequence::Clip) && unprintable_seeds?(c) && o.variations.empty?
              # A clip whose recipe drew seeds that can't be given (e.g.
              # bake through humanize) is saved as the events it made
              return [clip_events_text(o, indent), ATOM]
            end
            recv_obj = c.receiver
            if BINARY.include?(c.name) && c.args.length == 1 && c.kwargs.empty? && c.block.nil?
              prec = PREC[c.name]
              l, lp = operand(recv_obj, indent)
              r, rp = operand(c.args[0], indent)
              l = "(#{l})" if c.name == :** ? lp <= prec : lp < prec
              r = "(#{r})" if c.name == :** ? rp < prec : rp <= prec
              text = "#{l} #{c.name} #{r}"
              config = Recipe.config_of(o)
              return [text, prec] if config.empty? && !named_config?(o)
              text = "(#{text})"
            elsif c.name == :[] && c.block.nil?
              text = "#{receiver_text(recv_obj, indent)}[#{c.args.map { |a| value(a, indent) }.join(', ')}]"
            else
              text = call_text(receiver_text(recv_obj, indent), c, indent)
            end
            Recipe.config_of(o).each { |k| text = call_text(text, k, indent) }
            [text, ATOM]
          end

          def named_config?(o)
            Recipe.config_of(o).any?
          end

          # An operand of arithmetic.
          def operand(v, indent)
            if Recipe.graph_object?(v)
              expr_p(v, indent: indent, arith: true)
            elsif v.is_a?(Numeric) && v.real? && v.negative?
              [num(v), UNARY]
            else
              [value(v, indent), ATOM]
            end
          end

          # The receiver part of a call: nil for MB::Sound (printed bare).
          def receiver_text(r, indent)
            return nil if r.equal?(MB::Sound)
            return class_name(r) if r.is_a?(Module)

            t, p = Recipe.graph_object?(r) ? expr_p(r, indent: indent) : [value(r, indent), r.is_a?(Numeric) && r.real? && r.negative? ? UNARY : ATOM]
            # Unary note marks bind after calls: (!A1).n8
            p < ATOM || t.match?(/\A[!~]/) ? "(#{t})" : t
          end

          def class_name(k)
            n = k.name
            return fixme("anonymous class #{k.inspect}") unless n
            n.start_with?('MB::Sound::') ? n.delete_prefix('MB::Sound::') : n
          end

          # Live values win over recorded ones (Constant#constant= queues a
          # change; Multiplier and Mixer constants may be set later).
          def live_call(o, c)
            case o
            when Constant
              if c.name == :constant && c.receiver.is_a?(Numeric)
                live = live_constant(o)
                return c.dup.tap { |d| d.receiver = live } if live != c.receiver
              end
            when Multiplier, Mixer
              if [:*, :+, :-].include?(c.name) && c.args.length == 1 && c.args[0].is_a?(Numeric) && !c.receiver.is_a?(Numeric)
                live = c.name == :- ? -o.constant : o.constant
                return c.dup.tap { |d| d.args = [live] } if live != c.args[0] && live.is_a?(Numeric)
              end
            end
            c
          end

          def live_constant(o)
            queued = o.instance_variable_get(:@changes)&.max_by(&:first)
            queued ? queued.last : o.constant
          end

          # Text for an object without a recipe: a value, a bundle of
          # printable channels, or a free input.
          def unrecorded(o, indent, arith)
            if (owner = @output_owner[o])
              return ["#{receiver_text(owner[0], indent)}.outputs[#{owner[1]}]", ATOM]
            end

            case o
            when Constant
              v = live_constant(o)
              t = num(v)
              if arith
                return [t, v.is_a?(Numeric) && v.real? && v.negative? ? UNARY : ATOM]
              end
              return ["#{v.is_a?(Numeric) && v.real? && v.negative? ? "(#{t})" : t}.constant", ATOM]
            when Knob, Knob::Reader
              # A Session knob (or a graph document's, without knob_nodes):
              # each knob(:name) is its own reader, so it prints inline
              # (2026-10-12: before, as a free input)
              return [knob_text(o), ATOM]
            when BusTap::Channel
              # A reader of a Session bus or track: bus(:name) (see #bus_text)
              return [bus_text(o), ATOM]
            when MB::Sound::Notes::NotePitch
              # falls through to an input
            when MB::Sound::Pitch
              return [pitch_text(o), ATOM]
            when Channels
              tap = o.to_a.first.is_a?(BusTap::Channel) && o.to_a.first.original_source
              return [bus_text(tap), ATOM] if tap && o.to_a == tap.outputs
              if channels_printable?(o)
                return ["channels(#{o.to_a.map { |x| expr(x, indent: indent) }.join(', ')})", ATOM]
              end
            when MB::Sound::Sequence::Clip
              # A clip without a recipe (captured, recorded, Clip.new):
              # its events
              return [clip_events_text(o, indent), ATOM]
            end

            [input_name(o), ATOM]
          end

          # bus(:name), bus(:name, only: :node), or one channel of a bus,
          # bus(:name)[1], for a BusTap or one of its channels.
          def bus_text(o)
            tap = o.is_a?(BusTap) ? o : o.original_source
            text = "bus(#{tap.source_name.inspect}#{tap.only ? ", only: #{tap.only.inspect}" : ''})"
            return text if o.is_a?(BusTap) || tap.outputs.length == 1
            "#{text}[#{tap.outputs.index(o)}]"
          end

          # knob(:name) for a Knob or Knob::Reader.
          def knob_text(o)
            "knob(#{(o.is_a?(Knob::Reader) ? o.knob : o).name.to_sym.inspect})"
          end

          def channels_printable?(o)
            o.to_a.all? { |x| @names.key?(x) || Recipe.call_of(x, @scope) || x.is_a?(Constant) || x.is_a?(MB::Sound::Pitch) || x.is_a?(BusTap::Channel) }
          end

          # Names a free input.
          def input_name(o)
            name = unique(o.is_a?(MB::Sound::Notes) ? 'midi' : (o.is_a?(MB::Sound::Sequence::Clip) ? 'clip' : 'input'))
            file = (Object.const_source_location(o.class.name)&.first if o.class.name)
            unless file&.start_with?(LIB_DIR)
              @problems << "#{name} is a #{o.class.name || o.class.inspect}, a class defined outside the library (an input here)"
            end
            @names[o] = name
            @inputs[name] = o
            name
          end

          # A dynamics level given as a bare dB number (0 and below) as the
          # Decibels it means, so it prints as `-20.db` (same value; see
          # DynamicsMethods.check_level).
          def dynamics_level(name, key, v)
            return v unless DynamicsMethods::LEVEL_KEYWORDS.include?(key) && DynamicsMethods::LEVEL_METHODS.include?(name)
            return v unless v.is_a?(Numeric) && !v.is_a?(MB::Sound::Decibels) && v.real? && v.finite? && v <= 0

            MB::Sound::Decibels.new(v)
          end

          # Calls whose delay keywords print in their current spelling (see
          # #call_text).
          DELAY_CALLS = [:delay, :feedback_delay, :multitap, :multitap_delay].freeze

          # receiver.name(args) { block } for call +c+.
          def call_text(recv, c, indent)
            if c.name == :events && recv.nil? && c.receiver.equal?(MB::Sound) && c.block.nil?
              return events_text(c.args, c.kwargs, indent)
            end
            args = c.args.map { |a| value(a, indent) }
            kwargs = c.kwargs.dup
            if DELAY_CALLS.include?(c.name)
              # Current spellings: delay(t), not the deprecated
              # delay(seconds: t); smooth:, not smoothing:
              args = [value(kwargs.delete(:seconds), indent)] if kwargs.key?(:seconds) && args.empty?
              kwargs = kwargs.to_h { |k, v| [k == :smoothing && !kwargs.key?(:smooth) ? :smooth : k, v] }
            end
            seed = drawn_seed(c)
            kwargs[:seed] = seed if seed
            args += kwargs.map { |k, v|
              if k == :seed && seed && @seeds == :marked
                # Graph documents mark drawn seeds, so seeds: :fresh can
                # redraw them and keep the ones the code gave
                "seed: drawn_seed(#{seed})"
              elsif k.is_a?(Symbol)
                "#{key_text(k)} #{value(dynamics_level(c.name, k, v), indent)}"
              else
                "#{value(k, indent)} => #{value(v, indent)}"
              end
            }
            named = c.block && c.block_kind == :runtime && proc_name(c.block)
            args << "&named_proc(#{named.inspect})" if named

            name = c.name.to_s
            text = recv ? "#{recv}.#{name}" : name
            if args.any?
              text += "(#{args.join(', ')})"
            elsif recv.nil? && @used.include?(name)
              # A local of that name would shadow the bare call
              text += '()'
            end

            if c.block_kind == :build && c.invocations && !c.invocations.empty?
              text += block_text(c, indent)
            elsif c.block_kind == :build && c.block
              # Not called yet (e.g. kept for later): print its source
              text += runtime_block(c, c.block)
            elsif c.block && !named
              text += runtime_block(c, c.block)
            end
            text
          end

          # The name of +block+ in MB::Sound.named_proc's registry, or nil.
          def proc_name(block)
            procs = defined?(MB::Sound::GraphIO) && MB::Sound::GraphIO.procs
            return nil unless procs
            procs.each { |k, v| return k if v.equal?(block) }
            nil
          end

          public

          # The text of Hash key +k+ (`name:` or `"odd name":`).
          def key_text(k)
            k.is_a?(Symbol) && k.to_s.match?(/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/) ? "#{k}:" : "#{k.to_s.inspect}:"
          end

          private

          # The seed drawn by +c+ if it should be printed (see the class
          # description), else nil.
          def drawn_seed(c)
            return nil unless c.seeds && !c.kwargs.key?(:seed) && c.lane.nil?

            synth = c.name == :synth || (c.name == :new && c.receiver.is_a?(Class) && c.receiver <= MB::Sound::Synth)
            if synth
              # Lanes draw from the synth's seed; it matters only if they did
              return nil unless c.invocations&.any?(&:seeded)
              return @seeds ? c.seeds.first : nil
            end
            return (@seeds ? c.seeds.first : nil) if c.seeds.length == 1 && accepts_seed?(c)

            # Can't be given (no seed:, or several seeds)
            @seed_warning = true
            seed_warning(c) if @seeds || @fallback
            nil
          end

          # Warns that +c+'s random seeds aren't printed.  Returns nil.
          def seed_warning(c)
            @warnings << "#{c.name} draws random seeds that aren't printed; " \
              'rebuilds match only in the same order after the same MB::Sound.seed'
            nil
          end

          # True if call +c+ drew random seeds that can't be printed as
          # seed: (see #drawn_seed).
          def unprintable_seeds?(c)
            c.seeds && !c.kwargs.key?(:seed) && c.lane.nil? && !(c.seeds.length == 1 && accepts_seed?(c))
          end

          def accepts_seed?(c)
            m = c.receiver.method(c.name)
            m = m.super_method while m && wrapper?(m.owner)
            m && m.parameters.any? { |type, n| (n == :seed && (type == :key || type == :keyreq)) || type == :keyrest }
          rescue NameError
            false
          end

          def wrapper?(mod)
            mod.name.nil? || mod == ChannelDispatch::Generated || mod == NewRecording || mod == SeedRecording
          end

          ### Blocks

          def block_params(c)
            (c.block&.parameters || []).map { |type, n|
              case type
              when :rest then "*#{n}"
              when :keyrest then "**#{n}"
              when :block then "&#{n}"
              else n.to_s
              end
            }
          end

          # The build block of +c+, printed from its invocations.
          def block_text(c, indent)
            params = block_params(c)
            inner = indent + '  '
            invs = c.invocations
            body =
              if invs.length == 1
                block_body(c, invs[0], params, inner)
              else
                lane_bodies(c, invs, params, inner)
              end
            plist = params.empty? ? '' : " |#{params.join(', ')}|"
            " {#{plist}\n#{body}\n#{indent}}"
          end

          # Prints several invocations (synth lanes, unison layers) once:
          # values that differ become per_voice(...).
          def lane_bodies(c, invs, params, indent)
            saved_template = @template
            templates = invs.map { |inv|
              @template = []
              text = block_body(c, inv, params, indent)
              [text, @template]
            }
            @template = saved_template

            skeletons = templates.map(&:first)
            if skeletons.uniq.length > 1
              if ENV['MB_SOUND_RECIPE_DEBUG']
                skeletons.uniq.first(2).each_with_index { |sk, i| warn "--- variant #{i}\n#{fill(sk) { |j| templates[skeletons.index(sk)][1][j][0] }}" }
              end
              @warnings << "#{c.name}'s block built #{skeletons.uniq.length} different graphs over #{invs.length} calls; printed the first call's"
              text, slots = templates[0]
              return fill(text) { |i| slots[i][0] }
            end

            text = skeletons[0]
            per_voice = c.name == :synth || (c.receiver.is_a?(Class) && c.receiver <= MB::Sound::Synth)
            fill(text) { |i|
              printed = templates.map { |(_, slots)| slots[i][0] }
              if printed.uniq.length == 1
                printed[0]
              elsif per_voice
                per_voice_text(templates.map { |(_, slots)| slots[i][1] }, printed)
              else
                @warnings << "#{c.name}'s block calls differ in values (#{printed.uniq.join(', ')}); printed the first call's"
                printed[0]
              end
            }
          end

          def fill(text)
            text.gsub(/\u0001(\d+)\u0002/) { yield $1.to_i }
          end

          # per_voice(...) for lane values +values+ (printed as +printed+):
          # a Range when they spread evenly, else the shortest repeating list.
          def per_voice_text(values, printed)
            count = values.length
            if values.all? { |v| v.is_a?(Numeric) && v.real? } && count > 2
              range = values.first..values.last
              spread = ChannelSpread.new(range)
              if values.each_with_index.all? { |v, i| spread.value(i, count) == v }
                return "per_voice(#{printed.first}..#{printed.last})"
              end
            end
            period = (1..count).find { |p| printed.each_with_index.all? { |t, i| t == printed[i % p] } }
            "per_voice(#{printed.first(period).join(', ')})"
          end

          # The lines of one invocation's body.
          def block_body(c, inv, params, indent)
            saved = [@names.dup, @used.dup, @locals, @scope]
            @scope = inv
            inv.args.each_with_index do |a, i|
              next unless Recipe.graph_object?(a) && params[i]
              @names[a] = params[i].delete_prefix('*').delete_prefix('&')
              @used << @names[a]
            end
            @used.merge(params)
            @locals = {}.compare_by_identity
            inv.locals.each do |k, v|
              next if params.include?(k.to_s) || !Recipe.graph_object?(v) || @locals.key?(v)
              @locals[v] = k.to_s
            end

            roots = invocation_roots(inv)
            stmts = inv.statements || []
            roots += stmts.flat_map { |s| (s.invocations || []).flat_map { |si| block_captures_for(s, si) } }
            lines = emit_scope(inv, roots, [], indent)
            stmts.each { |s| lines << "#{indent}#{call_text(receiver_text(s.receiver, indent), s, indent)}" }
            if Recipe.graph_object?(inv.result)
              lines << "#{indent}#{expr(inv.result, top: true, indent: indent)}"
            elsif inv.result.is_a?(Array) && inv.result.all? { |x| Recipe.graph_object?(x) }
              lines << "#{indent}[#{inv.result.map { |x| expr(x, indent: indent) }.join(', ')}]"
            elsif stmts.empty?
              lines << "#{indent}#{value(inv.result, indent)}"
            end
            lines.join("\n")
          ensure
            @names, @used, @locals, @scope = saved
            # Free inputs found inside keep their names everywhere
            @inputs.each { |n, obj| @names[obj] = n; @used << n }
          end

          # Objects a statement's block uses from the enclosing scope.
          def block_captures_for(stmt, _inv)
            block_captures(stmt)
          end

          # A runtime block's source text, found with Prism.
          def runtime_block(c, block)
            src = Recipe.block_source(block, c.name)
            if src
              outer = Recipe.outer_locals(block, src)
              return " #{src}" if outer.empty?

              note = note_fixme("the #{c.name} block uses #{outer.join(', ')} from the code around it")
              first, rest = src.split("\n", 2)
              return " #{first}#{note}#{"\n#{rest}" if rest}"
            end

            " { |*| #{fixme("the #{c.name} block's source wasn't found")} }"
          end

          ### Values

          # Text for a value (literal, unit value, or graph object).
          def value(v, indent = '')
            return expr(v, indent: indent) if Recipe.graph_object?(v) || @names.key?(v)

            if @template && leaf?(v)
              @template << [leaf(v, indent), v]
              return "\u0001#{@template.length - 1}\u0002"
            end
            leaf(v, indent)
          end

          def leaf?(v)
            case v
            when Numeric, Symbol, String, true, false, nil, MB::Sound::Interval, MB::Sound::Sequence::Duration
              true
            when MB::Sound::Length::Seconds, MB::Sound::Length::Samples
              v.value.is_a?(Numeric)
            when MB::Sound::Pitch
              true
            else
              false
            end
          end

          def leaf(v, indent)
            case v
            when Integer, Float, Rational, Complex, MB::Sound::Decibels then num(v)
            when nil, true, false, Symbol then v.inspect
            when String
              # A file name, in a bundle: the asset's name
              (@assets && @assets.file(v))&.inspect || v.inspect
            when Range
              b = v.begin.nil? ? '' : range_end(v.begin, indent)
              e = v.end.nil? ? '' : range_end(v.end, indent)
              "#{b}#{v.exclude_end? ? '...' : '..'}#{e}"
            when Array then "[#{v.map { |x| value(x, indent) }.join(', ')}]"
            when Hash then "{ #{v.map { |k, x| k.is_a?(Symbol) ? "#{key_text(k)} #{value(x, indent)}" : "#{value(k, indent)} => #{value(x, indent)}" }.join(', ')} }"
            when MB::Sound::Length::Samples then v.origin ? origin_text(v, indent) : unit_value(v.value, 'samples', indent)
            when MB::Sound::Length::Seconds then v.origin ? origin_text(v, indent) : seconds_text(v, indent)
            when MB::Sound::Interval then interval_text(v)
            when MB::Sound::Sequence::Duration then duration_text(v)
            when MB::Sound::Phase then phase_text(v, indent)
            when MB::Sound::Pitch then pitch_text(v)
            when ChannelValues then "per_channel(#{v.values.map { |x| value(x, indent) }.join(', ')})"
            when ChannelSpread then "per_channel(#{leaf(v.range, indent)})"
            when Module then class_name(v)
            when MB::Sound::Wavetable then wavetable_text(v)
            when MB::Sound::Sample then sample_text(v, indent)
            when MB::Sound::Sample::Slices then slices_text(v, indent)
            when MB::Sound::Sampler::Instrument then instrument_text(v, indent)
            when MB::Sound::Scale then scale_text(v)
            when MB::Sound::Sequence::Seq::Step then step_text(v)
            when MB::Sound::Length::Attack then v.to_ruby
            when MB::Sound::MIDI::Transform::Spec then transform_spec_text(v, indent)
            when Proc then ((n = proc_name(v)) && "named_proc(#{n.inspect})") || Recipe.block_source(v, nil) || fixme("a #{v.lambda? ? 'lambda' : 'proc'} whose source wasn't found")
            when Data
              fields = v.to_h.map { |k, x| "#{key_text(k)} #{value(x, indent)}" }
              "#{class_name(v.class)}.new(#{fields.join(', ')})"
            else fixme("can't print a #{v.class}")
            end
          end

          # A Range end: negative numbers need no parentheses in a range.
          def range_end(x, indent)
            value(x, indent)
          end

          def unit_value(x, unit, indent)
            if x.is_a?(Numeric)
              t = num(x)
              t = "(#{t})" if (x.real? && x.negative?) || t.include?('/') # (1r/110).seconds
              "#{t}.#{unit}"
            else
              t, p = expr_p(x, indent: indent)
              p < ATOM ? "(#{t}).#{unit}" : "#{t}.#{unit}"
            end
          end

          # A length read from an object (Length::Quantity#origin), printed as
          # the call that made it: `220.hz.period`, `osc.period_samples`.
          def origin_text(v, indent)
            obj, name = v.origin
            if Recipe.graph_object?(obj) || @names.key?(obj)
              t, p = expr_p(obj, indent: indent)
              t = "(#{t})" if p < ATOM
            else
              t = leaf(obj, indent)
            end
            "#{t}.#{name}"
          end

          def seconds_text(v, indent)
            s = v.value
            return unit_value(s, 'seconds', indent) unless s.is_a?(Numeric)

            ms = (s * 1000).round
            return unit_value(ms, 'ms', indent) if s.is_a?(Float) && ms.ms.value == s && ms != 0
            unit_value(s, 'seconds', indent)
          end

          def interval_text(v)
            unit = v.instance_variable_get(:@unit)
            st = v.semitones
            candidates =
              case unit
              when :octaves then [[st / 12r, 'oct'], [st / 12.0, 'oct']]
              when :cents then [[(st * 100).to_r, 'cents'], [st * 100.0, 'cents']]
              else []
              end
            candidates << [st, 'st']
            candidates.each do |n, u|
              n = n.to_i if n.is_a?(Rational) && n.denominator == 1
              n = n.to_i if n.is_a?(Float) && n == n.round && n.abs < 1e15 && !(st.is_a?(Float))
              iv = n.public_send(u)
              next unless iv.semitones == st && iv.semitones.class == st.class
              t = num(n)
              return n.negative? ? "(#{t}).#{u}" : "#{t}.#{u}"
            end
            fixme("an Interval of #{st.inspect} semitones")
          end

          DURATION_DENOMINATORS = [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32, 64, 128].freeze

          DURATION_MODS = { 'dotted' => 'dotted', 'double dotted' => 'dd', 'triplet' => 'triplet' }.freeze

          def duration_text(v)
            r = v.whole_notes
            # The spelling it was made with, when that rebuilds it exactly
            if (m = v.to_s.match(/\A(?:(dotted|double dotted|triplet) )?(?:(\d+) × )?n(\d+)\z/))
              k = (m[2] || 1).to_i
              d = k.public_send("n#{m[3]}")
              d = d.public_send(DURATION_MODS[m[1]]) if m[1]
              return "#{k}.n#{m[3]}#{".#{DURATION_MODS[m[1]]}" if m[1]}" if d.whole_notes == r
            elsif (m = v.to_s.match(/\A(\d+) (bar|beat)s?\z/))
              unit = m[1] == '1' ? m[2] : "#{m[2]}s"
              return "#{m[1]}.#{unit}" if m[1].to_i.public_send(unit).whole_notes == r
            end

            DURATION_DENOMINATORS.each do |n|
              k = r * n
              next unless k.denominator == 1
              return "#{k.to_i}.n#{n}"
            end
            "Sequence::Duration.new(#{num(r)})"
          end

          def phase_text(v, indent)
            if (deg = v.instance_variable_get(:@degrees))
              unit_value(deg, 'degrees', indent)
            elsif (rad = v.instance_variable_get(:@radians))
              unit_value(rad, 'radians', indent)
            else
              unit_value(v.cycles, 'cycles', indent)
            end
          end

          # A Note's name (A3, Cs4) when it rebuilds the same note, else
          # its frequency in Hz.
          # A Scale as the top-level call that makes it: `scale(:minor, A4)`.
          def scale_text(s)
            return fixme("a Scale with a period of #{s.period}") unless s.period == 12
            list = s.name && MB::Sound::Scale::OFFSETS[MB::Sound::Scale::ALIASES.fetch(s.name, s.name)] == s.offsets ? s.name.inspect : leaf(s.offsets, '')
            root = s.root.is_a?(Integer) ? pitch_text(MB::Sound::Note.new(s.root)) : num(s.root)
            "scale(#{list}, #{root})"
          end

          # A rest or tie step, or a note with marks (`!A1`, `~C2`,
          # `G2.chance(0.5)`; other steps print through their recipes).
          def step_text(v)
            return 'Rest' if v.equal?(MB::Sound::Rest)
            return 'Tie' if v.equal?(MB::Sound::Tie)
            marked_step_text(v) || fixme("can't print a #{v.class} (#{v.to_h.compact.inspect})")
          end

          # The marks of a note step as Ruby (`~!A1.chance(0.5).every(2)`),
          # checked by building the step again, or nil.
          def marked_step_text(v)
            return nil if v.clip || v.length || v.legato || v.tie || v.value.nil?
            return nil unless v.value.is_a?(Integer) && v.value.between?(0, 127)

            note = MB::Sound::Note.new(v.value)
            base = pitch_text(note)
            return nil unless base.match?(/\A([A-G]|Note\.new\()/)

            # Applied innermost first, as `~!A1.chance(p)` evaluates
            suffix = []
            rebuilt = note
            unrecorded_calls {
              if v.probability
                suffix << ".chance(#{num(v.probability)})"
                rebuilt = rebuilt.chance(v.probability)
              end
              if v.condition
                n, from = v.condition
                suffix << (from == 1 ? ".every(#{n})" : ".every(#{n}, from: #{from})")
                rebuilt = rebuilt.every(n, from: from)
              end
              if v.fill_mark
                mode, name = v.fill_mark
                suffix << ".#{mode}#{"(#{name.inspect})" if name}"
                rebuilt = rebuilt.public_send(mode, name)
              end
              if v.pitch
                suffix << ".pitch(#{num(v.pitch)})"
                rebuilt = rebuilt.pitch(v.pitch)
              end
              if v[:flam]
                suffix << (v[:flam] == true ? '.flam' : ".flam(#{num(v[:flam])})")
                rebuilt = rebuilt.flam(v[:flam])
              end
              rebuilt = MB::Sound::Sequence::Seq.step(rebuilt)
              prefix = ''
              if v.accented
                rebuilt = rebuilt.accent
                prefix = '!'
              end
              if v.slid == true
                rebuilt = rebuilt.slide
                prefix = "~#{prefix}"
              elsif v.slid
                suffix << ".slide(#{num(v.slid)})"
                rebuilt = rebuilt.slide(v.slid)
              end
              return nil unless rebuilt == v
              # Method calls bind before unary marks; .slide(x) must come last
              if v.slid && v.slid != true && !prefix.empty?
                return "(#{prefix}#{base}#{suffix[0...-1].join})#{suffix[-1]}"
              end
              return "#{prefix}#{base}#{suffix.join}"
            }
          end

          # An unattached MIDI transform chain as the calls that make it:
          # `echo(3.n16, 3, pitch: 7.st).strum(20.ms)`.
          def transform_spec_text(spec, indent)
            return fixme('an empty MIDI transform chain') if spec.steps.empty?
            first = true
            spec.steps.map { |name, args, kwargs, block|
              return fixme("a MIDI transform chain with a #{name} block") if block
              unless !first || MB::Sound.respond_to?(name)
                return fixme("a MIDI transform chain starting with #{name}")
              end
              first = false
              parts = args.map { |a| value(a, indent) } + kwargs.map { |k, x| "#{key_text(k)} #{value(x, indent)}" }
              "#{name}#{"(#{parts.join(', ')})" unless parts.empty?}"
            }.join('.')
          end

          # Runs the block without recording its calls.
          def unrecorded_calls
            st = Recipe.state
            st.depth += 1
            begin
              yield
            ensure
              st.depth -= 1
            end
          end

          # events(...) of a clip without a recipe (see
          # SequenceMethods#events), or a FIXME for one with per-cycle
          # variations (code, not data).
          def clip_events_text(clip, indent)
            unless clip.variations.empty?
              return fixme("a clip without a recipe that has per-cycle variations (#{clip.variations.map(&:name).join(', ')})")
            end
            rows = clip.events.map { |e|
              marks = MB::Sound::SequenceMethods::EVENT_MARKS.to_h { |k| [k, e[k]] }.compact
              [e.start, e.length, e.value, e.velocity, *(marks.empty? ? [] : [marks])]
            }
            kwargs = { length: clip.length }
            kwargs[:loop] = true if clip.looping?
            kwargs[:seed] = clip.seed unless clip.seed == 0
            kwargs[:align] = clip.align unless clip.align == :timeline
            kwargs[:performed] = true if clip.performed?
            text = events_text(rows, kwargs, indent)
            text += ".named(#{clip.name.inspect})" if clip.named?
            text
          end

          # events(rows..., kwargs) with one event per line.
          def events_text(rows, kwargs, indent)
            row_texts = rows.map { |r| event_row_text(r, indent) }
            kw = kwargs.map { |k, v| "#{key_text(k)} #{k == :length ? event_number(v) : value(v, indent)}" }
            parts = row_texts + (kw.empty? ? [] : [kw.join(', ')])
            return "events(#{parts.join(', ')})" if row_texts.length <= 2 && parts.join(', ').length < 80

            inner = indent + '  '
            "events(\n#{parts.map { |t| "#{inner}#{t}" }.join(",\n")}\n#{indent})"
          end

          def event_row_text(row, indent)
            return value(row, indent) unless row.is_a?(Array)

            start, len, val, vel, marks = row
            items = [event_number(start), event_number(len), val.is_a?(Numeric) ? event_number(val) : value(val, indent), event_number(vel)]
            items << value(marks, indent) if marks
            "[#{items.join(', ')}]"
          end

          # A number exactly, never as dB (velocities, positions).
          def event_number(n)
            n.is_a?(Float) && n.finite? ? n.to_s : num(n)
          end

          def pitch_text(p)
            if p.instance_of?(MB::Sound::Note)
              name = p.to_s
              if name.match?(/\A[A-G][sb]?\d+\z/)
                n = MB::Sound::Note.new(name) rescue nil
                return name if n && n.frequency == p.frequency
              elsif name.match?(/\A[A-G][sb]?-\d+\z/) && p.number == p.number.round
                # Octave -1 has no constant (Fs-1 would be Fs minus 1)
                n = MB::Sound::Note.new(p.number.round)
                return "Note.new(#{p.number.round})" if n.frequency == p.frequency
              end
            end
            unless p.constant?
              # A tempo-synced pitch (`1.bar.hz`) prints as its duration (it
              # printed its frequency at the current tempo before
              # 2026-10-13, losing the tempo sync; patches-1)
              src = p.freq
              if src.is_a?(MB::Sound::Sequence::TempoNode) && src.mode == :hz && !src.freewheel?
                return "#{duration_text(src.duration)}.hz"
              end
              return fixme("a #{p.class} with a node frequency") unless src.is_a?(Constant)
            end
            f = p.frequency
            return fixme("a #{p.class} with a node frequency") unless f.is_a?(Numeric)
            f = f.to_i if f.is_a?(Float) && f == f.round && f.abs < 1e15 && f.to_i.hz.frequency.eql?(f)
            "#{num(f)}.hz"
          end

          def wavetable_text(t)
            name = t.name
            if name
              cached = MB::Sound::Wavetable.instance_variable_get(:@cache)&.[](name.to_sym)
              return "Wavetable[#{name.to_sym.inspect}]" if cached.equal?(t)
            end
            if @assets && (asset = @assets.wavetable(t))
              return "Wavetable[#{asset.inspect}]"
            end
            fixme("a Wavetable#{" (#{name})" if name} that isn't a library table (bundles save it as a file: GraphIO.save(..., bundle: true))")
          end

          # A Sample: the calls that cut or edited it (Sample#lineage) on its
          # origin, which prints as an asset in bundles (or its file).
          def sample_text(s, indent)
            # Edits (new audio: bits, lofi, stretch, mono) save as assets in
            # bundles, so loading neither redoes them nor rounds differently
            if @assets && s.lineage && MB::Sound::Sample::EDITS.include?(s.lineage[1]) && (asset = @assets.sample(s))
              return "Sample[#{asset.inspect}]"
            end
            if s.lineage
              parent, name, args, kwargs = s.lineage
              return "#{lineage_receiver(parent, indent)}#{lineage_call(name, args, kwargs, indent)}"
            end
            if @assets && (asset = @assets.sample(s))
              return "Sample[#{asset.inspect}]"
            end
            return "Sample[#{s.file.inspect}]" if s.file

            fixme("a Sample made from audio in memory (bundles save it as a file: GraphIO.save(..., bundle: true))")
          end

          def slices_text(s, indent)
            return fixme('Slices without a recipe') unless s.lineage
            parent, name, args, kwargs = s.lineage
            "#{lineage_receiver(parent, indent)}#{lineage_call(name, args, kwargs, indent)}"
          end

          # An Instrument: from slices (keymap) or an SFZ file; others print
          # as a FIXME for now.
          def instrument_text(i, indent)
            if i.lineage
              parent, name, args, kwargs = i.lineage
              if parent == :sfz
                extra = kwargs.map { |k, v| ", #{key_text(k)} #{value(v, indent)}" }.join
                return "sfz(#{leaf(args[0], indent)}#{extra})"
              end
              return "#{lineage_receiver(parent, indent)}#{lineage_call(name, args, kwargs, indent)}"
            end
            instrument_block_text(i, indent)
          end

          # An Instrument built region by region, as its constructor with a
          # block of `i.region` calls (only settings that differ from
          # Instrument#region's defaults).
          def instrument_block_text(inst, indent)
            kw = {}
            kw[:split] = inst.split if inst.split
            kw[:mips] = inst.mips unless inst.mips == :default
            kw[:envelope] = inst.envelope if inst.envelope
            kw[:name] = inst.name if inst.name
            args = kw.map { |k, v| "#{key_text(k)} #{value(v, indent)}" }
            inner = "#{indent}  "
            lines = inst.regions.map { |r|
              opts = {}
              opts[:keys] = r.keys[0]..r.keys[1] unless r.keys == [0, 127]
              opts[:vel] = r.vel[0]..r.vel[1] unless r.vel == [0, 127]
              opts[:seq] = r.seq if r.seq
              opts[:rand] = r.rand[0]...r.rand[1] if r.rand
              opts[:root] = r.root if r.root
              opts[:keytrack] = r.keytrack unless r.keytrack == 1
              opts[:veltrack] = r.veltrack unless r.veltrack == 0
              opts[:tune] = r.tune unless r.tune == 0
              opts[:gain] = r.gain unless r.gain == 1
              opts[:offset] = r.offset unless r.offset == 0
              list = [value(r.sample, inner)] + opts.map { |k, v| "#{key_text(k)} #{value(v, inner)}" }
              "#{inner}i.region(#{list.join(', ')})"
            }
            head = args.empty? ? 'Sampler::Instrument.new' : "Sampler::Instrument.new(#{args.join(', ')})"
            "#{head} { |i|\n#{lines.join("\n")}\n#{indent}}"
          end

          # (Samples, Slices, and Instruments print as postfix chains, so
          # they need no parentheses as receivers)
          def lineage_receiver(parent, indent)
            leaf(parent, indent)
          end

          def lineage_call(name, args, kwargs, indent)
            list = args.map { |a| value(a, indent) } + kwargs.map { |k, v| "#{key_text(k)} #{value(v, indent)}" }
            return "[#{list.join(', ')}]" if name == :[]
            list.empty? ? ".#{name}" : ".#{name}(#{list.join(', ')})"
          end

          # A number: Decibels as k.db, and Float gains that are exactly k/10
          # dB as k.db too.
          def num(n)
            case n
            when Integer then n.to_s
            when Float
              return 'Float::INFINITY' if n == Float::INFINITY
              return '-Float::INFINITY' if n == -Float::INFINITY
              return 'Float::NAN' if n.nan?
              if n > 0 && n.to_s.length > 8 && (db = (20 * Math.log10(n) * 10).round / 10.0) && db.db == n
                db = db.to_i if db == db.to_i
                "#{db}.db"
              else
                n.to_s
              end
            when Rational
              n.denominator == 1 ? "#{n.numerator}r" : "#{n.numerator}r/#{n.denominator}"
            when MB::Sound::Decibels
              d = num(n.decibels)
              d.include?('/') || d.include?('::') ? "(#{d}).db" : "#{d}.db"
            when Complex
              "Complex(#{num(n.real)}, #{num(n.imaginary)})"
            else n.inspect
            end
          end
        end

        class << self
          # Local variables from the code around +block+ that its source
          # text +src+ reads (it can't be printed on its own).
          def outer_locals(block, src)
            return [] if block.respond_to?(:graph_io_source)
            outer = block.binding.local_variables
            return [] if outer.empty?

            require 'prism'
            names = []
            walk = ->(node) {
              return if node.nil?
              if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.variable_call?
                names << node.name
              elsif node.is_a?(Prism::LocalVariableReadNode) && node.depth > 0
                names << node.name
              end
              node.compact_child_nodes.each { |n| walk.(n) }
            }
            walk.(Prism.parse(src).value)
            (names & outer).uniq
          rescue StandardError
            []
          end

          # The source text of +block+ (a `{ ... }`/`do ... end` literal or a
          # lambda literal) from the file it was written in, found with Prism
          # from its source location; +call_name+ picks among several blocks
          # on one line.  nil if not found (e.g. eval'd code).
          def block_source(block, call_name = nil)
            # Blocks loaded from graph documents keep their text
            return block.graph_io_source if block.respond_to?(:graph_io_source)

            file, line = block.source_location
            return nil unless file && File.file?(file)

            require 'prism'
            @parsed ||= {}
            tree = (@parsed[file] ||= Prism.parse_file(file).value)
            found = []
            walk = ->(node, parent) {
              return if node.nil?
              if (node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)) && node.location.start_line == line
                found << [node, parent]
              end
              node.compact_child_nodes.each { |n| walk.(n, node) }
            }
            walk.(tree, nil)
            return nil if found.empty?

            if found.length > 1 && call_name
              named = found.select { |_, parent| parent.is_a?(Prism::CallNode) && parent.name == call_name }
              found = named unless named.empty?
            end
            return nil if found.length > 1 && found.map { |n, _| n.slice }.uniq.length > 1

            found[0][0].slice
          end
        end
      end
    end
  end
end

module MB
  module Sound
    class Arrangement
      # Live literals (envelope-view-1; design/notes/sound_design_ui.md,
      # Live literals): a number written in a track's patch (a literal
      # like `resonance: 0.25`, an envelope time) or a graph document's
      # param that no knob drives becomes turnable.  `bind :bass, lp4:
      # :resonance` makes a knob (:"bass/reso", ranged from the Param
      # names table at the literal's value), and the track's patch is
      # built again with `knob(:"bass/reso")` in that argument's place
      # (Recipe.substituting: the same block runs, the call gets the knob)
      # and swapped in at the track's launch point, keeping its routing,
      # through the journal (undoable: the old patch and graph come back;
      # replayed from takes, since the line names the literal by where its
      # call was made).  A document param is bound like a `preset` keyword
      # (`preset :dnb_reese, midi: c, cutoff: :"bass/cutoff"`).
      #
      # The new graph takes the old one's running state on the swap frame
      # (Session::Carry, sound-design-2: held notes play on with their
      # phases, envelope stages and levels, and filter states; delays and
      # reverbs start fresh behind a short crossfade).
      module LiteralBinding
        # Where a literal is: +kind+ :call (an argument of a recorded DSL
        # call: +call_name+ its method's name, +nth+ which of the patch's calls of that
        # name (in the order the patch makes them), +key+ (Recipe.key_of), +slot+ [:arg, index]
        # or [:kw, name]) or :document (a graph document's param: +document+
        # its name), +param+ the param's name, +value+ the literal.
        #
        # Since sound-design-2 a slot may end in a path into a list
        # argument ([:arg, 0, [1, 1]]: the second segment's time of
        # `env([[level, time, curve], ...])`), and the call may be a chained
        # setter's (`.curve(release: 30)`, a config call of the node);
        # +arg+ is the argument's name in the call (:release), +param+ the
        # name the inspector and the knob use (:release_curve).
        Target = Data.define(:kind, :call_name, :nth, :key, :slot, :param, :value, :document, :arg) do
          def initialize(kind:, call_name:, nth:, key:, slot:, param:, value:, document:, arg: nil)
            super(kind: kind, call_name: call_name, nth: nth, key: key, slot: slot, param: param, value: value, document: document, arg: arg || param)
          end
        end

        # A literal that can't be bound, with the reason.
        class Error < ArgumentError; end

        # Values that count as literals: numbers, pitches, fixed lengths in
        # seconds or samples (not Durations: they follow the tempo).
        def self.literal?(v)
          return false if v.is_a?(GraphNode) && !v.is_a?(Pitch)
          return v.fixed? if v.is_a?(Length::Seconds) || v.is_a?(Length::Samples)
          return false if v.is_a?(Sequence::Duration)
          v.is_a?(Numeric) || v.is_a?(Pitch)
        end

        # Param names that count things (voices, copies, taps, ...): read
        # once while a patch builds, so an Integer given to one is shown
        # read-only, never bound (the maintainer, 2026-10-27).
        COUNT_NAMES = %i[voices spares count copies taps bands steps stages order lanes size n].freeze

        # True for a count-like literal (see COUNT_NAMES; also names the
        # Param names table ranges in Integer steps).
        def self.count?(param, value)
          return false unless value.is_a?(Integer)
          return true if COUNT_NAMES.include?(param)
          r = Param.name_entry(param)&.dig(:range)
          r.is_a?(Range) && r.begin.is_a?(Integer)
        end

        module_function

        # The nodes of graph +roots+, each once.
        def nodes(roots)
          roots.flat_map { |r| [r, *(r.respond_to?(:graph) ? r.graph : [])] }.uniq(&:__id__)
        end

        # The recorded Call that made +node+, or nil.
        #
        # A node a per-channel call made (an lp4 on a stereo bundle: the
        # call is recorded on the bundle it returned) gives that bundle's
        # call, and a unison's mixer its unison call (sound-design-nav-1;
        # GraphNode::ChannelGroup#bundle, ChannelMixer::Unison#recipe_bundle).
        def call_of(node)
          own_call_of(node) || bundle_call_of(node)
        end

        # True if +node+ has a recorded call of its own (not its bundle's).
        def own_call?(node) = !own_call_of(node).nil?

        def own_call_of(node)
          node.instance_variable_defined?(:@graph_recipe) ? node.instance_variable_get(:@graph_recipe)&.call : nil
        end

        def bundle_call_of(node)
          bundle = node.respond_to?(:recipe_bundle) ? node.recipe_bundle : node.respond_to?(:channel_group) && node.channel_group&.bundle
          return nil unless bundle && !bundle.equal?(node) && bundle.instance_variable_defined?(:@graph_recipe)
          bundle.instance_variable_get(:@graph_recipe)&.call
        end

        # The call keys of +method+'s calls in graph +roots+, in the order
        # the patch made them (by Call#seq: the same from any root, and when
        # the patch builds again).
        def keys_of(roots, method, all: nil)
          seqs = {}
          (all || nodes(roots)).each do |n|
            calls_of(n).each do |c|
              next unless (c.written || c.name) == method
              k = GraphNode::Recipe.key_of(c) or next
              seqs[k] = c.seq if seqs[k].nil? || c.seq < seqs[k]
            end
          end
          seqs.sort_by { |_, seq| seq }.map(&:first)
        end

        # The recorded calls of +node+: the call that made it, then its
        # chained setters' (config calls: `.curve(release: 30)`), in order.
        def calls_of(node)
          c = call_of(node) or return []
          own_call?(node) ? [c, *GraphNode::Recipe.config_of(node)] : [c]
        end

        # The Target for param +param+ of +node+ in graph +roots+ (see
        # Target), or raises Error saying why it can't be bound.  +all+ is
        # .nodes(roots) if the caller has it (it walks the graph).
        def target(roots, node, param, all: nil)
          param = param.to_sym
          if (doc = document_param(roots, node, param))
            return doc
          end

          call = call_of(node) or raise Error, unrecorded(roots, param)
          # (a call reached through a bundle inside a graph document: the
          # document's numbers are fixed, its params bind)
          raise Error, unrecorded(roots, param) if !own_call?(node) && roots.any? { |r| GraphIO.document_of(r) }
          # (a chained setter's argument: :release_curve is .curve(release: ...))
          arg = param
          unless slot_of(call, param)
            calls_of(node).drop(1).reverse_each do |cc|
              m = (cc.written || cc.name).to_s
              next unless param.to_s.end_with?("_#{m}")
              a = param.to_s.delete_suffix("_#{m}").to_sym
              next unless slot_of(cc, a)
              call = cc
              arg = a
              break
            end
          end
          target_of_call(roots, call, param, arg, all: all)
        end

        # The Target for argument +arg+ of recorded +call+ (named +param+;
        # see Target), or raises Error.
        def target_of_call(roots, call, param, arg = param, all: nil)
          key = GraphNode::Recipe.key_of(call) or raise Error, "#{param}: this graph wasn't built by a track's patch (track :x { |clip| ... } makes one)"
          method = call.written || call.name
          slot = slot_of(call, arg) or raise Error, "#{param} isn't an argument of #{method}(...) (a setting a chained call gave without a name)"
          value = slot_value(call, slot)
          unless LiteralBinding.literal?(value)
            raise Error, "#{param} of #{method} is #{value.is_a?(Sequence::Duration) ? 'a tempo length' : 'not a number'} (#{value.inspect[0, 40]}): only numbers become knobs"
          end
          if LiteralBinding.count?(arg, value)
            raise Error, "#{param} of #{method} is a count (#{value}; read once while the patch builds): shown read-only, no knob"
          end
          nth = keys_of(roots, method, all: all).index(key) or raise Error, "#{method} isn't in the track's graph"
          Target.new(kind: :call, call_name: method, nth: nth, key: key, slot: slot, param: param, value: value, document: nil, arg: arg)
        end

        # The value at +slot+ of +call+ (see Target).
        def slot_value(call, slot)
          kind, at, path = slot
          v = kind == :kw ? call.kwargs[at] : call.args[at]
          path ? v.dig(*path) : v
        end

        # +list+ (nested Arrays) with the value at +path+ replaced by +value+
        # (copies along the path).
        def replace_path(list, path, value)
          i, *rest = path
          list.dup.tap { |l| l[i] = rest.empty? ? value : replace_path(l[i], rest, value) }
        end

        # The literals a node's code wrote that #param_info doesn't name, as
        # [[param, value], ...]: the arguments of its recorded call (by
        # keyword or positional name), the curves of a segment list
        # (`env([[1, 0.01, 30], ...])`: :t1_curve), and its chained setters'
        # (`.curve(release: 30)`: :release_curve).  Values may be anything:
        # callers keep the numbers (LiteralBinding.literal?).
        def literals(node)
          call = call_of(node) or return []
          names = positional_names(call) || []
          out = call.args.each_with_index.filter_map { |v, i| names[i] && [names[i], v] } + call.kwargs.to_a
          if (segs = segment_list(call))
            segs.each_with_index { |row, i| out << [:"t#{i + 1}_curve", row[2]] if row.is_a?(Array) && row.length > 2 }
          end
          if own_call?(node)
            GraphNode::Recipe.config_of(node).each do |cc|
              m = cc.written || cc.name
              cn = positional_names(cc) || []
              cc.args.each_with_index { |v, i| out << [:"#{cn[i]}_#{m}", v] if cn[i] }
              cc.kwargs.each { |k, v| out << [:"#{k}_#{m}", v] }
            end
          end
          out
        end

        # An envelope call's segment list (`env([[level, time, curve,
        # shape], ...])`: its first argument, an Array of Arrays), or nil.
        def segment_list(call)
          a = call.args[0]
          a.is_a?(Array) && !a.empty? && a.all? { |r| r.is_a?(Array) } ? a : nil
        end

        # The Target for the +nth+ call of +method+ in graph +roots+ and its
        # param +param+ (what `bind :bass, lp4: :resonance, nth: 1` names).
        def find(roots, method, param, nth = 0)
          key = keys_of(roots, method)[nth] or raise Error, missing(roots, method, param, nth)
          node = call = nil
          nodes(roots).each do |n|
            call = calls_of(n).find { |c| GraphNode::Recipe.key_of(c) == key } and (node = n) and break
          end
          return target(roots, node, param) if call.equal?(call_of(node))
          # (a chained setter's argument, named after it: .curve(release:) is :release_curve)
          raise Error, unrecorded(roots, param) if roots.any? { |r| GraphIO.document_of(r) }
          target_of_call(roots, call, :"#{param}_#{call.written || call.name}", param)
        end

        # A document param of the graph: +param+ of +node+ is a Constant
        # named after a param of the Document a root was loaded from.
        def document_param(roots, node, param)
          src = node.respond_to?(:sources) ? node.sources[param] : nil
          src = GraphNode.climb_tee_tree(src) if src
          return nil unless src.is_a?(GraphNode::Constant) && src.named?
          name = src.graph_node_name.to_sym
          doc = roots.lazy.filter_map { |r| GraphIO.document_of(r) }.first
          return nil unless doc && doc.params.key?(name)
          Target.new(kind: :document, call_name: nil, nth: nil, key: nil, slot: nil, param: name, value: src.constant, document: doc.name.to_s)
        end

        # A document param by name in graph +roots+ (`bind :bass, :cutoff`).
        def find_document(roots, param)
          doc = roots.lazy.filter_map { |r| GraphIO.document_of(r) }.first
          raise Error, "the track's graph has no document param #{param.inspect} (bind :x, method: :param for a literal)" unless doc && doc.params.key?(param)
          c = nodes(roots).find { |n| n.is_a?(GraphNode::Constant) && n.named? && n.graph_node_name.to_sym == param }
          value = c ? c.constant : doc.params[param][:value]
          Target.new(kind: :document, call_name: nil, nth: nil, key: nil, slot: nil, param: param, value: value, document: doc.name.to_s)
        end

        # The argument of +call+ that param +param+ is: a keyword of that
        # name, or a positional argument named so in the DSL method's
        # parameters.  Nil if neither.
        def slot_of(call, param)
          return [:kw, param] if call.kwargs.key?(param)
          names = positional_names(call)
          i = names&.index(param)
          return [:arg, i] if i && i < call.args.length
          # (a segment list's level, time, or curve: :t2, :t2_level, :t2_curve)
          if (segs = segment_list(call)) && (m = param.to_s.match(/\At(\d+)(_level|_curve)?\z/))
            row = m[1].to_i - 1
            col = { nil => 1, '_level' => 0, '_curve' => 2 }[m[2]]
            return [:arg, 0, [row, col]] if row >= 0 && segs[row] && segs[row].length > col
          end
          nil
        end

        # The positional parameter names of +call+'s DSL method (past the
        # recorders, whose parameters are *args, **kwargs).
        def positional_names(call)
          name = call.written || call.name
          m = call.receiver.method(name) rescue (return nil)
          m = m.super_method while m.super_method && m.parameters.map(&:first) == %i[rest keyrest block]
          if m.parameters.map(&:first) == %i[rest keyrest block] && call.receiver.is_a?(GraphNode::Channels)
            # (a per-channel call on a bundle: the node method it runs)
            m = GraphNode.instance_method(name) rescue (return nil)
            m = m.super_method while m.super_method && m.parameters.map(&:first) == %i[rest keyrest block]
          end
          m.parameters.select { |type, _| type == :req || type == :opt }.map(&:last)
        end

        # The knob name for a binding of +param+ on track +track+:
        # :"bass/reso" (the Param names table's short alias where it has
        # one: resonance -> reso, frequency -> freq, quality -> q).
        SHORT = { resonance: :reso, frequency: :freq, quality: :q }.freeze

        def knob_name(track, param)
          :"#{track}/#{SHORT[param] || param}"
        end

        # The knob default for literal +value+ of param +param+: a ranged
        # default `(lo..hi).at(value)` from the Param names table (the
        # value given its unit: seconds for times, Hz for pitches), widened
        # to hold the value; else a range around it.
        def knob_default(param, value, range = nil)
          v = value.is_a?(Pitch) ? value.frequency.to_f.hz : value
          v = v.to_f if v.is_a?(Length::Samples) || (v.is_a?(Numeric) && !v.is_a?(Length) && !v.is_a?(Decibels))
          entry = Param.name_entry(param) || envelope_entry(param)
          r = range || entry&.dig(:range)
          if r && !r.begin.is_a?(Float) && !r.begin.is_a?(Integer) && v.is_a?(Float)
            # (a typed range: the literal in its unit)
            v = Param.retype(r.begin, v) rescue (r = nil)
          end
          r ||= v.to_f == 0 ? 0.0..1.0 : (v.to_f > 0 ? 0.0..(v.to_f * 4) : (v.to_f * 4)..0.0)
          lo = Param.magnitude(r.begin)
          hi = Param.magnitude(r.end)
          m = Param.magnitude(v)
          r = (m < lo ? Param.retype(r.begin, m) : r.begin)..(m > hi ? Param.retype(r.end, m) : r.end) if m < lo || m > hi
          r = r.begin.to_f..r.end.to_f if r.begin.is_a?(Integer) && v.is_a?(Float)
          r.at(v)
        end

        # Ranges for envelope point literals no names-table entry covers
        # (sound-design-2's envelope editor): a segment list's times (:t2,
        # an attack's range), levels (:t2_level, 0..1, widened to hold the
        # value), and curves (:t2_curve, :release_curve: -60..60 dB).
        def envelope_entry(param)
          case param.to_s
          when /\At\d+\z/ then Param.name_entry(:attack)
          when /\At\d+_level\z/ then { range: 0.0..1.0 }
          when /_curve\z/ then { range: -60.0..60.0 }
          end
        end

        # The console line binding Target +t+ on track +track+.
        def line(track, t)
          return "bind #{track.inspect}, #{t.param.inspect}" if t.kind == :document
          "bind #{track.inspect}, #{t.call_name}: #{t.arg.inspect}#{", nth: #{t.nth}" if t.nth > 0}"
        end

        # +patch+ (a track's patch block) built with Target +t+'s literal
        # replaced by knob +kname+ (read as Session.current's knob of that
        # name, so rehearsal sandboxes read their copies): a block like the
        # patch (arity, parameters, source location), remembering what it
        # binds (#literal_bindings) and the patch it wraps (#unbound_patch).
        #
        # +knob+ (a GraphNode::Knob) stands in for the new binding's knob
        # instead (bind_literal's test build, before the knob exists).
        def wrap(patch, t, kname, knob: nil)
          bindings = (patch.respond_to?(:literal_bindings) ? patch.literal_bindings : []) + [[t, kname]]
          stand_in = ->(kn) { knob && kn == kname ? knob : nil }
          base = patch.respond_to?(:unbound_patch) ? patch.unbound_patch : patch
          subs = {}
          docs = {}
          bindings.each do |tt, kn|
            if tt.kind == :document
              (docs[tt.document] ||= {})[tt.param] = stand_in.(kn) || kn
            else
              kind, at, path = tt.slot
              rule = subs[tt.key] # (two literals of one call: both)
              subs[tt.key] = ->(args, kwargs) {
                args, kwargs = rule.call(args, kwargs) if rule
                k = stand_in.(kn) || Session.current.knob(kn)
                if kind == :kw
                  [args, kwargs.merge(at => path ? replace_path(kwargs[at], path, k) : k)]
                else
                  [args.dup.tap { |a| a[at] = path ? replace_path(a[at], path, k) : k }, kwargs]
                end
              }
            end
          end
          subs.freeze
          docs.freeze
          wrapped = proc do |*a, **kw, &b|
            LiteralBinding.with_documents(docs) {
              GraphNode::Recipe.substituting(subs) { kw.empty? ? base.call(*a, &b) : base.call(*a, **kw, &b) }
            }
          end
          wrapped.define_singleton_method(:arity) { base.arity }
          wrapped.define_singleton_method(:parameters) { |**k| base.parameters(**k) }
          wrapped.define_singleton_method(:lambda?) { base.lambda? }
          wrapped.define_singleton_method(:source_location) { base.source_location }
          bindings = bindings.freeze
          wrapped.define_singleton_method(:literal_bindings) { bindings }
          wrapped.define_singleton_method(:unbound_patch) { base }
          wrapped.define_singleton_method(:patch_block) { base.respond_to?(:patch_block) ? base.patch_block : base }
          wrapped.define_singleton_method(:patch_context) { |&blk| LiteralBinding.with_documents(docs) { GraphNode::Recipe.substituting(subs, &blk) } }
          wrapped
        end

        # Runs the block with graph documents' params bound to knob names
        # (+docs+: { document name => { param => knob name } }), as if each
        # `preset` of that document had been given them.
        def with_documents(docs)
          return yield if docs.empty?
          old = Thread.current[:mb_sound_bound_document_params]
          Thread.current[:mb_sound_bound_document_params] = old ? old.merge(docs) { |_, a, b| a.merge(b) } : docs
          begin
            yield
          ensure
            Thread.current[:mb_sound_bound_document_params] = old
          end
        end

        # The bound params for document +name+ (see .with_documents), or nil.
        def document_params(name)
          Thread.current[:mb_sound_bound_document_params]&.[](name.to_s)
        end

        # A short description of +node+ for messages.
        # Why the +nth+ call of +method+ isn't found: a preset's text
        # (whose calls aren't recorded) or a name not in the graph.
        def missing(roots, method, param, nth)
          return unrecorded(roots, param) if keys_of(roots, method).empty? && roots.any? { |r| GraphIO.document_of(r) }
          "no #{method}#{" ##{nth}" if nth > 0} in the track's graph#{suggestion(roots, method)}"
        end

        # Why +param+ of a node with no recorded call can't be bound, in
        # the user's terms (never a node class name): a preset's literals
        # are fixed in its text, and only its params bind.
        def unrecorded(roots, param)
          doc = roots.lazy.filter_map { |r| GraphIO.document_of(r) }.first
          return "#{param}: not set by the track's code (nothing to bind)" unless doc
          params = doc.params.keys
          bind = params.empty? ? 'it has no params to bind' : "bind its param#{params.length == 1 ? '' : 's'} instead: #{params.join(', ')}"
          "#{param} is fixed in the #{doc.name} preset; #{bind}"
        end

        def suggestion(roots, method)
          names = nodes(roots).filter_map { |n| (c = call_of(n)) && (c.written || c.name).to_s }.uniq
          s = DidYouMean::SpellChecker.new(dictionary: names).correct(method.to_s).first
          s ? " (did you mean #{s}?)" : ''
        end
      end

      # Binds a literal of track +name+'s patch to a new knob (see
      # LiteralBinding; ArrangementMethods#bind is the console command),
      # at +point+ (a LaunchPoint; the track's launch quantization by
      # default).  +what+ is a document param's name (Symbol) or { method
      # => param }; +nth+ which of the patch's calls of that method; +as+
      # the knob's name; +range+ its range.  Returns the journal entry of
      # the swap.
      def bind_literal(name, what, nth: 0, as: nil, range: nil, point: LaunchPoint::NONE, fade: nil)
        tr = tracks[name] or return MB::Sound.live_error(ArgumentError.new("No track #{name.inspect}#{track_hint}"))
        unless tr.patch?
          return MB::Sound.live_error(LiteralBinding::Error.new("#{name} plays a graph, not a patch: nothing to rebuild (track #{name.inspect} { |clip| ... } makes one)"))
        end
        input = @session.playing_after_queue?(name) && @session.ui_graphs[name]
        unless input
          return MB::Sound.live_error(LiteralBinding::Error.new("#{name} isn't playing: bind finds its literals in the graph it plays (bg #{name.inspect}, clip)"))
        end
        roots = UI::Inspect.roots(input)
        doc = roots.lazy.filter_map { |r| GraphIO.document_of(r) }.first
        follow = nil
        # (library-instruments-1: a preset's param following an existing
        # knob, `bind :bass, cutoff: :cut`; params already the track's knobs
        # (TrackKnobs); the guess `bind :bass, :cut`)
        if what.is_a?(Hash) && what.length == 1 && doc && doc.params.key?(what.keys.first.to_sym) && what.values.first.is_a?(Symbol)
          follow = what.values.first
          unless @session.knobs[follow]
            return MB::Sound.live_error(LiteralBinding::Error.new("bind #{name.inspect}, #{what.keys.first}: #{follow.inspect}: no knob #{follow.inspect}#{GraphIO.suggest(follow, @session.knobs.keys)} (knob #{follow.inspect}, ... makes one)"))
          end
          what = what.keys.first.to_sym
        elsif what.is_a?(Symbol) && doc && doc.params.key?(what) && reads_knob?(roots, TrackKnobs.knob_name(name, what))
          kn = TrackKnobs.knob_name(name, what)
          puts "\e[2m#{name}'s #{what} is already knob #{kn.inspect}: turn #{kn.inspect}, ...; bind #{name.inspect}, #{what}: :other follows another knob\e[0m"
          return kn
        elsif what.is_a?(Symbol) && doc && !doc.params.key?(what) && @session.knobs[what] && !doc.params.empty?
          ps = doc.params.keys
          # (the params whose range holds the knob's value, if any: a cutoff for knob :cut at 2400 Hz)
          value = @session.knobs[what].value
          fits = ps.select { |n| (r = doc.params[n][:range]).is_a?(Range) && Param.magnitude(r.begin).to_f <= value && value <= Param.magnitude(r.end).to_f }
          ps = fits unless fits.empty?
          line = ps.length == 1 ? "bind #{name.inspect}, #{ps.first}: #{what.inspect}" : "bind #{name.inspect}, <param>: #{what.inspect} (params: #{ps.join(', ')})"
          return MB::Sound.live_error(LiteralBinding::Error.new("bind #{name.inspect}, #{what.inspect}: #{what.inspect} is a knob, not a param of #{doc.name} (did you mean #{line}?)"))
        end
        t =
          begin
            if what.is_a?(Hash)
              raise LiteralBinding::Error, "bind takes one method: :param (got #{what.inspect})" unless what.length == 1
              method, param = what.first
              LiteralBinding.find(roots, method.to_sym, param.to_sym, nth)
            else
              LiteralBinding.find_document(roots, what.to_sym)
            end
          rescue LiteralBinding::Error => e
            return MB::Sound.live_error(e)
          end

        kname = (follow || as || LiteralBinding.knob_name(name, t.param)).to_sym
        default = LiteralBinding.knob_default(t.param, t.value, range)
        k = @session.knobs[kname]
        if k && !follow && (k.value - Param.magnitude(default.default).to_f).abs > 1e-9 * [1.0, k.value.abs].max
          return MB::Sound.live_error(LiteralBinding::Error.new("knob #{kname.inspect} is at #{k.value}, not #{name}'s #{t.param} (#{Param.literal(default.default)}): give as: another name"))
        end

        # A test build with a stand-in knob first: the patch must build and
        # read the knob (a count or a setting read once while building
        # can't follow one), else nothing changes
        # (a document param's stand-in is a Constant: preset would adopt a
        # Knob into the session)
        probe = t.kind == :document ? GraphNode::Constant.new(Param.magnitude(default.default).to_f, sample_rate: 48000) : GraphNode::Knob.new(kname, default)
        begin
          built = MB::Sound.keeping_random_state {
            Session.with_context(session: @session) {
              GraphNode::Mixer.with_ring(@session.ring || GraphNode::Mixer.ring_mode) { LiteralBinding.wrap(tr.patch, t, kname, knob: probe).call(tr.clip) }
            }
          }
        rescue ScriptError, StandardError => e
          return MB::Sound.live_error(LiteralBinding::Error.new("#{LiteralBinding.line(name, t)}: the patch raised #{e.class} with #{t.param} as a knob (#{e.message.lines.first.to_s.chomp}); nothing was changed"))
        end
        broots = built.is_a?(GraphNode::Channels) ? built.to_a : [built]
        unless LiteralBinding.nodes(broots).any? { |n| GraphNode.climb_tee_tree(n).equal?(probe) || (n.is_a?(GraphNode::Knob::Reader) && n.knob.equal?(probe)) }
          return MB::Sound.live_error(LiteralBinding::Error.new("#{LiteralBinding.line(name, t)}: #{t.param} is read once while the patch builds, so a knob can't move it; nothing was changed"))
        end
        (@session.knob(kname, default) or return nil) unless k

        entry = nil
        @session.command("bind #{name.inspect} #{t.param} -> #{follow ? 'follows ' : ''}knob #{kname.inspect}") {
          before = undo_state
          @mutex.synchronize { tr.patch = LiteralBinding.wrap(tr.patch, t, kname) }
          time = resolve(tr.q || @quant, tr, point)
          entry = start_track(tr, tr.clip, time, fade, carry: true)
          @session.note_undo_extra(self, before, undo_state)
        }
        entry && @session.journal[entry.seq]
      end

      private

      # True if graph +roots+ read Session knob +kname+.
      def reads_knob?(roots, kname)
        LiteralBinding.nodes(roots).any? { |n| n.is_a?(GraphNode::Knob::Reader) && n.knob.name == kname }
      end
    end
  end
end

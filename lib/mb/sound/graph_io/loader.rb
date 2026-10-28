require 'prism'
require 'set'

module MB
  module Sound
    module GraphIO
      # Builds a graph from a graph document (a Ruby subset, see GraphIO) by
      # walking its Prism syntax tree: literals and unit values become
      # values, calls go through Registry and public_send, local variables
      # live in Scopes, build blocks become procs that walk their bodies
      # again for each call.  Nothing is evaluated as Ruby code (the one
      # exception is the opt-in trust: :code for runtime blocks outside the
      # safe subset, in TrustedCode).
      class Loader
        # Variables of one block scope (or the document's top level).
        class Scope
          attr_reader :vars, :parent

          # The object a block without parameters runs on (a drum kit's
          # builder or hit, see Drums::Machine), where receiverless calls go
          # before MB::Sound.
          attr_writer :implicit_self

          # Names bound per application of a rack document (its ports and
          # knobs), read where the body names them; nil elsewhere.
          attr_accessor :bindings

          def initialize(parent = nil)
            @parent = parent
            @vars = {}
            @implicit_self = nil
            @bindings = nil
          end

          # The scope binding +name+ (see #bindings), or nil.
          def binding_scope(name)
            return self if @bindings&.key?(name)
            @parent&.binding_scope(name)
          end

          # The innermost implicit self (see #implicit_self=), or nil.
          def implicit_self
            @implicit_self || @parent&.implicit_self
          end

          # The scope +depth+ levels up (Prism's depth of a local).
          def up(depth)
            s = self
            depth.times { s = s.parent }
            s
          end

          def key?(name)
            @vars.key?(name) || @parent&.key?(name)
          end

          def [](name)
            return @vars[name] if @vars.key?(name)
            @parent&.[](name)
          end

          # Every name visible here (for did_you_mean).
          def names
            (@vars.keys + (@parent&.names || [])).uniq
          end
        end

        # Friendlier names for syntax that documents can't use.
        FORBIDDEN_NODES = {
          'IfNode' => 'if (no flow control in graph documents; use per_voice/per_channel for variations)',
          'UnlessNode' => 'unless (no flow control in graph documents)',
          'CaseNode' => 'case (no flow control in graph documents)',
          'CaseMatchNode' => 'case/in (no flow control in graph documents)',
          'WhileNode' => 'while (no loops in graph documents; use per_voice/per_channel or unison for copies)',
          'UntilNode' => 'until (no loops in graph documents)',
          'ForNode' => 'for (no loops in graph documents)',
          'DefNode' => 'def (no method definitions in graph documents)',
          'ClassNode' => 'class (no class definitions in graph documents)',
          'SingletonClassNode' => 'class << (no class definitions in graph documents)',
          'ModuleNode' => 'module (no module definitions in graph documents)',
          'XStringNode' => 'backticks (no shell commands in graph documents)',
          'InterpolatedXStringNode' => 'backticks (no shell commands in graph documents)',
          'GlobalVariableReadNode' => 'global variables',
          'GlobalVariableWriteNode' => 'global variables',
          'InstanceVariableReadNode' => 'instance variables',
          'InstanceVariableWriteNode' => 'instance variables',
          'ClassVariableReadNode' => 'class variables',
          'ClassVariableWriteNode' => 'class variables',
          'ConstantWriteNode' => 'constant assignment',
          'ConstantPathWriteNode' => 'constant assignment',
          'InterpolatedStringNode' => 'string interpolation',
          'InterpolatedSymbolNode' => 'symbol interpolation',
          'InterpolatedRegularExpressionNode' => 'regular expressions',
          'RegularExpressionNode' => 'regular expressions',
          'AndNode' => '&& / and (no flow control in graph documents)',
          'OrNode' => '|| / or (no flow control in graph documents)',
          'BeginNode' => 'begin/rescue',
          'RescueModifierNode' => 'rescue',
          'YieldNode' => 'yield',
          'ReturnNode' => 'return',
          'BreakNode' => 'break',
          'NextNode' => 'next',
          'RedoNode' => 'redo',
          'RetryNode' => 'retry',
          'SuperNode' => 'super',
          'ForwardingSuperNode' => 'super',
          'SelfNode' => 'self',
          'AliasMethodNode' => 'alias',
          'UndefNode' => 'undef',
          'DefinedNode' => 'defined?',
          'SplatNode' => 'splats (*args)',
          'AssocSplatNode' => 'double splats (**opts)',
          'MultiWriteNode' => 'multiple assignment (a, b = ...)',
          'LocalVariableOperatorWriteNode' => 'operator assignment (x += ...)',
          'LocalVariableOrWriteNode' => 'x ||= ...',
          'LocalVariableAndWriteNode' => 'x &&= ...',
          'CallOperatorWriteNode' => 'operator assignment',
          'IndexOperatorWriteNode' => 'operator assignment',
          'FlipFlopNode' => 'flip-flops',
          'MatchWriteNode' => 'regular expressions',
          'PreExecutionNode' => 'BEGIN { }',
          'PostExecutionNode' => 'END { }',
          'ItLocalVariableReadNode' => 'implicit block parameters (it); name the parameter',
          'NumberedReferenceReadNode' => 'regular expression matches',
          'SourceFileNode' => '__FILE__',
          'SourceLineNode' => '__LINE__',
          'SourceEncodingNode' => '__ENCODING__',
          'StringConcatNode' => 'string concatenation',
        }.freeze

        attr_reader :path, :document

        # +text+ is the document; +path+ its file (for errors and relative
        # file names); +inputs+ binds the document's inputs by name;
        # +params+ overrides its param defaults; +trust+ :code allows
        # runtime blocks outside the safe subset (TrustedCode); +limits+
        # overrides GraphIO::LIMITS.
        def initialize(text, path: nil, inputs: {}, params: {}, trust: nil, limits: {}, base_dir: nil, session: nil, seeds: :saved, racks: nil)
          @text = text
          @session = session
          unless racks.nil? || Rack::Conflict::CHOICES.include?(racks)
            raise ArgumentError, "racks: must be :session, :saved, or :rename (got #{racks.inspect})"
          end
          @racks_choice = racks
          @rack_aliases = {}
          raise ArgumentError, "seeds: must be :saved or :fresh (got #{seeds.inspect})" unless %i[saved fresh].include?(seeds)
          @fresh_seeds = seeds == :fresh
          # Whether the document marks drawn seeds (format 2 and later; see
          # GraphIO::FORMAT); otherwise :fresh counts every seed as drawn
          @seed_marks = false
          # Whether bare dynamics levels and gains keep their dB meaning
          # (documents before format 3; see GraphIO::FORMAT)
          @old_db = false
          @old_db_warned = false
          # Whether sums end with their first input (documents before
          # format 4; see GraphIO::FORMAT)
          @old_ring = false
          @path = path
          @label = path || '(graph document)'
          @given_inputs = inputs.transform_keys(&:to_sym)
          @overrides = params.transform_keys(&:to_sym)
          @trust = trust
          @limits = GraphIO::LIMITS.merge(limits)
          @base_dir = base_dir || (path && File.dirname(File.expand_path(path)))
          raise ArgumentError, "trust: must be nil or :code (got #{trust.inspect})" unless trust.nil? || trust == :code
        end

        # Parses the document and builds its graph.  Returns the graph (with
        # GraphIO.document_of(graph) giving its Document).
        def load
          tree = parse
          stmts = tree.statements.body
          @document = Document.new(path: @path)
          @document.read_comments(@comments)
          fresh_limits! # (header values may call value methods: `param :x, 1.constant` failed with a NoMethodError)
          index = read_header(stmts)
          body = stmts[index..] || []
          return load_set(body) if set?
          raise error(tree, 'the document has no graph (only a header)') if body.empty?
          return load_rack(body) if @document.rack?

          bind_inputs
          bind_params

          fresh_limits!
          scope = Scope.new
          result = nil
          GraphNode::Mixer.with_ring(@old_ring ? :first : GraphNode::Mixer.ring_mode) {
            body.each { |s| result = eval_node(s, scope) }
          }
          unless GraphNode::Recipe.graph_object?(result) || result.is_a?(MB::Sound::Synth) || graph_array?(result)
            raise error(body.last, "the document's last line must be a graph (got #{describe(result)})")
          end

          @document.knob_nodes = @knob_nodes
          result.instance_variable_set(:@graph_io_document, @document) unless result.frozen?
          @loaded = true
          result
        end

        # Loads a rack document (`graph 4, ..., rack: :arack`; see
        # RackWriter): returns its Rack, whose block walks the body for each
        # application with the ports bound to the values given and the
        # knob lines made as the rack's knobs (RackMethods#rack_knob, so they
        # are named and shared like any rack's).  With the inputs given,
        # returns the Rack applied to them.  The Rack is named after the
        # document (registered in a Session only by `preset` or a graph's
        # definition).
        def load_rack(body)
          types = @document.input_types
          raise LoadError.new("#{@label}: a rack document needs typed inputs (inputs sig: :audio)", path: @path) if types.empty?
          unless @document.params.values.all? { |p| p[:knob] }
            raise LoadError.new("#{@label}: rack documents keep settings in knob lines, not param lines", path: @path)
          end
          constructor = @document.meta[:rack]
          unless constructor.is_a?(Symbol) && Rack::CONSTRUCTORS.include?(constructor)
            raise LoadError.new("#{@label}: rack: must name a rack constructor (#{Rack::CONSTRUCTORS.to_a.join(', ')}), not #{constructor.inspect}", path: @path)
          end

          main_name, main_type = types.first
          ports = types.drop(1).to_h
          defaults = @document.input_defaults
          rack_knobs = @document.params.select { |_, p| p[:knob] }
          out = @document.outputs.first
          listener = %i[lrack amrack listener_rack].include?(constructor)
          out = nil if listener
          out = :audio if %i[irack instrument_rack].include?(constructor)

          @inputs = {}
          @knobs = {}
          @knob_nodes = {}
          loader = self
          last = nil
          pr = proc do |main, **kw|
            loader.fresh_limits! if loader.loaded?
            unknown = kw.keys - ports.keys
            raise ArgumentError, "unknown keyword#{'s' if unknown.length > 1}: #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?
            scope = Scope.new
            b = { main_name => main }
            ports.each_key do |k|
              if kw.key?(k)
                b[k] = kw[k]
              elsif defaults.key?(k)
                b[k] = defaults[k]
              else
                raise ArgumentError, "missing keyword: :#{k}"
              end
            end
            rack_knobs.each do |n, spec|
              opts = spec.slice(*Document::KNOB_KEYS, *Document::RACK_KNOB_KEYS).except(:description)
              b[n] = MB::Sound.knob(n, spec[:param] ? spec[:param].typed(spec[:value]) : spec[:value], description: spec[:description], **opts)
            end
            scope.bindings = b
            last = scope
            loader.walk_statements(body, scope)
          end
          params = [[:opt, main_name]]
          ports.each_key { |k| params << [defaults.key?(k) ? :key : :keyreq, k] }
          pr.define_singleton_method(:arity) { 1 }
          pr.define_singleton_method(:parameters) { |**| params }
          pr.define_singleton_method(:lambda?) { false }
          default_text = defaults.transform_values { |v| v.nil? ? 'nil' : v.inspect }
          pr.define_singleton_method(:graph_io_defaults) { default_text }
          pr.define_singleton_method(:graph_io_locals) { last ? last.vars.dup : {} }

          name = @document.name&.to_sym
          rack = Rack.new(name, in: main_type, out: out, constructor: constructor, block: pr, ports: ports.to_h { |k, t| [k, t] }, listener: listener, quiet: true)
          @document.rack = rack
          GraphIO.remember_rack_document(rack, @document)
          @loaded = true
          return rack if @given_inputs.empty?

          missing = [main_name, *ports.keys.reject { |k| defaults.key?(k) }] - @given_inputs.keys
          unless missing.empty?
            raise LoadError.new("#{@label}: missing input#{'s' if missing.length > 1} #{missing.join(', ')} (give #{missing.map { |m| "#{m}: ..." }.join(', ')}, or none for the Rack)", path: @path)
          end
          extra = @given_inputs.keys - types.keys
          raise LoadError.new("#{@label}: no input#{'s' if extra.length > 1} #{extra.join(', ')} (the rack's inputs: #{types.keys.join(', ')})#{GraphIO.suggest(extra[0], types.keys)}", path: @path) unless extra.empty?
          rack.call(@given_inputs[main_name], **@given_inputs.except(main_name))
        end

        # Walks the top-level statements +body+ in +scope+ (a rack
        # document's application).  Returns the last value.
        def walk_statements(body, scope)
          result = nil
          body.each { |st| result = eval_node(st, scope) }
          result
        end

        # A named rack constructor in the document (a graph's embedded
        # definition, see RubyWriter.rack_definition): defines the rack, or
        # settles a conflict with the session's rack of that name
        # (GraphIO.place_rack); a rack loaded under a new name (:rename)
        # is what this document's rack(:dub) means from then on.
        def define_named_rack(node, receiver, ctor, args, kwargs, block)
          name = args[0]
          saved = receiver.public_send(ctor, *args[1..], **kwargs, &block).renamed(name)
          rack = GraphIO.place_rack(@session || Session.current, saved, racks: @racks_choice, source: @label.to_s) { |msg| error(node, msg) }
          @rack_aliases[name] = rack.name unless rack.name == name
          rack
        end

        # rack(:name) in a document: the Session's rack, else a rack
        # document among the presets of that name (loaded and defined in
        # the Session), else a LoadError.
        def rack_reference(node, scope)
          name = node.arguments.arguments[0].unescaped.to_sym
          name = @rack_aliases.fetch(name, name)
          session = @session || Session.current
          found = session.racks[name]
          return found if found

          path = name.to_s.match?(/\A[\w.-]+\z/) ? GraphIO.find_preset(name) : nil
          doc = path && (GraphIO.parse(path) rescue nil)
          unless doc&.rack?
            names = session.racks.names
            raise error(node, "rack #{name.inspect} isn't defined here, and no rack document of that name is among the presets#{GraphIO.suggest(name, names)}")
          end
          rack = GraphIO.load(path)
          Session.with_context(session: session) { session.racks.define(rack) }
          rack
        end

        # Set commands of `kind: :set` documents (see #load_set), called
        # with their evaluated arguments on the set's Session.
        SET_COMMANDS = %i[bpm meter master_gain quant master bus track sidechain scene mutes section flow].freeze

        # Commands a scene block may hold (they land at the scene's launch
        # point, as in an #at_bar block): meter and tempo, knob turns and
        # snapshots, background players, mutes and solos.
        SCENE_COMMANDS = %i[meter bpm turn recall xfade bg stop swap mute unmute solo unsolo].freeze

        # Loads a set document (kind: :set, see SetWriter) into the
        # Session (the current one unless given): knob lines become the
        # session's knobs, and the body is set commands (SET_COMMANDS) and
        # local variables (clips, graphs).  Returns the Document, whose
        # #form is the flow (not playing; `play_form doc.form`).
        def load_set(body)
          @session ||= Session.current
          unless @given_inputs.empty? && @document.inputs.empty?
            raise LoadError.new("#{@label}: set documents have no inputs", path: @path)
          end
          @inputs = {}
          Session.with_context(session: @session) do
            bind_params
            # The header's clocks (after its knobs, which speeds may name)
            @document.clocks.each { |n, spec| @session.define_clock(n, spec[:base], speed: spec[:speed] || 1) }
            fresh_limits!
            scope = Scope.new
            # Graphs built here (graph tracks, clips' sums) keep the
            # first-input endings of documents before format 4 (patches:
            # see #build_proc)
            run = -> {
              body.each do |s|
                if s.is_a?(Prism::LocalVariableWriteNode)
                  eval_node(s, scope)
                elsif s.is_a?(Prism::CallNode) && s.receiver.nil? && SET_COMMANDS.include?(s.name)
                  set_command(s, scope)
                else
                  raise error(s, "a set document holds set commands (#{SET_COMMANDS.join(', ')}) and assignments")
                end
              end
            }
            @old_ring ? GraphNode::Mixer.with_ring(:first, &run) : run.call
          end
          @document.knob_nodes = @knob_nodes
          @document.session = @session
          @loaded = true
          @document
        end

        # Reads only the header (no graph is built).  Returns a Document.
        def read_document
          tree = parse
          @document = Document.new(path: @path)
          @document.read_comments(@comments)
          fresh_limits! # (header values may call value methods: (0.0..1.0).at(0.5))
          read_header(tree.statements.body)
          @document
        end

        # Parses the text with Prism, checking size, syntax, and depth.
        # Returns the ProgramNode.
        def parse
          if @text.bytesize > @limits[:bytes]
            raise LoadError.new("#{@label}: the document is #{@text.bytesize} bytes (the limit is #{@limits[:bytes]})", path: @path)
          end

          result = Prism.parse(@text, filepath: @path || '(graph document)')
          unless result.errors.empty?
            e = result.errors.first
            raise LoadError.new("#{@label}:#{e.location.start_line}: syntax error: #{e.message}", path: @path, line: e.location.start_line)
          end
          @comments = result.comments.map { |c| [c.location.start_line, c.location.slice] }
          check_shape(result.value)
          result.value
        end

        # True once #load returned (set documents' patches build later).
        def loaded?
          @loaded
        end

        # Starts counting calls and build time anew (see LIMITS).
        def fresh_limits!
          @calls = 0
          @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # Walks a build block's body in +scope+ (called by the procs that
        # #build_proc makes).
        # The value of a build block keyword's default (a rack's optional
        # port, `|sig, depth: 0.5|`), in the block's scope.
        def keyword_default(node, scope)
          eval_node(node, scope)
        end

        def walk_block(body, scope)
          eval_statements(body, scope)
        end

        # Runs a runtime block body (already checked by #runtime_problem;
        # called by the procs that #runtime_proc makes, while sampling).
        def run_runtime(node, scope)
          case node
          when nil then nil
          when Prism::StatementsNode
            r = nil
            node.body.each { |s| r = run_runtime(s, scope) }
            r
          when Prism::ParenthesesNode then run_runtime(node.body, scope)
          when Prism::LocalVariableWriteNode then scope.vars[node.name] = run_runtime(node.value, scope)
          when Prism::LocalVariableReadNode then scope.vars[node.name]
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            Registry::RUNTIME_CONSTANTS.fetch(node.slice) { Registry::VALUE_CONSTANTS.fetch(node.slice) }
          when Prism::ArrayNode then node.elements.map { |e| run_runtime(e, scope) }
          when Prism::RangeNode then Range.new(run_runtime(node.left, scope), run_runtime(node.right, scope), node.exclude_end?)
          when Prism::CallNode
            args = (node.arguments&.arguments || []).map { |a| run_runtime(a, scope) }
            if node.receiver.nil?
              Complex(*args)
            else
              run_runtime(node.receiver, scope).public_send(node.name, *args)
            end
          when Prism::StringNode then node.unescaped
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::NilNode then nil
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          else node.value
          end
        end

        private

        # Checks node count and nesting depth without recursion (so a
        # deeply nested hostile file can't overflow the stack), and rejects
        # forbidden syntax anywhere in the document before anything runs.
        def check_shape(root)
          count = 0
          stack = [[root, 0]]
          until stack.empty?
            node, depth = stack.pop
            count += 1
            raise error(node, "the document has more than #{@limits[:nodes]} syntax nodes") if count > @limits[:nodes]
            raise error(node, "the document nests deeper than #{@limits[:depth]} levels") if depth > @limits[:depth]

            kind = node.class.name.split('::').last
            if (what = FORBIDDEN_NODES[kind])
              raise error(node, "#{what} isn't allowed")
            end
            if node.is_a?(Prism::CallNode)
              check_call_name(node)
            end
            node.compact_child_nodes.each { |c| stack << [c, depth + 1] }
          end
        end

        def check_call_name(node)
          name = node.name
          if Registry::FORBIDDEN.include?(name) || (node.receiver.nil? && Registry::KERNEL.include?(name))
            raise error(node, "`#{name}` is never allowed in graph documents")
          end
          if node.call_operator == '&.'
            raise error(node, 'safe navigation (&.) is flow control and isn\'t allowed')
          end
        end

        ### Header

        # Reads the leading header statements (graph, inputs, param);
        # returns the index of the first body statement.
        def read_header(stmts)
          i = 0
          while i < stmts.length && header_call?(stmts[i])
            node = stmts[i]
            args, kwargs = header_args(node)
            case node.name
            when :graph
              raise error(node, 'graph must come first') unless i == 0
              version = args[0]
              raise error(node, "graph needs a format version (graph #{GraphIO::FORMAT})") unless version.is_a?(Integer)
              if version > GraphIO::FORMAT
                raise error(node, "the document is format #{version}, newer than this mb-sound reads (#{GraphIO::FORMAT}); update mb-sound")
              end
              @document.format = version
              @seed_marks = version >= 2
              @old_db = version < 3
              @old_ring = version < 4
              @document.meta = kwargs
            when :inputs
              bad = args.reject { |a| a.is_a?(Symbol) }
              raise error(node, "inputs takes Symbols (inputs :midi), not #{bad.map(&:inspect).join(', ')}") unless bad.empty?
              # Untyped names (before format 4): midi is notes, others audio
              args.each { |a| @document.input_types[a] = a == :midi ? :notes : :audio }
              kwargs.each do |k, t|
                type, default = t.is_a?(Array) ? t : [t]
                unless Rack::DEFAULT_KINDS.key?(type) && (!t.is_a?(Array) || t.length == 2)
                  raise error(node, "input #{k}: needs a port type (:notes, :audio, :control; [:control, 0.5] for an optional port), not #{t.inspect}")
                end
                @document.input_types[k] = type
                @document.input_defaults[k] = default if t.is_a?(Array)
              end
              @document.inputs.concat(args + kwargs.keys)
            when :outputs
              bad = args.reject { |a| Rack::DEFAULT_KINDS.key?(a) }
              raise error(node, "outputs takes port types (:notes, :audio, :control), not #{bad.map(&:inspect).join(', ')}") unless bad.empty? && kwargs.empty? && !args.empty?
              @document.outputs.concat(args)
            when :param
              name, value = args
              raise error(node, 'param needs a name and a value (param :drive, 1.0)') unless name.is_a?(Symbol) && args.length == 2
              value, kwargs = unpack_ranged(node, name, value, kwargs)
              raise error(node, "param #{name} needs a number or a unit value like 2400.hz (got #{value.inspect})") unless header_number?(value)
              unknown = kwargs.keys - Document::PARAM_KEYS
              raise error(node, "unknown param option#{'s' if unknown.length > 1} #{unknown.join(', ')} (#{Document::PARAM_KEYS.join(', ')})") unless unknown.empty?
              raise error(node, "#{name} is declared twice") if @document.params.key?(name)
              decl = declaration(node, name, value, kwargs)
              # (the value as a number in its base unit: params bind as
              # Constants; the Param keeps the typed declaration)
              @document.params[name] = kwargs.merge(value: base_number(decl.default), param: decl)
            when :knob
              name, value = args
              raise error(node, 'knob needs a name and a value (knob :cut, (100.hz..8000.hz).at(800.hz))') unless name.is_a?(Symbol) && args.length == 2
              value, kwargs = unpack_ranged(node, name, value, kwargs)
              raise error(node, "knob #{name} needs a number or a unit value like 2400.hz (got #{value.inspect})") unless header_number?(value)
              keys = Document::KNOB_KEYS + (@document.rack? ? Document::RACK_KNOB_KEYS : [])
              unknown = kwargs.keys - keys
              raise error(node, "unknown knob option#{'s' if unknown.length > 1} #{unknown.join(', ')} (#{keys.join(', ')}#{'; share: and follow: are for rack documents\' knobs' if (unknown & Document::RACK_KNOB_KEYS).any?})") unless unknown.empty?
              raise error(node, "#{name} is declared twice") if @document.params.key?(name)
              spec = begin
                GraphNode::Knob::Spec.new(name: name, default: value, **kwargs.except(*Document::RACK_KNOB_KEYS))
              rescue ArgumentError => e
                raise error(node, "knob #{name}: #{e.message}")
              end
              @document.params[name] = kwargs.merge(value: base_number(spec.param.default.nil? ? spec.default : spec.param.default), knob: true, param: spec.param)
            when :clock
              name, base = args
              raise error(node, 'clock needs a name and a tempo, ratio, or period (clock :tide, 31.1.seconds)') unless name.is_a?(Symbol) && args.length == 2
              unknown = kwargs.keys - [:speed]
              raise error(node, "unknown clock option#{'s' if unknown.length > 1} #{unknown.join(', ')} (speed)") unless unknown.empty?
              raise error(node, "clock #{name} is declared twice") if @document.clocks.key?(name)
              speed = kwargs[:speed]
              unless speed.nil? || speed.is_a?(Symbol) || (speed.is_a?(Numeric) && speed.real? && speed >= 0)
                raise error(node, "clock #{name}: speed: is a number or a knob's name (got #{speed.inspect})")
              end
              begin
                MB::Sound::Clock.new(base)
              rescue ArgumentError => e
                raise error(node, "clock #{name}: #{e.message}")
              end
              @document.clocks[name] = { base: base, speed: speed }
            when :asset
              name = args[0]
              unless args.length == 1 && name.is_a?(String) && kwargs.keys.all? { |k| k == :sha256 }
                raise error(node, 'asset takes a file name and its sum (asset "assets/pad.flac", sha256: "...")')
              end
              sum = kwargs[:sha256]
              raise error(node, "asset #{name.inspect}: sha256: must be 64 hex digits") unless sum.nil? || (sum.is_a?(String) && sum.match?(/\A[0-9a-f]{64}\z/))
              raise error(node, "asset #{name.inspect} is listed twice") if @document.assets.key?(name)
              @document.assets[name] = sum
            end
            i += 1
          end
          stmts[i..].each do |s|
            raise error(s, "#{s.name} belongs in the header, before the graph") if header_call?(s)
          end
          i
        end

        def header_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && Document::HEADER.include?(node.name) && node.block.nil? &&
            !(node.name == :inputs && node.arguments.nil?)
        end

        # Header arguments: values only (no DSL calls).
        def header_args(node)
          @header = true
          args = []
          kwargs = {}
          (node.arguments&.arguments || []).each do |a|
            if a.is_a?(Prism::KeywordHashNode)
              a.elements.each { |el| kwargs[value_key(el.key)] = eval_node(el.value, Scope.new) }
            else
              args << eval_node(a, Scope.new)
            end
          end
          [args, kwargs]
        ensure
          @header = false
        end

        ### Inputs and params

        def bind_inputs
          declared = @document.inputs
          if declared.empty? && @document.comment_inputs
            declared.concat(@document.comment_inputs)
          end
          missing = declared - @given_inputs.keys
          unless missing.empty?
            notes = missing.select { |m| @document.input_types[m] == :notes || (m == :midi && !@document.input_types.key?(m)) }
            hint = notes.empty? ? '' : "; an instrument plays notes: `#{@document.name || 'x'}` on a track gets the track's clip (track :x, :#{@document.name || 'x'})"
            raise LoadError.new("#{@label}: missing input#{'s' if missing.length > 1} #{missing.join(', ')} (give #{missing.map { |m| "#{m}: ..." }.join(', ')}#{hint})", path: @path)
          end

          extra = @given_inputs.keys - declared
          # Overrides of params can arrive mixed with inputs (preset :x, input: a, drive: 2)
          extra -= @document.params.keys
          unless extra.empty?
            params = @document.params.keys
            known = "the document's inputs: #{declared.empty? ? 'none' : declared.join(', ')}"
            known += "; params and knobs: #{params.join(', ')}" unless params.empty?
            hint = extra.flat_map { |e| DidYouMean::SpellChecker.new(dictionary: (declared + params).map(&:to_s)).correct(e.to_s) }.uniq
            hint = hint.empty? ? '' : " (did you mean #{hint.map { |h| "#{h}:" }.join(', ')}?)"
            warn "#{@label}: ignoring #{extra.map { |e| "#{e}:" }.join(', ')} (#{known})#{hint}"
          end
          @inputs = @given_inputs.slice(*declared)
        end

        # Knobs: each use of a param's name is a new Constant named after
        # it, as scripts make them, so loaded documents render like their
        # scripts (a Constant shared with an oversample region is read
        # through a resampling Tee branch since omnibus4, correct but not
        # the same graph).  Document#set changes them all.
        def bind_params
          baked = (@document.meta[:options] || {})
          @overrides.each_key do |k|
            next if @document.params.key?(k)
            if baked.respond_to?(:key?) && baked.key?(k)
              raise LoadError.new("#{@label}: #{k} was baked into this patch when it was saved (a script option, not a knob); change it in the script and save again", path: @path)
            end
            hint = GraphIO.suggest(k, @document.params.keys)
            raise LoadError.new("#{@label}: no param #{k}#{hint} (params: #{@document.params.keys.join(', ').then { |s| s.empty? ? 'none' : s }})", path: @path)
          end

          @knobs = {}
          @knob_nodes = {}
          @bound = {}
          @document.params.each do |name, spec|
            value = @overrides.fetch(name, spec[:value])
            decl = spec[:param]
            if decl && @overrides.key?(name) && header_number?(value) && !value.is_a?(Numeric) && MB::Sound::Param.type_of(value) == decl.type
              value = MB::Sound::Param.magnitude(value) # (a typed override: 3000.hz for a frequency param)
            end
            if (node = bound_param(name, value))
              # Bound to a node or a Session knob by the caller: every use
              # reads it (consumers branch it with get_sampler), and the
              # document's own default stays the param's value
              @bound[name] = node
              spec[:bound] = value.is_a?(Symbol) ? value : node
              @knobs[name] = spec[:value]
              next
            end
            raise LoadError.new("#{@label}: param #{name} needs a number, a graph node, or a knob name (got #{value.inspect})", path: @path) unless value.is_a?(Numeric) && value.real?
            if @overrides.key?(name) && decl
              # (a Param check: raises in scripts and specs; live, warns
              # and limits the value to the range)
              value = base_number(decl.check(value, what: "#{@label}: param #{name}"))
            end
            spec[:value] = value
            @knobs[name] = value
            if spec[:knob]
              # One GraphNode::Knob per knob line, read by every use (each
              # consumer gets its own Knob::Reader)
              opts = spec.slice(*Document::KNOB_KEYS)
              typed = decl ? decl.typed(value) : value
              @knob_nodes[name] = [set? ? session_knob(name, typed, opts) : GraphNode::Knob.new(name, typed, **opts)]
            end
          end
        end

        # True for a header line's value: a real number or a unit value
        # (format 5 documents write typed values: 2400.hz, -12.db).
        def header_number?(v)
          (v.is_a?(Numeric) && v.real?) || MB::Sound::Param::UNIT_TYPES.include?(MB::Sound::Param.type_of(v))
        end

        # +v+ as a number in its base unit (plain numbers as written).
        def base_number(v)
          v.is_a?(Numeric) && !v.is_a?(MB::Sound::Decibels) ? v : MB::Sound::Param.magnitude(v)
        end

        # A header line's value and keywords with a ranged default
        # (`param :drive, (0.0..24.0).at(11.0)`, the canonical spelling,
        # which documents accept but don't write yet) unpacked into
        # value and range:.
        def unpack_ranged(node, name, value, kwargs)
          return [value, kwargs] unless value.is_a?(MB::Sound::Param::Ranged)
          raise error(node, "#{name}: give the range once, in (lo..hi).at(value) or in range:") if kwargs.key?(:range)
          [value.default, kwargs.merge(range: value.range)]
        end

        # The MB::Sound::Param of a `param` line (a LoadError at the line
        # for a mistake: a value outside its range, mixed range ends, an
        # unknown curve).  A range written high to low (an inverted
        # controller's, saved by older scripts) declares the span low to
        # high; the line keeps it as written.
        def declaration(node, name, value, kwargs)
          Document.declaration(name, value, kwargs)
        rescue ArgumentError => e
          raise error(node, "param #{name}: #{e.message.delete_prefix("#{name}: ")}")
        end

        # The node param +name+ is bound to when the caller's +value+ (never
        # document text: params in the document are numbers) is a graph node
        # or a Symbol naming a knob of the Session (the loader's, else the
        # current context's or default one, never created here), else nil.
        def bound_param(name, value)
          case value
          when Symbol
            session = @session || Session.existing
            knob = session&.knobs&.[](value)
            unless knob
              names = session ? session.knobs.keys : []
              raise LoadError.new("#{@label}: param #{name} names knob #{value.inspect}, but #{session ? 'the session has no such knob' : 'there is no session'}#{GraphIO.suggest(value, names)} (knobs: #{names.empty? ? 'none' : names.join(', ')})", path: @path)
            end
            knob
          when GraphNode, GraphNode::Channels
            value
          end
        end

        # True for a set document (kind: :set).
        def set?
          @document.kind == :set
        end

        # The Session's knob for a set document's `knob` line: made, or
        # given the document's options and value if the session has it.
        def session_knob(name, value, opts)
          existing = @session.knobs[name]
          k = @session.knob(name, value, **opts)
          raise LoadError.new("#{@label}: knob #{name} can't be made (its name is taken in the session)", path: @path) unless k
          k.set(value, frame: k.next_frame) if existing && k.target != value
          k
        end

        # Runs set command +node+ (see SET_COMMANDS) on the set's Session.
        def set_command(node, scope)
          name = node.name
          args, kwargs = call_args(node, scope)
          check_limits(node, MB::Sound, name, args, kwargs)
          b = node.block
          if b && !b.is_a?(Prism::BlockNode)
            raise error(b, "#{name} takes a literal block here")
          end
          if b && !%i[master bus track sidechain flow scene].include?(name)
            raise error(b, "#{name} takes no block in set documents")
          end

          begin
            case name
            when :meter
              beats, unit = args
              unit ||= 4
              unless beats.is_a?(Integer) && unit.is_a?(Integer) && beats > 0 && unit > 0 && kwargs.empty?
                raise error(node, 'meter takes beats and a note unit (meter 7, 8)')
              end
              @session.transport.bar_length = Rational(beats, unit)
            when :master
              preset = args.length == 1 && Mastering.preset?(args[0])
              unless (b && args.empty? && kwargs.empty?) || preset
                raise error(node, "master takes a block (master { |mix| ... }) or a mastering preset (master :club, lufs: -8; #{Mastering.names.map(&:inspect).join(', ')})")
              end
              MB::Sound.master(*args, **kwargs, &(b && build_proc(b, scope)))
            when :track
              MB::Sound.track(*args, **kwargs, &(b && build_proc(b, scope)))
            when :sidechain
              unless args.length == 1 && args[0].is_a?(Symbol) && (kwargs.keys - %i[q fade nudge]).empty? && b
                raise error(node, 'sidechain takes a name, q:, fade:, nudge:, and a block in set documents (sidechain(:pump) { |clip| clip.trigger })')
              end
              MB::Sound.sidechain(*args, **kwargs, &build_proc(b, scope))
            when :bus
              unless args.length == 1 && args[0].is_a?(Symbol) && (kwargs.keys - %i[to]).empty? && (b || kwargs.key?(:to))
                raise error(node, 'bus takes a name, to:, and a block (bus(:hall, to: :verb) { |sig| ... }, or bus :drums, to: :master)')
              end
              MB::Sound.bus(*args, **kwargs, &(b && build_proc(b, scope)))
            when :scene
              MB::Sound.scene(*args, **kwargs, &(b && scene_proc(b, scope)))
            when :flow
              raise error(node, 'flow takes a block (flow do ... end)') unless b && args.empty? && kwargs.empty?
              raise error(b, 'flow blocks take no parameters') if b.parameters
              loader = self
              body = b.body
              @document.form = @session.arrangement.build_form { loader.walk_flow(body, self, scope) }
            else
              MB::Sound.public_send(name, *args, **kwargs)
            end
          rescue GraphIO::LoadError
            raise
          rescue StandardError => e
            raise error(node, "#{name} raised #{e.class}: #{e.message}")
          end
        end

        public

        # True for documents before format 4, whose sums end with their
        # first input (see GraphIO::FORMAT).
        def old_ring?
          @old_ring
        end

        # A scene block: a proc that runs the block's statements when the
        # scene launches (assignments, and SCENE_COMMANDS with values and
        # graphs as arguments; no blocks), keeping its text for saving.
        def scene_proc(b, outer)
          names, rest = block_params(b)
          (b.body&.body || []).each do |st|
            next if st.is_a?(Prism::LocalVariableWriteNode)
            unless st.is_a?(Prism::CallNode) && st.receiver.nil? && SCENE_COMMANDS.include?(st.name) && st.block.nil?
              raise error(st, "a scene block holds assignments and the commands #{SCENE_COMMANDS.join(', ')} (without blocks)")
            end
          end

          loader = self
          count = names.length
          body = b.body
          source = b.slice
          pr = proc do |*args|
            loader.fresh_limits!
            scope = Scope.new(outer)
            names.each_with_index { |n, i| scope.vars[n] = args[i] }
            scope.vars[rest] = args[count..] || [] if rest
            loader.run_scene(body, scope)
          end
          arity = rest ? -(count + 1) : count
          params = names.map { |n| [:opt, n] }
          params << [:rest, rest] if rest
          pr.define_singleton_method(:arity) { arity }
          pr.define_singleton_method(:parameters) { |**| params }
          pr.define_singleton_method(:graph_io_source) { source }
          pr
        end

        public

        # Runs a scene block's statements (see #scene_proc).
        def run_scene(body, scope)
          (body&.body || []).each do |st|
            if st.is_a?(Prism::LocalVariableWriteNode)
              eval_node(st, scope)
              next
            end
            args, kwargs = call_args(st, scope)
            check_limits(st, MB::Sound, st.name, args, kwargs)
            begin
              MB::Sound.public_send(st.name, *args, **kwargs)
            rescue GraphIO::LoadError
              raise
            rescue StandardError => e
              raise error(st, "#{st.name} raised #{e.class}: #{e.message}")
            end
          end
          nil
        end

        # Why +source+ (a scene block's text, `{ |t| ... }` or `do ... end`)
        # can't be a scene block of a set document, or nil (see SetWriter).
        def self.scene_block_problem(source)
          new("graph 1, kind: :set\nscene(:x) #{source}\n").scene_block_check
          nil
        rescue LoadError => e
          e.message.sub(/\A\(graph document\):\d+: /, '')
        end

        # Parses a one-scene document made by .scene_block_problem and
        # checks its block (raises LoadError).
        def scene_block_check
          node = parse.statements.body[1]
          raise LoadError, 'not a scene block' unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)
          scene_proc(node.block, Scope.new)
        end

        # Builds a flow's steps from +body+ (the statements of a `flow do`,
        # `repeat n do`, or pick option block) on Form::Builder +builder+:
        # sections and the steps repeat, fill, label, goto, and pick, with
        # values only (goto Procs are code).
        def walk_flow(body, builder, scope)
          (body&.body || []).each do |s|
            unless s.is_a?(Prism::CallNode) && s.receiver.nil?
              raise error(s, 'a flow holds sections and steps (verse 8, repeat 2 do ... end, label, goto, pick, fill)')
            end
            name = s.name
            args, kwargs = call_args(s, scope)
            @calls += 1
            if (args + kwargs.values).any? { |a| a.is_a?(Proc) }
              raise error(s, "#{name} takes values in a set document (goto Procs are code)")
            end
            b = s.block
            raise error(b, 'flow blocks are literal blocks') if b && !b.is_a?(Prism::BlockNode)
            if name.to_s.start_with?('__') || (BasicObject.public_instance_methods.include?(name) && name != :!)
              raise error(s, "#{name} can't be a section name")
            end

            begin
              case name
              when :repeat
                raise error(s, 'repeat takes a block of sections') unless b && b.parameters.nil?
                builder.repeat(*args, **kwargs) { walk_flow(b.body, builder, scope) }
              when :pick
                if b
                  params, = block_params(b)
                  raise error(b, 'a pick block takes one parameter (pick do |p| p.option(2) { ... } end)') unless params.length == 1
                  builder.pick(*args, **kwargs) { |opts| walk_options(b.body, params[0], opts, builder, scope) }
                else
                  builder.pick(*args, **kwargs)
                end
              else
                raise error(b, "#{name} takes no block") if b
                FLOW_CALL.bind_call(builder, name, *args, **kwargs)
              end
            rescue GraphIO::LoadError
              raise
            rescue StandardError, NoMethodError => e
              raise error(s, "#{name}: #{e.message}")
            end
          end
          nil
        end

        # A pick block's `p.option(weight) { sections }` lines.
        def walk_options(body, param, opts, builder, scope)
          (body&.body || []).each do |s|
            ok = s.is_a?(Prism::CallNode) && s.name == :option && s.receiver.is_a?(Prism::LocalVariableReadNode) && s.receiver.name == param
            raise error(s, "a pick block holds #{param}.option(weight) { sections } lines") unless ok
            args, kwargs = call_args(s, scope)
            b = s.block
            raise error(s, 'option takes a literal block') if b && !(b.is_a?(Prism::BlockNode) && b.parameters.nil?)
            if b
              opts.option(*args, **kwargs) { walk_flow(b.body, builder, scope) }
            else
              opts.option(*args, **kwargs)
            end
          end
        end

        # Calls a flow step or section by name on a Form::Builder (a
        # BasicObject, which has no public_send of its own).
        FLOW_CALL = Kernel.instance_method(:public_send)

        private

        # The node for a use of param +name+: a new Constant named after it
        # (see #bind_params), or the knob of a `knob` line.
        def knob(name)
          return @bound[name] if @bound&.key?(name)
          return @knob_nodes[name][0] if @document.params[name][:knob]

          c = @knobs[name].constant.named(name.to_s)
          (@knob_nodes[name] ||= []) << c
          c
        end

        ### Evaluation

        def eval_node(node, scope)
          case node
          when Prism::IntegerNode
            check_integer(node, node.value)
          when Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode
            node.value
          when Prism::StringNode
            # Registered, so library file readers keep it inside the
            # document's directory (FileGuard)
            FileGuard.register(node.unescaped.dup, file_context)
          when Prism::SymbolNode
            node.unescaped.to_sym
          when Prism::NilNode then nil
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::ArrayNode
            node.elements.map { |e| eval_node(e, scope) }
          when Prism::HashNode, Prism::KeywordHashNode
            node.elements.to_h { |el| [eval_node(el.key, scope), eval_node(el.value, scope)] }
          when Prism::RangeNode
            b = node.left && eval_node(node.left, scope)
            e = node.right && eval_node(node.right, scope)
            Range.new(b, e, node.exclude_end?)
          when Prism::ParenthesesNode
            eval_statements(node.body, scope)
          when Prism::StatementsNode
            eval_statements(node, scope)
          when Prism::LocalVariableWriteNode
            raise error(node, "#{node.name} is an input or param and can't be assigned") if bound?(node.name)
            scope.up(node.depth).vars[node.name] = eval_node(node.value, scope)
          when Prism::LocalVariableReadNode
            s = scope.up(node.depth)
            raise error(node, "#{node.name} is used before it is assigned") unless s.vars.key?(node.name)
            s.vars[node.name]
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            constant(node)
          when Prism::CallNode
            eval_call(node, scope)
          when Prism::LambdaNode
            runtime_proc(node, scope, lambda: true)
          else
            raise error(node, "#{node.class.name.split('::').last.delete_suffix('Node')} isn't allowed in graph documents")
          end
        end

        def eval_statements(node, scope)
          return nil if node.nil?
          result = nil
          node.body.each { |s| result = eval_node(s, scope) }
          result
        end

        def check_integer(node, v)
          if v.bit_length > 64
            raise error(node, "the number #{v.to_s[0, 20]}... is too large (#{v.bit_length} bits; the limit is 64)")
          end
          v
        end

        def constant(node)
          text = node.slice
          v = @header ? Registry::VALUE_CONSTANTS[text] : Registry.constant(text)
          return v unless v.nil?
          hint = GraphIO.suggest(text, Registry.constants.keys)
          raise error(node, "unknown constant #{text}#{hint} (documents may name the library's node, filter, and value classes, notes like A3, and Float::INFINITY)")
        end

        def bound?(name)
          @inputs&.key?(name) || @knobs&.key?(name)
        end

        # A call: a value method, a DSL call through the registry, or a
        # name bound to an input or param.
        def eval_call(node, scope)
          name = node.name

          if node.receiver.nil?
            if node.variable_call?
              if (bs = scope.binding_scope(name))
                return bs.bindings[name]
              end
              return @inputs[name] if @inputs&.key?(name)
              return knob(name) if @knobs&.key?(name)
            end
            return complex(node, scope) if name == :Complex
            return rack_reference(node, scope) if name == :rack && node.block.nil? && node.arguments&.arguments&.length == 1 && node.arguments.arguments[0].is_a?(Prism::SymbolNode)
            return named_proc(node, scope) if name == :named_proc
            return bus_reader(node, scope) if name == :bus
            return drawn_seed(node, scope) if name == :drawn_seed
            # knob(:"bass/reso") reads a knob the header defined whose name
            # isn't a Ruby identifier (as a bare name reads the others)
            if name == :knob && !@header && !MB::Sound::Rack.application && node.block.nil? && (a = node.arguments&.arguments)&.length == 1 && a[0].is_a?(Prism::SymbolNode) && @knobs&.key?(a[0].unescaped.to_sym)
              return knob(a[0].unescaped.to_sym)
            end
            # (knob inside a rack's block is the rack's own knob: RackMethods#rack_knob)
            if Document::HEADER.include?(name) && !(name == :knob && MB::Sound::Rack.application)
              raise error(node, "#{name} belongs in the header, before the graph")
            end
            if @header
              raise error(node, "the header holds values only (#{name} isn't one)")
            end
            implicit = scope.implicit_self
            if implicit && Registry.allowed?(implicit, name)
              receiver = implicit
            elsif !(Registry.top_level.include?(name) && MB::Sound.respond_to?(name))
              if node.variable_call?
                known = scope.names + (@inputs&.keys || []) + (@knobs&.keys || [])
                hint = GraphIO.suggest(name, known + Registry.top_level.to_a)
                raise error(node, "undefined name #{name}#{hint}#{" (the document's inputs: #{@document.inputs.join(', ')})" unless @document.inputs.empty?}")
              end
              hint = GraphIO.suggest(name, Registry.top_level.to_a + (implicit ? Registry.names_for(implicit).to_a : []))
              raise error(node, "#{name} isn't a graph method#{hint}")
            else
              receiver = MB::Sound
            end
          else
            receiver = eval_node(node.receiver, scope)
            if @header && !receiver.is_a?(Numeric) && !(receiver.is_a?(Range) && name == :at)
              raise error(node, "the header holds values only (#{name} isn't one)")
            end
            unless Registry.allowed?(receiver, name)
              names = Registry.names_for(receiver)
              hint = GraphIO.suggest(name, names.to_a)
              raise error(node, "#{name} isn't a graph method of #{describe(receiver)}#{hint}")
            end
          end

          args, kwargs = call_args(node, scope)
          block = call_block(node, scope)
          if receiver.equal?(MB::Sound) && Rack::CONSTRUCTORS.include?(name) && args[0].is_a?(Symbol) && block
            return define_named_rack(node, receiver, name, args, kwargs, block)
          end
          check_limits(node, receiver, name, args, kwargs)
          check_file(node, name, args) if Registry::FILE_METHODS.include?(name)
          drawn = kwargs[:seed].is_a?(DrawnSeed) ? kwargs.delete(:seed) : nil
          if (args + kwargs.values).any?(DrawnSeed)
            raise error(node, 'drawn_seed(n) goes only in seed:')
          end
          if @fresh_seeds && (drawn || !@seed_marks)
            # seeds: :fresh draws new random seeds instead of the ones the
            # save drew (all seeds in documents that don't mark them)
            kwargs.delete(:seed)
            drawn = nil
          elsif drawn
            kwargs[:seed] = drawn.seed
          end

          args, kwargs = old_db_arguments(receiver, name, args, kwargs) if @old_db

          begin
            # Documents load without the dynamics "above full scale"
            # warnings, and keep delay(seconds:) loading, so loading them
            # doesn't warn
            result = Decibels.quietly do
              GraphNode::DelayMethods.quiet_seconds do
                if drawn
                  # Recorded as drawn, so saving the graph again marks it again
                  GraphNode::Recipe.given_drawn_seed(drawn.seed) { receiver.public_send(name, *args, **kwargs, &block) }
                else
                  receiver.public_send(name, *args, **kwargs, &block)
                end
              end
            end
          rescue GraphIO::FileError => e
            raise error(node, e.message)
          rescue GraphIO::LoadError
            raise
          rescue StandardError => e
            raise error(node, "#{name} raised #{e.class}: #{e.message}")
          end
          check_result(node, result) if receiver.is_a?(Numeric) || result.is_a?(Integer)
          result
        end

        # Arguments for a call in a document older than format 3, whose
        # bare dB values become the Decibels they meant (OldDecibels), with
        # one warning per document.
        def old_db_arguments(receiver, name, args, kwargs)
          args, kwargs, changed = OldDecibels.convert(receiver, name, args, kwargs)
          if changed && !@old_db_warned
            @old_db_warned = true
            warn "#{@label}: warning: format #{@document.format} document: bare dB values (like makeup: 9 or accent: 6) are read as dB, as when it was saved; " \
              "save it again to write them as 9.db (bare numbers are linear gains since format #{GraphIO::FORMAT})"
          end
          [args, kwargs]
        end

        def call_args(node, scope)
          args = []
          kwargs = {}
          (node.arguments&.arguments || []).each do |a|
            if a.is_a?(Prism::KeywordHashNode)
              a.elements.each { |el| kwargs[eval_node(el.key, scope)] = eval_node(el.value, scope) }
            elsif a.is_a?(Prism::BlockArgumentNode)
              raise error(a, 'block arguments go last') # Prism keeps &blk in #block
            else
              args << eval_node(a, scope)
            end
          end
          [args, kwargs]
        end

        # The block for a call: a build block (walked per call), a runtime
        # block (safe subset, or trusted code), or &named_proc(:name).
        def call_block(node, scope)
          b = node.block
          return nil if b.nil?

          if b.is_a?(Prism::BlockArgumentNode)
            raise error(b, 'a block argument needs a value (&named_proc(:name))') unless b.expression
            pr = eval_node(b.expression, scope)
            # A rack applied with then(&rack) (MB::Sound::Rack#to_proc)
            pr = pr.to_proc if pr.is_a?(MB::Sound::Rack)
            raise error(b, "a block argument must be a proc or a rack (got #{describe(pr)})") unless pr.is_a?(Proc)
            return pr
          end

          if Registry::BUILD_BLOCKS.include?(node.name)
            build_proc(b, scope)
          else
            runtime_proc(b, scope, lambda: false, call_name: node.name)
          end
        end

        # Block parameter names (required, optional without defaults
        # aren't allowed, a rest parameter is).
        def block_params(b, keywords: false)
          params = b.parameters
          return [[], nil, []] if params.nil?
          if params.is_a?(Prism::NumberedParametersNode) || params.is_a?(Prism::ItParametersNode)
            raise error(b, 'implicit block parameters (_1, it) aren\'t allowed; name them')
          end
          list = params.is_a?(Prism::BlockParametersNode) ? params.parameters : params
          return [[], nil, []] if list.nil?
          unless list.optionals.empty? && list.posts.empty? && (keywords || list.keywords.empty?) && list.keyword_rest.nil? && list.block.nil?
            raise error(b, "block parameters may only be plain names (|v, i|)#{', keywords (|sig, side:|),' if keywords} and a *rest")
          end
          names = list.requireds.map { |r|
            raise error(r, 'destructuring block parameters aren\'t allowed') unless r.is_a?(Prism::RequiredParameterNode)
            r.name
          }
          rest = list.rest&.name
          # Keywords of build blocks (a rack's ports): [name, default node or nil]
          kws = list.keywords.map { |k| [k.name, k.respond_to?(:value) ? k.value : nil] }
          [names, rest, kws]
        end

        # A build block: a proc that walks the block's body for each call,
        # with its parameters bound in a new scope.  It answers arity,
        # parameters, and lambda? like the literal block, and gives the
        # recorder its locals (GraphNode::Recipe.trace_locals).
        def build_proc(b, outer)
          names, rest, kws = block_params(b, keywords: true)
          loader = self
          count = names.length
          last = nil
          pr = proc do |*args, **kw|
            args = args[0] if count > 1 && args.length == 1 && args[0].is_a?(Array)
            # A set's patches build again long after the load: each build
            # gets the limits afresh
            loader.fresh_limits! if loader.loaded?
            scope = Scope.new(outer)
            # Run with instance_exec (a drum kit's parameterless blocks):
            # receiverless calls go to that object first
            scope.implicit_self = self unless self.equal?(loader)
            names.each_with_index { |n, i| scope.vars[n] = args[i] }
            scope.vars[rest] = args[count..] || [] if rest
            kws.each do |k, default|
              if kw.key?(k)
                scope.vars[k] = kw[k]
              elsif default
                scope.vars[k] = loader.keyword_default(default, scope)
              else
                raise ArgumentError, "missing keyword: :#{k}"
              end
            end
            unknown = kw.keys - kws.map(&:first)
            raise ArgumentError, "unknown keyword#{'s' if unknown.length > 1}: #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?
            last = scope
            # Blocks of documents before format 4 (set patches built when a
            # track launches, synth lanes built later) keep their sums'
            # first-input endings like the document's graph (see #load)
            if loader.old_ring?
              GraphNode::Mixer.with_ring(:first) { loader.walk_block(b.body, scope) }
            else
              loader.walk_block(b.body, scope)
            end
          end
          params = names.map { |n| [:opt, n] }
          params << [:rest, rest] if rest
          kws.each { |k, default| params << [default ? :key : :keyreq, k] }
          arity = rest ? -(count + 1) : count
          pr.define_singleton_method(:arity) { arity }
          pr.define_singleton_method(:parameters) { |**| params }
          pr.define_singleton_method(:lambda?) { false }
          source = b.slice
          pr.define_singleton_method(:graph_io_source) { source }
          pr.define_singleton_method(:graph_io_locals) { last ? last.vars.reject { |k, _| names.include?(k) || k == rest || kws.any? { |kk, _| kk == k } } : {} }
          pr
        end

        # A runtime block (or lambda value): checked against the safe
        # subset now, then interpreted each time it's called (while
        # sampling).  Outside the subset it needs trust: :code.
        def runtime_proc(b, outer, lambda:, call_name: nil)
          names, rest = block_params(b)
          source = lambda ? b.slice : b.slice
          problem = runtime_problem(b.body, Set.new(names + [rest].compact))
          if problem
            if @trust == :code
              return TrustedCode.block(source, lambda: lambda, path: @label, line: b.location.start_line)
            end
            raise error(problem[0], "the #{lambda ? 'lambda' : "#{call_name} block"} #{problem[1]}, outside the safe subset for runtime blocks " \
              '(arithmetic and math on its own parameters); register it with MB::Sound.named_proc(:name) { ... } and write ' \
              "&named_proc(:name), or load with trust: :code")
          end

          loader = self
          count = names.length
          body = b.body
          run = ->(args) {
            args = args[0] if !lambda && count > 1 && args.length == 1 && args[0].is_a?(Array)
            scope = Scope.new
            names.each_with_index { |n, i| scope.vars[n] = args[i] }
            scope.vars[rest] = args[count..] || [] if rest
            loader.run_runtime(body, scope)
          }
          pr = lambda ? ->(*args) { run.(args) } : proc { |*args| run.(args) }
          params = names.map { |n| [lambda ? :req : :opt, n] }
          params << [:rest, rest] if rest
          arity = rest ? -(count + 1) : count
          pr.define_singleton_method(:arity) { arity }
          pr.define_singleton_method(:parameters) { |**| params }
          pr.define_singleton_method(:lambda?) { lambda }
          pr.define_singleton_method(:graph_io_source) { source }
          pr
        end

        # Why +body+ is outside the runtime safe subset ([node, reason]),
        # or nil.  +locals+ are the block's parameters.
        def runtime_problem(body, locals)
          locals = locals.dup
          stack = [body].compact
          until stack.empty?
            n = stack.pop
            case n
            when Prism::StatementsNode, Prism::ParenthesesNode, Prism::ArgumentsNode, Prism::IntegerNode, Prism::FloatNode,
                 Prism::RationalNode, Prism::ImaginaryNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
                 Prism::SymbolNode, Prism::ArrayNode, Prism::RangeNode
            when Prism::LocalVariableWriteNode
              return [n, "assigns #{n.name} outside the block"] if n.depth > 0
              locals << n.name
            when Prism::LocalVariableReadNode
              return [n, "reads #{n.name} from the code around it"] if n.depth > 0
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              return [n, "names #{n.slice}"] unless Registry::RUNTIME_CONSTANTS.key?(n.slice) || Registry::VALUE_CONSTANTS.key?(n.slice)
              next
            when Prism::CallNode
              if n.receiver.nil?
                return [n, "calls #{n.name}"] unless n.name == :Complex
              elsif !Registry::RUNTIME.include?(n.name)
                return [n, "calls #{n.name}"]
              end
              return [n, "passes a block to #{n.name}"] if n.block
            else
              return [n, "uses #{n.class.name.split('::').last.delete_suffix('Node')}"]
            end
            stack.concat(n.compact_child_nodes)
          end
          nil
        end

        def complex(node, scope)
          args, kwargs = call_args(node, scope)
          raise error(node, 'Complex takes two numbers') unless kwargs.empty? && args.length.between?(1, 2) && args.all? { |a| a.is_a?(Numeric) && a.real? }
          Complex(*args)
        end

        # A seed drawn when the graph was saved (see GraphIO::FORMAT), for
        # seed: only.
        DrawnSeed = Struct.new(:seed)

        # seed: drawn_seed(n): a seed the save drew (GraphIO.dump marks
        # them), which seeds: :fresh leaves out.
        def drawn_seed(node, scope)
          args, kwargs = call_args(node, scope)
          unless kwargs.empty? && args.length == 1 && args[0].is_a?(Integer)
            raise error(node, 'drawn_seed takes an Integer (seed: drawn_seed(1234))')
          end
          DrawnSeed.new(args[0])
        end

        # &named_proc(:name): a block from GraphIO.procs.
        # bus(:drums) or bus(:drums, only: :kick): a node reading a bus or
        # track of the Session that plays the graph (GraphNode::BusTap).
        # Documents only read buses; defining one (a block, to:) is the
        # console's or a set's.
        def bus_reader(node, scope)
          raise error(node, 'documents read buses (bus(:name)); define them in the console or a set') if node.block
          args, kwargs = call_args(node, scope)
          only = kwargs.delete(:only)
          unless args.length == 1 && args[0].is_a?(Symbol) && kwargs.empty? && (only.nil? || only.is_a?(Symbol))
            raise error(node, 'bus takes a bus or track name and only: a node name (bus(:drums, only: :kick))')
          end
          check_limits(node, MB::Sound, :bus, args, {})
          GraphNode::BusTap.new(args[0], only: only, channels: Session.existing&.channels || 2).node
        end

        def named_proc(node, scope)
          args, = call_args(node, scope)
          name = args[0]
          raise error(node, 'named_proc takes a Symbol (named_proc(:square))') unless args.length == 1 && name.is_a?(Symbol)
          GraphIO.procs.fetch(name) {
            hint = GraphIO.suggest(name, GraphIO.procs.keys)
            raise error(node, "no named proc #{name.inspect}#{hint}; register it with MB::Sound.named_proc(#{name.inspect}) { |buf| ... } before loading")
          }
        end

        ### Limits

        def check_limits(node, receiver, name, args, kwargs)
          @calls += 1
          raise error(node, "the document makes more than #{@limits[:calls]} calls") if @calls > @limits[:calls]
          if @calls % 64 == 0 && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started > @limits[:build_seconds]
            raise error(node, "building took longer than #{@limits[:build_seconds]} seconds")
          end

          if receiver.is_a?(Integer) && name == :** && args[0].is_a?(Integer) && receiver.abs > 1 && args[0] > 64
            raise error(node, "#{receiver} ** #{args[0]} is too large")
          end

          case name
          when :delay, :feedback_delay
            seconds(node, name, args[0]) if args[0]
            seconds(node, name, kwargs[:seconds]) if kwargs[:seconds]
            seconds(node, name, kwargs[:max_delay], 'max_delay:') if kwargs.key?(:max_delay)
          when :multitap, :multitap_delay
            args.each { |a| seconds(node, name, a) }
          when :with_buffer
            count(node, name, samples_of(args[0]), :buffer_samples)
          when :silence, :until
            seconds(node, name, args[0], nil, :render_seconds) if args[0]
          when :wavetable_of
            count(node, name, kwargs[:size], :wavetable_size) if kwargs.key?(:size)
          when :oversample
            count(node, name, args[0], :oversample) if args[0].is_a?(Numeric)
          when :resample
            count(node, name, args[0], :sample_rate) if args[0].is_a?(Numeric)
          when :synth
            count(node, name, kwargs[:voices], :voices) if kwargs.key?(:voices)
          when :new
            count(node, name, kwargs[:voices], :voices) if receiver.is_a?(Class) && receiver <= MB::Sound::Synth && kwargs.key?(:voices)
          when :unison, :swarm
            count(node, name, args[0], :copies) if args[0].is_a?(Numeric)
          when :bursts
            count(node, name, args[0], :copies) if receiver.is_a?(MB::Sound::Drums::Hit)
          when :melody, :motifs
            count(node, name, args[1], :steps) if receiver.equal?(MB::Sound)
          when :repeat, :loop, :ratchet, :roll, :every, :euclid, :grid, :*
            if receiver.is_a?(MB::Sound::Sequence::Clip) || receiver.is_a?(MB::Sound::Sequence::Seq) || name != :*
              args.each { |a| count(node, name, a, :repeats) if a.is_a?(Numeric) }
            end
          end
        end

        def count(node, name, value, key)
          return unless value.is_a?(Numeric)
          if value > @limits[key]
            raise error(node, "#{name}(#{value}) is over the limit of #{@limits[key]} (GraphIO::LIMITS[:#{key}])")
          end
        end

        def samples_of(v)
          v = v.value if v.is_a?(MB::Sound::Length::Samples)
          v
        end

        # Checks a time argument against the delay (or render) limit.
        def seconds(node, name, value, label = nil, key = :delay_seconds)
          s =
            case value
            when MB::Sound::Length::Samples
              value.value.is_a?(Numeric) ? value.value / 48000.0 : nil
            when MB::Sound::Length::Seconds
              value.value.is_a?(Numeric) ? value.value : nil
            when MB::Sound::Sequence::Duration
              # At the slowest tempo the transport allows
              value.whole_notes * 4 * 60.0 / MB::Sound::Sequence::TempoNode::SLOWEST_BPM
            when Numeric then value.real? ? value : nil
            end
          return unless s
          if s > @limits[key]
            raise error(node, "#{name}#{" #{label}" if label} of #{s.round(3)} seconds is over the limit of #{@limits[key]} (GraphIO::LIMITS[:#{key}])")
          end
        end

        def check_result(node, result)
          check_integer(node, result) if result.is_a?(Integer)
        end

        # Files: only relative names inside the document's directory (see
        # FileGuard, which also catches file names reaching other readers).
        def check_file(node, name, args)
          file = args[0]
          return unless file.is_a?(String)
          resolved = FileGuard.check(file, file_context, name.to_s)
          args[0] = resolved unless Registry::KEEP_NAME.include?(name)
        rescue GraphIO::FileError => e
          raise error(node, e.message)
        end

        # Where this document's file names point (see FileGuard).
        def file_context
          @file_context ||= FileGuard::Context.new(@base_dir, @label, @document)
        end

        ### Helpers

        def graph_array?(v)
          v.is_a?(Array) && !v.empty? && v.all? { |x| GraphNode::Recipe.graph_object?(x) }
        end

        def value_key(node)
          raise error(node, 'header keys must be symbols') unless node.is_a?(Prism::SymbolNode)
          node.unescaped.to_sym
        end

        def describe(v)
          case v
          when nil then 'nil'
          when Numeric then "a number (#{v})"
          when Module then v.name || 'a class'
          else "a #{v.class.name&.delete_prefix('MB::Sound::') || v.class}"
          end
        end

        def error(node, message)
          line = node.respond_to?(:location) ? node.location.start_line : nil
          LoadError.new("#{@label}:#{line}: #{message}", path: @path, line: line)
        end
      end
    end
  end
end

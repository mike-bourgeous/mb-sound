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

          def initialize(parent = nil)
            @parent = parent
            @vars = {}
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
        def initialize(text, path: nil, inputs: {}, params: {}, trust: nil, limits: {}, base_dir: nil)
          @text = text
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
          index = read_header(stmts)
          body = stmts[index..] || []
          raise error(tree, 'the document has no graph (only a header)') if body.empty?

          bind_inputs
          bind_params

          @calls = 0
          @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          scope = Scope.new
          result = nil
          body.each { |s| result = eval_node(s, scope) }
          unless GraphNode::Recipe.graph_object?(result) || result.is_a?(MB::Sound::Synth) || graph_array?(result)
            raise error(body.last, "the document's last line must be a graph (got #{describe(result)})")
          end

          @document.knob_nodes = @knobs
          result.instance_variable_set(:@graph_io_document, @document) unless result.frozen?
          result
        end

        # Reads only the header (no graph is built).  Returns a Document.
        def read_document
          tree = parse
          @document = Document.new(path: @path)
          @document.read_comments(@comments)
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

        # Walks a build block's body in +scope+ (called by the procs that
        # #build_proc makes).
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
              raise error(node, 'graph needs a format version (graph 1)') unless version.is_a?(Integer)
              if version > GraphIO::FORMAT
                raise error(node, "the document is format #{version}, newer than this mb-sound reads (#{GraphIO::FORMAT}); update mb-sound")
              end
              @document.format = version
              @document.meta = kwargs
            when :inputs
              bad = args.reject { |a| a.is_a?(Symbol) }
              raise error(node, "inputs takes Symbols (inputs :midi), not #{bad.map(&:inspect).join(', ')}") unless bad.empty?
              @document.inputs.concat(args)
            when :param
              name, value = args
              raise error(node, 'param needs a name and a value (param :drive, 1.0)') unless name.is_a?(Symbol) && args.length == 2
              raise error(node, "param #{name} needs a number (got #{value.inspect})") unless value.is_a?(Numeric) && value.real?
              unknown = kwargs.keys - Document::PARAM_KEYS
              raise error(node, "unknown param option#{'s' if unknown.length > 1} #{unknown.join(', ')} (#{Document::PARAM_KEYS.join(', ')})") unless unknown.empty?
              raise error(node, "param #{name} is declared twice") if @document.params.key?(name)
              @document.params[name] = kwargs.merge(value: value)
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
            raise LoadError.new("#{@label}: missing input#{'s' if missing.length > 1} #{missing.join(', ')} (give #{missing.map { |m| "#{m}: ..." }.join(', ')})", path: @path)
          end

          extra = @given_inputs.keys - declared
          # Overrides of params can arrive mixed with inputs (preset :x, input: a, drive: 2)
          extra -= @document.params.keys
          warn "#{@label}: ignoring input#{'s' if extra.length > 1} #{extra.join(', ')} (the document's inputs: #{declared.empty? ? 'none' : declared.join(', ')})" unless extra.empty?
          @inputs = @given_inputs.slice(*declared)
        end

        # Knobs: one named Constant per param, shared by every use.
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
          @document.params.each do |name, spec|
            value = @overrides.fetch(name, spec[:value])
            raise LoadError.new("#{@label}: param #{name} needs a number (got #{value.inspect})", path: @path) unless value.is_a?(Numeric) && value.real?
            if (r = spec[:range]) && r.is_a?(Range) && @overrides.key?(name) && !range_cover?(r, value)
              warn "#{@label}: param #{name} = #{value} is outside its range #{r}"
            end
            spec[:value] = value
            @knobs[name] = value.constant.named(name.to_s)
          end
        end

        def range_cover?(r, v)
          lo, hi = [r.begin, r.end].minmax
          v >= lo && v <= hi
        end

        ### Evaluation

        def eval_node(node, scope)
          case node
          when Prism::IntegerNode
            check_integer(node, node.value)
          when Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode
            node.value
          when Prism::StringNode
            node.unescaped.dup.freeze
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
              return @inputs[name] if @inputs&.key?(name)
              return @knobs[name] if @knobs&.key?(name)
            end
            return complex(node, scope) if name == :Complex
            return named_proc(node, scope) if name == :named_proc
            if Document::HEADER.include?(name)
              raise error(node, "#{name} belongs in the header, before the graph")
            end
            if @header
              raise error(node, "the header holds values only (#{name} isn't one)")
            end
            unless Registry.top_level.include?(name) && MB::Sound.respond_to?(name)
              if node.variable_call?
                known = scope.names + (@inputs&.keys || []) + (@knobs&.keys || [])
                hint = GraphIO.suggest(name, known + Registry.top_level.to_a)
                raise error(node, "undefined name #{name}#{hint}#{" (the document's inputs: #{@document.inputs.join(', ')})" unless @document.inputs.empty?}")
              end
              hint = GraphIO.suggest(name, Registry.top_level.to_a)
              raise error(node, "#{name} isn't a graph method#{hint}")
            end
            receiver = MB::Sound
          else
            receiver = eval_node(node.receiver, scope)
            if @header && !receiver.is_a?(Numeric)
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
          check_limits(node, receiver, name, args, kwargs)
          check_file(node, name, args) if Registry::FILE_METHODS.include?(name)

          begin
            result = receiver.public_send(name, *args, **kwargs, &block)
          rescue GraphIO::LoadError
            raise
          rescue StandardError => e
            raise error(node, "#{name} raised #{e.class}: #{e.message}")
          end
          check_result(node, result) if receiver.is_a?(Numeric) || result.is_a?(Integer)
          result
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
            raise error(b, "a block argument must be a proc (got #{describe(pr)})") unless pr.is_a?(Proc)
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
        def block_params(b)
          params = b.parameters
          return [[], nil] if params.nil?
          if params.is_a?(Prism::NumberedParametersNode) || params.is_a?(Prism::ItParametersNode)
            raise error(b, 'implicit block parameters (_1, it) aren\'t allowed; name them')
          end
          list = params.is_a?(Prism::BlockParametersNode) ? params.parameters : params
          return [[], nil] if list.nil?
          unless list.optionals.empty? && list.posts.empty? && list.keywords.empty? && list.keyword_rest.nil? && list.block.nil?
            raise error(b, 'block parameters may only be plain names (|v, i|) and a *rest')
          end
          names = list.requireds.map { |r|
            raise error(r, 'destructuring block parameters aren\'t allowed') unless r.is_a?(Prism::RequiredParameterNode)
            r.name
          }
          rest = list.rest&.name
          [names, rest]
        end

        # A build block: a proc that walks the block's body for each call,
        # with its parameters bound in a new scope.  It answers arity,
        # parameters, and lambda? like the literal block, and gives the
        # recorder its locals (GraphNode::Recipe.trace_locals).
        def build_proc(b, outer)
          names, rest = block_params(b)
          loader = self
          count = names.length
          last = nil
          pr = proc do |*args|
            args = args[0] if count > 1 && args.length == 1 && args[0].is_a?(Array)
            scope = Scope.new(outer)
            names.each_with_index { |n, i| scope.vars[n] = args[i] }
            scope.vars[rest] = args[count..] || [] if rest
            last = scope
            loader.walk_block(b.body, scope)
          end
          params = names.map { |n| [:opt, n] }
          params << [:rest, rest] if rest
          arity = rest ? -(count + 1) : count
          pr.define_singleton_method(:arity) { arity }
          pr.define_singleton_method(:parameters) { |**| params }
          pr.define_singleton_method(:lambda?) { false }
          source = b.slice
          pr.define_singleton_method(:graph_io_source) { source }
          pr.define_singleton_method(:graph_io_locals) { last ? last.vars.reject { |k, _| names.include?(k) || k == rest } : {} }
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

        # &named_proc(:name): a block from GraphIO.procs.
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

        # Files: only relative names inside the document's directory.
        def check_file(node, name, args)
          file = args[0]
          return unless file.is_a?(String)
          unless @base_dir
            raise error(node, "#{name} reads a file, which only documents loaded from a file (or with base_dir:) may do")
          end
          if file.start_with?('/', '~') || file.split(%r{[/\\]}).include?('..') || file.match?(/\A[a-zA-Z]:/) || file.include?("\0")
            raise error(node, "#{name}(#{file.inspect}): files must be named relative to the document, inside its directory")
          end
          args[0] = File.join(@base_dir, file)
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

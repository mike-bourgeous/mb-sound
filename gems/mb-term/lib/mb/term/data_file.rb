require 'prism'

module MB
  module Term
    # Reads the UI's data files (layouts, themes, pane files) by walking
    # their Prism tree: never eval, instance_eval, Marshal, or YAML.  A
    # file is a list of calls without receivers whose names come from a
    # closed table per block level, with literal arguments (Symbols,
    # numbers, Strings, true/false/nil, Arrays, Hashes, and Ranges of
    # them, and constants from a closed table), and do...end or { }
    # blocks holding more calls.  Anything else is a LoadError naming the
    # file and line, with did_you_mean suggestions for misspelled calls.
    # The result is a list of Calls that a builder replays, so a file can
    # make only what the Ruby DSL can.  Generic (no MB::Sound types).
    #
    #     calls = DataFile.parse(text, path, calls: { nil => %i[theme], theme: %i[role glyphs] })
    module DataFile
      # A data file that isn't plain data (with file:line in the message).
      class LoadError < StandardError; end

      # One call: +name+, positional +args+, keyword +opts+, +children+
      # (Calls of its block, or nil), and the +line+ it started on.
      Call = Data.define(:name, :args, :opts, :children, :line)

      # Largest file read (bytes) and deepest block nesting.
      MAX_BYTES = 256 * 1024
      MAX_DEPTH = 16

      module_function

      # The Calls in +text+.  +calls+ maps a parent call's name (nil for
      # the top level) to the names allowed inside it (a :* key applies to
      # every level not listed); +constants+ maps constant names allowed
      # as values to their values.
      def parse(text, path = '(data)', calls:, constants: {})
        raise LoadError, "#{path}: larger than #{MAX_BYTES} bytes" if text.bytesize > MAX_BYTES
        result = Prism.parse(text)
        unless result.success?
          e = result.errors.first
          raise LoadError, "#{path}:#{e.location.start_line}: #{e.message}"
        end

        statements(result.value.statements, nil, path, calls, constants, 0)
      end

      # Reads and parses the file at +path+.
      def load(path, **opts)
        raise LoadError, "#{path}: no such file" unless File.file?(path)
        raise LoadError, "#{path}: larger than #{MAX_BYTES} bytes" if File.size(path) > MAX_BYTES
        parse(File.read(path), path, **opts)
      end

      # Replays +calls+ into +builder+ with public_send, blocks becoming
      # blocks that replay their children on the block's self (for
      # builders that instance_exec their blocks) or on the object the
      # block receives.  LoadErrors keep the line of the failing call.
      def replay(builder, calls, path = '(data)')
        calls.each do |c|
          begin
            if c.children
              kids = c.children
              builder.public_send(c.name, *c.args, **c.opts) do |inner = nil|
                DataFile.replay(inner.nil? || inner.is_a?(Symbol) || inner.is_a?(Integer) ? self : inner, kids, path)
              end
            else
              builder.public_send(c.name, *c.args, **c.opts)
            end
          rescue LoadError
            raise
          rescue NoMethodError, ArgumentError => e
            msg = e.respond_to?(:detailed_message) ? e.detailed_message(highlight: false) : e.message
            raise LoadError, "#{path}:#{c.line}: #{msg.lines.first.strip}"
          end
        end
        builder
      end

      def statements(node, parent, path, calls, constants, depth)
        raise LoadError, "#{path}: blocks nested deeper than #{MAX_DEPTH}" if depth > MAX_DEPTH
        return [] if node.nil?
        raise LoadError, "#{path}:#{node.location.start_line}: expected calls (got #{node.class})" unless node.is_a?(Prism::StatementsNode)

        allowed = calls.fetch(parent) { calls.fetch(:*) { [] } }
        node.body.map { |n| call(n, allowed, path, calls, constants, depth) }
      end

      def call(n, allowed, path, calls, constants, depth)
        line = n.location.start_line
        unless n.is_a?(Prism::CallNode) && n.receiver.nil?
          raise LoadError, "#{path}:#{line}: only #{allowed.join(', ')} are allowed here (got #{n.slice[0, 40].inspect})"
        end
        unless allowed.include?(n.name)
          hint = DidYouMean::SpellChecker.new(dictionary: allowed.map(&:to_s)).correct(n.name.to_s).first
          raise LoadError, "#{path}:#{line}: `#{n.name}` isn't allowed here#{hint ? " (did you mean `#{hint}`?)" : ''} (allowed: #{allowed.join(', ')})"
        end

        args = []
        opts = {}
        (n.arguments&.arguments || []).each do |a|
          if a.is_a?(Prism::KeywordHashNode)
            a.elements.each do |el|
              raise LoadError, "#{path}:#{line}: expected key: value" unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
              opts[el.key.unescaped.to_sym] = literal(el.value, path, constants)
            end
          else
            args << literal(a, path, constants)
          end
        end

        children = nil
        if n.block
          raise LoadError, "#{path}:#{line}: #{n.name} takes a block of calls (got #{n.block.class})" unless n.block.is_a?(Prism::BlockNode)
          children = statements(n.block.body, n.name, path, calls, constants, depth + 1)
        end
        Call.new(name: n.name, args: args.freeze, opts: opts.freeze, children: children&.freeze, line: line)
      end

      def literal(node, path, constants)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode then node.value
        when Prism::StringNode then node.unescaped.dup.force_encoding(Encoding::UTF_8).freeze
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        when Prism::ArrayNode then node.elements.map { |e| literal(e, path, constants) }.freeze
        when Prism::HashNode
          node.elements.to_h { |el|
            raise LoadError, "#{path}:#{node.location.start_line}: expected key => value" unless el.is_a?(Prism::AssocNode)
            [literal(el.key, path, constants), literal(el.value, path, constants)]
          }.freeze
        when Prism::RangeNode
          a = node.left && literal(node.left, path, constants)
          b = node.right && literal(node.right, path, constants)
          Range.new(a, b, node.exclude_end?)
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          name = node.slice
          return constants[name] if constants.key?(name)
          hint = DidYouMean::SpellChecker.new(dictionary: constants.keys).correct(name).first
          raise LoadError, "#{path}:#{node.location.start_line}: constant #{name} isn't allowed#{hint ? " (did you mean #{hint}?)" : ''}#{constants.empty? ? '' : " (allowed: #{constants.keys.join(', ')})"}"
        else
          raise LoadError, "#{path}:#{node.location.start_line}: only literal values are allowed (Symbols, numbers, Strings, true/false/nil, Arrays, Hashes, Ranges) (got #{node.slice[0, 40].inspect})"
        end
      end
    end
  end
end

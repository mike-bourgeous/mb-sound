require 'prism'

module MB
  module Sound
    module UI
      # A layout for the band: panes in rows and columns, written as a
      # Ruby block (the top level stacks rows), printed back by #to_ruby,
      # and saved and loaded as Ruby (UI::LayoutLoader; never eval).
      #
      #     layout :mine do
      #       cols { pane :transport; pane :form }
      #       cols do
      #         pane :tracks, width: 30
      #         rows { pane :meters, height: 4; pane :knobs }
      #         pane :scope
      #       end
      #     end
      #
      # +height:+ fixes a pane's (or a row's) rows, +width:+ a pane's
      # columns; other panes share the width by +weight:+ (default: the
      # pane's natural width).  Columns are separated by one blank column.
      # +only: :big+ shows a pane (or a row) only when the terminal is big
      # enough for a scaled-up band (UI::Density decides).
      class Layout
        # One node of the layout tree: +kind+ :rows, :cols, or :pane;
        # +name+ for panes; +opts+ (:height, :width, :weight).
        Node = Struct.new(:kind, :name, :children, :opts) do
          def to_ruby(indent = 1)
            pad = '  ' * indent
            opts_s = opts.map { |k, v| "#{k}: #{RubyValue.text(v) || v.inspect}" }
            if kind == :pane
              "#{pad}pane #{[name.inspect, *opts_s].join(', ')}"
            else
              head = opts_s.empty? ? kind.to_s : "#{kind}(#{opts_s.join(', ')})"
              "#{pad}#{head} do\n#{children.map { |c| c.to_ruby(indent + 1) }.join("\n")}\n#{pad}end"
            end
          end
        end

        # Where a pane landed: its Pane, rectangle (0-based, in the band),
        # and a Hash of state kept for it between frames.
        Placed = Struct.new(:pane, :x, :y, :w, :h, :state, :drawn_at)

        # Builds layout trees (the block of UI.layout): only #pane, #rows,
        # and #cols, so a typo raises NoMethodError with suggestions.
        class Builder
          OPTIONS = %i[height width weight only].freeze

          def initialize(node)
            @node = node
          end

          # A pane by name (see UI.panes), with optional +height:+,
          # +width:+, +weight:+.
          def pane(name, **opts)
            check(opts)
            raise ArgumentError, "Pane names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
            @node.children << Node.new(:pane, name, nil, opts)
            nil
          end

          # Panes side by side.
          def cols(**opts, &block)
            group(:cols, opts, block)
          end
          alias columns cols

          # Panes stacked.
          def rows(**opts, &block)
            group(:rows, opts, block)
          end

          private

          def group(kind, opts, block)
            check(opts)
            raise ArgumentError, "#{kind} needs a block of panes" unless block
            n = Node.new(kind, nil, [], opts)
            Builder.new(n).instance_exec(&block)
            @node.children << n
            nil
          end

          def check(opts)
            bad = opts.keys - OPTIONS
            raise ArgumentError, "Unknown layout option#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')} (#{OPTIONS.map(&:inspect).join(', ')})" unless bad.empty?
            opts.each do |k, v|
              if k == :only
                raise ArgumentError, "Layout only: is one of #{Density::LEVELS.map(&:inspect).join(', ')} (got #{v.inspect})" unless Density::LEVELS.include?(v)
                next
              end
              raise ArgumentError, "Layout #{k}: is a positive Integer (got #{v.inspect})" unless v.is_a?(Integer) && v > 0
            end
          end
        end

        attr_reader :name, :root

        def initialize(name, &block)
          raise ArgumentError, "Layout names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, 'A layout needs a block of panes' unless block

          @name = name
          @root = Node.new(:rows, nil, [], {})
          Builder.new(@root).instance_exec(&block)
          raise ArgumentError, "Layout #{name.inspect} has no panes" if pane_names.empty?
        end

        # The names of the panes, in order.
        def pane_names
          walk(@root).map(&:name)
        end

        # The layout as shown at Density +level+ (:compact, :normal, :big):
        # without the panes and rows whose `only:` needs a bigger level.
        # Returns self when nothing is left out.
        def at_level(level)
          return self unless walk_all(@root).any? { |n| n.opts[:only] }
          copy = dup
          copy.instance_variable_set(:@root, filter(@root, level) || Node.new(:rows, nil, [], {}))
          copy
        end

        # The rows the layout takes (with +panes+, a Hash from name to Pane
        # for natural heights).
        def height(panes = UI.panes)
          natural_height(@root, panes)
        end

        # The natural heights of the layout's top-level rows.
        def row_heights(panes = UI.panes)
          @root.children.map { |c| natural_height(c, panes) }
        end

        # Places the panes in +width+ columns: an Array of Placed (Panes
        # from +panes+; unknown names raise with suggestions).  +height+
        # (more than the natural height) grows the top-level rows taller
        # than one row in proportion to their natural heights (a scaled-up
        # band); +row_gap+ rows go between top-level rows (a band in boxes
        # draws rules there); +x+ and +y+ offset everything.
        def place(width, panes = UI.panes, height: nil, row_gap: 0, x: 0, y: 0)
          walk(@root).each do |n|
            next if panes.key?(n.name)
            hint = DidYouMean::SpellChecker.new(dictionary: panes.keys.map(&:to_s)).correct(n.name.to_s).first
            raise ArgumentError, "No pane #{n.name.inspect} in layout #{@name.inspect}#{hint ? " (did you mean :#{hint}?)" : ''} (panes: #{panes.keys.map(&:inspect).join(', ')})"
          end
          out = []
          heights = grown_heights(panes, height && height - row_gap * [@root.children.length - 1, 0].max)
          @root.children.each_with_index do |c, i|
            place_node(c, x, y, width, heights[i], panes, out)
            y += heights[i] + row_gap
          end
          out
        end

        # The layout as Ruby (a `layout` call that recreates it).
        def to_ruby(**options)
          opts = options.map { |k, v| ", #{k}: #{RubyValue.text(v) || v.inspect}" }.join
          "layout #{@name.inspect}#{opts} do\n#{@root.children.map(&:to_ruby).join("\n")}\nend\n"
        end

        def inspect
          "#<UI::Layout #{@name.inspect} #{height} rows: #{pane_names.map(&:inspect).join(' ')}>"
        end

        private

        # Heights of the top-level rows: natural, with the rows past
        # +total+ shared by the growable rows (taller than one row, no
        # fixed height) in proportion to their natural heights.
        def grown_heights(panes, total)
          nat = row_heights(panes)
          extra = total ? total - nat.sum : 0
          return nat if extra <= 0
          grow = nat.each_index.select { |i| nat[i] > 1 && !@root.children[i].opts[:height] }
          return nat if grow.empty?
          sum = grow.sum { |i| nat[i] }.to_f
          add = grow.to_h { |i| [i, (extra * nat[i] / sum).floor] }
          add[grow.last] += extra - add.values.sum
          nat.each_with_index.map { |h, i| h + add.fetch(i, 0) }
        end

        def walk_all(node)
          [node, *(node.children || []).flat_map { |c| walk_all(c) }]
        end

        def filter(node, level)
          return nil if node.opts[:only] && Density::LEVELS.index(level) < Density::LEVELS.index(node.opts[:only])
          return node if node.kind == :pane
          kids = node.children.filter_map { |c| filter(c, level) }
          kids.empty? ? nil : Node.new(node.kind, node.name, kids, node.opts)
        end

        def walk(node)
          node.kind == :pane ? [node] : node.children.flat_map { |c| walk(c) }
        end

        def natural_height(node, panes)
          return node.opts[:height] if node.opts[:height]
          case node.kind
          when :pane then panes[node.name]&.height || 1
          when :rows then node.children.sum { |c| natural_height(c, panes) }
          else node.children.map { |c| natural_height(c, panes) }.max || 1
          end
        end

        def natural_width(node, panes)
          return node.opts[:weight] if node.opts[:weight]
          case node.kind
          when :pane then panes[node.name]&.width || 20
          when :cols then node.children.sum { |c| natural_width(c, panes) }
          else node.children.map { |c| natural_width(c, panes) }.max || 20
          end
        end

        def place_node(node, x, y, w, h, panes, out)
          return if w <= 0 || h <= 0

          case node.kind
          when :pane
            out << Placed.new(panes.fetch(node.name), x, y, w, h, {}, nil)
          when :rows
            node.children.each_with_index do |c, i|
              ch = i == node.children.length - 1 ? h : [natural_height(c, panes), h].min
              place_node(c, x, y, w, ch, panes, out)
              y += ch
              h -= ch
            end
          when :cols
            gaps = node.children.length - 1
            free = w - gaps - node.children.sum { |c| c.opts[:width].to_i }
            flex = node.children.reject { |c| c.opts[:width] }
            total = flex.sum { |c| natural_width(c, panes) }.to_f
            widths = node.children.map { |c| c.opts[:width] || (total > 0 ? (free * natural_width(c, panes) / total).floor : 0) }
            # Columns lost to rounding go to the last flexible pane
            last = node.children.rindex { |c| !c.opts[:width] }
            widths[last] += w - gaps - widths.sum if last
            x0 = x
            node.children.each_with_index do |c, i|
              cw = [widths[i], x0 + w - x].min
              place_node(c, x, y, cw, h, panes, out)
              x += widths[i] + 1
            end
          end
        end
      end

      # Loads layouts saved by Band#save: Ruby text read by walking its
      # Prism tree (never eval), allowing only `layout :name, options do`
      # with `pane`, `rows`, and `cols` calls whose arguments are literal
      # Symbols, Integers, Floats, true, false, and nil.
      module LayoutLoader
        # A layout file that isn't a plain layout block.
        class LoadError < StandardError; end

        module_function

        # [Layout, options Hash] from +text+ (+path+ for messages).
        def parse(text, path = '(layout)')
          result = Prism.parse(text)
          raise LoadError, "#{path}: #{result.errors.first.message}" unless result.success?

          stmts = result.value.statements.body
          raise LoadError, "#{path}: expected one `layout :name do ... end`" unless stmts.length == 1
          call = stmts[0]
          unless call.is_a?(Prism::CallNode) && call.name == :layout && call.receiver.nil? && call.block.is_a?(Prism::BlockNode)
            raise LoadError, "#{path}:#{call.location.start_line}: expected `layout :name do ... end`"
          end

          args, opts = arguments(call, path)
          raise LoadError, "#{path}: layout takes one Symbol name" unless args.length == 1 && args[0].is_a?(Symbol)

          calls = body_calls(call.block, path)
          layout = Layout.new(args[0]) { LayoutLoader.replay(self, calls) }
          [layout, opts]
        end

        # Replays parsed calls ([name, args, opts, children]) into a
        # Layout::Builder.
        def replay(builder, calls)
          calls.each do |name, args, opts, children|
            if children
              builder.public_send(name, *args, **opts) { LayoutLoader.replay(self, children) }
            else
              builder.public_send(name, *args, **opts)
            end
          end
        end

        def body_calls(block, path)
          body = block.body
          return [] if body.nil?
          raise LoadError, "#{path}: unexpected #{body.class}" unless body.is_a?(Prism::StatementsNode)

          body.body.map { |n|
            unless n.is_a?(Prism::CallNode) && n.receiver.nil? && %i[pane rows cols].include?(n.name)
              raise LoadError, "#{path}:#{n.location.start_line}: only pane, rows, and cols are allowed in a layout"
            end
            args, opts = arguments(n, path)
            children = nil
            if n.block
              raise LoadError, "#{path}:#{n.location.start_line}: #{n.name} takes a do ... end block" unless n.block.is_a?(Prism::BlockNode)
              children = body_calls(n.block, path)
            end
            [n.name, args, opts, children]
          }
        end

        def arguments(call, path)
          args = []
          opts = {}
          (call.arguments&.arguments || []).each do |a|
            if a.is_a?(Prism::KeywordHashNode)
              a.elements.each do |el|
                raise LoadError, "#{path}:#{a.location.start_line}: expected key: value" unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
                opts[el.key.unescaped.to_sym] = literal(el.value, path)
              end
            else
              args << literal(a, path)
            end
          end
          [args, opts]
        end

        def literal(node, path)
          case node
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::IntegerNode, Prism::FloatNode then node.value
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::NilNode then nil
          else raise LoadError, "#{path}:#{node.location.start_line}: only Symbols, numbers, true, false, and nil are allowed (got #{node.slice})"
          end
        end
      end
    end
  end
end

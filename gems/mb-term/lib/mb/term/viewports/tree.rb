module MB
  module Sound
    module UI
      # The viewports layer: a split tree written as a Ruby block, placed
      # into rectangles, changed by interactive operations (Tiler: split,
      # close, resize, swap, equalize, zoom, tabs, focus, undo), and printed
      # back as the same Ruby block (Layout#to_ruby, read back by
      # Viewports::Loader without eval).  Generic (no MB::Sound types).
      #
      #     studio = Viewports.layout :studio, focus: :repl do
      #       pane :transport, height: 1
      #       cols do
      #         pane :tracks, width: 28
      #         rows weight: 2 do
      #           repl
      #           pane :journal, height: 8
      #         end
      #         tabs :meters, :scope, active: :scope
      #       end
      #     end
      #     t = Viewports::Tiler.new(studio, 120, 40)
      #     t.split(:journal, :cols)          # vim's Ctrl-W v
      #     t.resize(:tracks, :right, 4)      # tmux's resize-pane -R 4
      #     puts t.layout.to_ruby             # the declarative form, weights in cells
      #
      # Nodes are immutable Data, so every operation makes a new tree and
      # undo is a stack of trees (Emacs winner-mode).
      module Viewports
        # Layout errors (a bad size, an unknown pane, ...).
        class Error < ArgumentError; end

        # Values a pane option may hold (literals, so layouts save as data).
        def self.literal?(v)
          case v
          when Symbol, Integer, Float, String, true, false, nil then true
          when Array then v.all? { |e| literal?(e) }
          else false
          end
        end

        # A leaf: one pane by name.  +size+ is fixed cells along the
        # parent's axis (rows inside `rows`, columns inside `cols`),
        # +weight+ shares what fixed siblings leave, +min+ is the smallest
        # size it gets, +opts+ the pane's options for this placement
        # (literals: `pane :scope, look: :scope`).
        Pane = Data.define(:name, :size, :weight, :min, :opts) do
          def initialize(name:, size: nil, weight: 1, min: nil, opts: {})
            super(name: name, size: size, weight: weight, min: min, opts: opts.frozen? ? opts : opts.dup.freeze)
          end

          def panes = [name]
        end

        # Children side by side (:cols) or stacked (:rows).
        Split = Data.define(:axis, :children, :size, :weight, :min) do
          def initialize(axis:, children:, size: nil, weight: 1, min: nil)
            super(axis: axis, children: children.frozen? ? children : children.dup.freeze, size: size, weight: weight, min: min)
          end

          def panes = children.flat_map(&:panes)
        end

        # Children sharing one rectangle, one visible (+active+ an index),
        # under a one-row tab strip.
        Tabs = Data.define(:children, :active, :size, :weight, :min) do
          def initialize(children:, active: 0, size: nil, weight: 1, min: nil)
            super(children: children.frozen? ? children : children.dup.freeze, active: active, size: size, weight: weight, min: min)
          end

          def panes = children.flat_map(&:panes)
        end

        # A rectangle of cells (0-based).
        Rect = Data.define(:x, :y, :w, :h) do
          def area = w * h
          def overlap?(o) = x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h
          def contains?(px, py) = px >= x && px < x + w && py >= y && py < y + h
          def to_s = "#{w}x#{h}+#{x}+#{y}"
        end

        # Where something landed: a pane (+name+, +opts+), or a tab strip
        # (+tabs+ the names of its tabs' first panes, +active+ an index).
        Placed = Data.define(:name, :rect, :tabs, :active, :opts) do
          def initialize(name:, rect:, tabs: nil, active: nil, opts: {})
            super
          end
        end

        # Builds the tree from the block of Viewports.layout: only #pane,
        # #repl, #rows, #cols, and #tabs exist, so a typo is a
        # NoMethodError with did_you_mean suggestions.
        class Builder
          # The layout calls (Loader allows only these).
          CALLS = %i[pane repl rows cols columns tabs].freeze

          def initialize(axis)
            @axis = axis
            @children = []
          end

          attr_reader :children

          # A pane by name; +height:+ (in rows) or +width:+ (in cols) fixes
          # its size, +weight:+ shares the rest, +min:+ keeps it from
          # shrinking; other keywords are the pane's options (literals).
          def pane(name, height: nil, width: nil, weight: 1, min: nil, **opts)
            raise Error, "Pane names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
            bad = opts.reject { |_, v| Viewports.literal?(v) }
            raise Error, "#{name.inspect}: pane options are literals (Symbols, numbers, Strings, true/false/nil, Arrays) (got #{bad.keys.map(&:inspect).join(', ')})" unless bad.empty?

            @children << Pane.new(name: name, size: size_for(name.inspect, height, width), weight: check_weight(weight), min: check_min(min), opts: opts)
            nil
          end

          # The REPL's pane (Pry): `repl` is `pane :repl`.
          def repl(**opts) = pane(:repl, **opts)

          # Panes side by side.
          def cols(height: nil, width: nil, weight: 1, min: nil, &block) = group(:cols, height, width, weight, min, block)
          alias columns cols

          # Panes stacked.
          def rows(height: nil, width: nil, weight: 1, min: nil, &block) = group(:rows, height, width, weight, min, block)

          # Tabs: `tabs :meters, :scope, active: :scope`, or a block of
          # panes and splits (`tabs { pane :mix; cols { pane :a; pane :b } }`).
          def tabs(*names, active: 0, height: nil, width: nil, weight: 1, min: nil, &block)
            kids = names.map { |n|
              raise Error, "Tab names are Symbols (got #{n.inspect})" unless n.is_a?(Symbol)
              Pane.new(name: n)
            }
            if block
              b = Builder.new(:tabs)
              b.instance_exec(&block)
              kids += b.children
            end
            raise Error, 'tabs needs at least two tabs' if kids.length < 2

            index = active.is_a?(Symbol) ? kids.index { |k| k.panes.include?(active) } : active
            raise Error, "No tab #{active.inspect} (#{kids.map { |k| k.panes.first.inspect }.join(', ')})" unless index.is_a?(Integer) && kids[index]

            @children << Tabs.new(children: kids, active: index, size: size_for('tabs', height, width), weight: check_weight(weight), min: check_min(min))
            nil
          end

          private

          def group(axis, height, width, weight, min, block)
            raise Error, "#{axis} needs a block of panes" unless block

            b = Builder.new(axis)
            b.instance_exec(&block)
            raise Error, "#{axis} needs at least one pane" if b.children.empty?

            @children << Split.new(axis: axis, children: b.children, size: size_for(axis.to_s, height, width), weight: check_weight(weight), min: check_min(min))
            nil
          end

          def size_for(what, height, width)
            return nil if height.nil? && width.nil?

            case @axis
            when :rows
              raise Error, "#{what}: width: only applies side by side (inside cols); in rows, use height:" if width
              check_cells(height)
            when :cols
              raise Error, "#{what}: height: only applies stacked (inside rows); in cols, use width:" if height
              check_cells(width)
            else
              raise Error, "#{what}: tabs share one rectangle, so their tabs take no height: or width:"
            end
          end

          def check_cells(n)
            raise Error, "Sizes are positive Integers of cells (got #{n.inspect})" unless n.is_a?(Integer) && n > 0
            n
          end

          def check_min(n)
            return nil if n.nil?
            check_cells(n)
          end

          def check_weight(w)
            raise Error, "Weights are positive numbers (got #{w.inspect})" unless w.is_a?(Numeric) && w > 0
            w
          end
        end

        # A named layout: a root (always a :rows Split), the focused pane,
        # the zoomed pane, and the gap between panes (0 or 1: a column between
        # panes side by side, a row between stacked ones).  Equal layouts are
        # == (Data all the way down).
        Layout = Data.define(:name, :root, :focus, :zoom, :gap) do
          def initialize(name:, root:, focus: nil, zoom: nil, gap: 1)
            names = root.panes
            dup = names.tally.select { |_, n| n > 1 }.keys
            raise Error, "Pane names must be unique in a layout (#{dup.map(&:inspect).join(', ')} twice)" unless dup.empty?
            raise Error, "No pane #{focus.inspect} to focus" if focus && !names.include?(focus)
            raise Error, "No pane #{zoom.inspect} to zoom" if zoom && !names.include?(zoom)
            raise Error, "gap: is 0 or 1 (got #{gap.inspect})" unless [0, 1].include?(gap)

            super
          end

          def panes = root.panes

          # True when the layout has a REPL pane (shown in :tiles mode).
          def repl? = panes.include?(:repl)

          # The placements in a +w+ x +h+ screen: an Array of Placed
          # (+header_rule+: a rule under one-row panes too; see
          # Viewports.place).
          def place(w, h, header_rule: false, mins: nil)
            out = []
            if zoom
              leaf = Viewports.find_leaf(root, zoom)
              out << Placed.new(name: zoom, rect: Rect.new(0, 0, w, h), opts: leaf.opts)
            else
              Viewports.place(root, Rect.new(0, 0, w, h), gap, out, header_rule: header_rule, mins: mins)
            end
            out
          end

          # {name => Rect} of the visible panes.
          def rects(w, h, header_rule: false, mins: nil) = place(w, h, header_rule: header_rule, mins: mins).select(&:name).to_h { |p| [p.name, p.rect] }

          # The options of pane +name+ ({} if it has none).
          def options_of(name) = Viewports.find_leaf(root, name)&.opts || {}

          # The layout as the Ruby block that makes it.
          def to_ruby
            opts = { focus: focus, zoom: zoom }.compact
            opts[:gap] = gap unless gap == 1
            head = ["layout #{name.inspect}", *opts.map { |k, v| "#{k}: #{v.inspect}" }].join(', ')
            "#{head} do\n#{root.children.map { |c| Viewports.node_ruby(c, :rows, 1) }.join("\n")}\nend\n"
          end

          def inspect = "#<UI::Viewports::Layout #{name.inspect}: #{panes.map(&:inspect).join(' ')}#{zoom ? " (#{zoom.inspect} zoomed)" : ''}>"
        end

        module_function

        # Viewports.layout :name, focus:, zoom:, gap: do ... end
        def layout(name, focus: nil, zoom: nil, gap: 1, &block)
          raise Error, "Layout names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise Error, 'A layout needs a block of panes' unless block

          b = Builder.new(:rows)
          b.instance_exec(&block)
          raise Error, "Layout #{name.inspect} has no panes" if b.children.empty?

          Layout.new(name: name, root: Split.new(axis: :rows, children: b.children), focus: focus, zoom: zoom, gap: gap)
        end

        def find_leaf(node, name)
          return (node.name == name ? node : nil) if node.is_a?(Pane)
          node.children.each do |c|
            found = find_leaf(c, name)
            return found if found
          end
          nil
        end

        def node_ruby(node, parent_axis, depth)
          pad = '  ' * depth
          opts = {}
          opts[parent_axis == :rows ? :height : :width] = node.size if node.size && parent_axis != :tabs
          opts[:weight] = node.weight unless node.weight == 1
          opts[:min] = node.min if node.min
          case node
          in Pane
            opts.merge!(node.opts)
            return "#{pad}repl#{opts.empty? ? '' : " #{kw(opts)}"}" if node.name == :repl

            "#{pad}pane #{[node.name.inspect, *(kw(opts) unless opts.empty?)].join(', ')}"
          in Split
            "#{pad}#{node.axis}#{opts.empty? ? '' : " #{kw(opts)}"} do\n#{node.children.map { |c| node_ruby(c, node.axis, depth + 1) }.join("\n")}\n#{pad}end"
          in Tabs
            if node.children.all? { |c| c.is_a?(Pane) && c == Pane.new(name: c.name) }
              active = node.active.zero? ? {} : { active: node.children[node.active].name }
              all = active.merge(opts)
              "#{pad}tabs #{[*node.children.map { |c| c.name.inspect }, *(kw(all) unless all.empty?)].join(', ')}"
            else
              opts = { active: node.active }.merge(opts) unless node.active.zero?
              "#{pad}tabs#{opts.empty? ? '' : " #{kw(opts)}"} do\n#{node.children.map { |c| node_ruby(c, :tabs, depth + 1) }.join("\n")}\n#{pad}end"
            end
          end
        end

        def kw(h) = h.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')

        # Sizes of +children+ along a +total+: fixed sizes first, then
        # weights by largest remainder (ties to the earlier child), then
        # minimums (+mins+, one per child; default each child's +min+, else
        # 1): a child under its minimum takes cells one at a time from the
        # sibling furthest above its own, fixed ones included, so a declared minimum
        # holds whenever the total allows it.  Sums to +total+ when any
        # child is flexible.
        def shares(children, total, mins = nil)
          mins ||= children.map { |c| c.min || 1 }
          fixed = children.map(&:size)
          left = [total - fixed.compact.sum, 0].max
          flex = children.each_index.reject { |i| fixed[i] }
          sizes = fixed.map { |s| s || 0 }
          if fixed.compact.sum > total
            # Fixed sizes overflow: shrink from the last child
            over = fixed.compact.sum - total
            children.each_index.reverse_each do |i|
              cut = [over, sizes[i] - 1].min
              next if cut <= 0
              sizes[i] -= cut
              over -= cut
            end
          end
          unless flex.empty?
            wsum = flex.sum { |i| children[i].weight.to_r }
            exact = flex.to_h { |i| [i, left * children[i].weight.to_r / wsum] }
            flex.each { |i| sizes[i] = exact[i].floor }
            rest = left - flex.sum { |i| sizes[i] }
            flex.sort_by { |i| [-(exact[i] - exact[i].floor), i] }.first(rest).each { |i| sizes[i] += 1 }
          end
          children.each_index do |i|
            need = mins[i] - sizes[i]
            next if need <= 0

            # One cell at a time from the sibling furthest above its
            # minimum (ties to the earlier one), so siblings give way
            # evenly
            others = children.each_index.reject { |d| d == i }
            while need > 0
              d = others.max_by { |o| [sizes[o] - mins[o], -o] }
              break if d.nil? || sizes[d] - mins[d] <= 0

              sizes[d] -= 1
              sizes[i] += 1
              need -= 1
            end
          end
          sizes
        end

        # The smallest size of +node+ along +axis+ (:rows or :cols): its own
        # +min+, else what +mins+ (a Proc of a pane name and an axis) says
        # for a pane, else 1; splits add their children's (and the gaps)
        # along their axis and take the largest across it.
        def min_of(node, axis, mins, gap = 1)
          case node
          in Pane then node.min || mins&.call(node.name, axis) || 1
          in Tabs then (axis == :rows ? 1 : 0) + node.children.map { |c| min_of(c, axis, mins, gap) }.max
          in Split
            kids = node.children.map { |c| min_of(c, axis, mins, gap) }
            node.axis == axis ? kids.sum + gap * (kids.length - 1) : kids.max
          end
        end

        # Places +node+ in +rect+, appending Placed to +out+ (+slots+, if
        # given, maps each node to its rectangle, by identity).  Stacked
        # children get +gap+ rows between them except under one-row
        # children (headers keep their height), unless +header_rule+.
        def place(node, rect, gap, out, slots = nil, header_rule: false, mins: nil)
          return if rect.w <= 0 || rect.h <= 0

          slots[node] = rect if slots

          case node
          in Pane
            out << Placed.new(name: node.name, rect: rect, opts: node.opts)
          in Tabs
            out << Placed.new(name: nil, rect: Rect.new(rect.x, rect.y, rect.w, 1), tabs: node.children.map { |c| c.panes.first }, active: node.active)
            place(node.children[node.active], Rect.new(rect.x, rect.y + 1, rect.w, rect.h - 1), gap, out, slots, header_rule: header_rule, mins: mins)
          in Split
            across = node.axis == :cols
            # One column between panes side by side, one row between
            # stacked panes (a rule drawn by the screen; its title goes
            # into it), except under one-row panes (headers keep their
            # height)
            gaps = node.children.each_cons(2).map { |a, _| across || header_rule || a.size != 1 ? gap : 0 }
            total = (across ? rect.w : rect.h) - gaps.sum
            pos = across ? rect.x : rect.y
            axis = across ? :cols : :rows
            least = node.children.map { |c| mins ? min_of(c, axis, mins, gap) : c.min || 1 }
            shares(node.children, total, least).each_with_index do |s, i|
              r = across ? Rect.new(pos, rect.y, s, rect.h) : Rect.new(rect.x, pos, rect.w, s)
              place(node.children[i], r, gap, out, slots, header_rule: header_rule, mins: mins)
              pos += s + gaps[i].to_i
            end
          end
        end

        # Collapses empty and one-child splits (the child takes the
        # split's slot); the root stays a Split.
        def normalize(node, top: true)
          return node if node.is_a?(Pane)

          kids = node.children.map { |c| normalize(c, top: false) }.compact
          return nil if kids.empty? && !top

          if node.is_a?(Tabs)
            return kids.first.with(size: node.size, weight: node.weight, min: node.min) if kids.length == 1
            return node.with(children: kids, active: node.active.clamp(0, kids.length - 1))
          end
          return kids.first.with(size: node.size, weight: node.weight, min: node.min) if kids.length == 1 && !top

          node.with(children: kids)
        end
      end
    end
  end
end

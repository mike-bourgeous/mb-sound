require_relative 'tree'

module MB
  module Sound
    module UI
      module Viewports
        # Interactive state: a layout at a screen size, with undo and redo.
        # Every operation replaces #layout with a new tree and returns self
        # (so they chain: t.split(...).resize(...)).  Not thread-safe by
        # itself: the screen that owns it serializes calls.
        class Tiler
          DIRS = { left: [:cols, -1], right: [:cols, 1], up: [:rows, -1], down: [:rows, 1] }.freeze

          # Undo steps kept.
          UNDO = 100

          attr_reader :layout, :w, :h

          def initialize(layout, w, h)
            @layout = layout
            @w = w
            @h = h
            @undo = []
            @redo = []
            @counter = 0
          end

          # A new screen size (placement follows; the tree is unchanged).
          def resize_screen(w, h)
            @w = w
            @h = h
            self
          end

          # Replaces the layout (undoable).
          def layout=(layout)
            record(layout)
          end

          def rects = @layout.rects(@w, @h)
          def placed = @layout.place(@w, @h)

          # The focused pane (the layout's focus, else the first pane).
          def focus = @layout.focus || @layout.panes.first

          # True if there are steps to undo / redo.
          def undo? = !@undo.empty?
          def redo? = !@redo.empty?

          # Splits +name+ along +axis+ (:cols puts the new pane beside it,
          # like vim's Ctrl-W v; :rows below it, Ctrl-W s), halving its
          # space.  The new pane is +new_name+ (default :empty1, :empty2,
          # ...) and gets focus.
          def split(name = focus, axis = :cols, new_name = nil)
            raise Error, "Split axes are :cols (beside) or :rows (below) (got #{axis.inspect})" unless %i[cols rows].include?(axis)
            find!(name)
            raise Error, "#{new_name.inspect} is already shown" if new_name && @layout.panes.include?(new_name)
            new_name ||= :"empty#{@counter += 1}" while new_name.nil? || @layout.panes.include?(new_name)
            change(focus: new_name, zoom: nil) do |root|
              edit(root, name) do |leaf, parent_axis|
                if parent_axis == axis
                  # Same direction as the parent: become two siblings
                  half = leaf.size ? [leaf.size / 2, 1].max : nil
                  [leaf.with(size: half ? leaf.size - half : nil), Pane.new(name: new_name, size: half, weight: leaf.weight)]
                else
                  [Split.new(axis: axis, children: [leaf.with(size: nil, weight: 1, min: nil), Pane.new(name: new_name)], size: leaf.size, weight: leaf.weight, min: leaf.min)]
                end
              end
            end
          end

          # Removes +name+; a split left with one child is replaced by it.
          def close(name = focus)
            find!(name)
            raise Error, 'The last pane stays' if @layout.panes.length == 1

            left = @layout.panes - [name]
            change(focus: left.include?(@layout.focus) ? @layout.focus : neighbor_of(name, left), zoom: (@layout.zoom == name ? nil : @layout.zoom)) do |root|
              edit(root, name) { [] }
            end
          end

          # Moves +name+'s edge in +dir+ (:left, :right, :up, :down) by
          # +cells+: the edge on that side if there is a neighbor there, else
          # the opposite edge (so the pane shrinks), like tmux's
          # resize-pane.  Siblings' sizes are rewritten as their current
          # cells (fixed sizes stay fixed; weights become cell counts divided
          # by their gcd), so placing at this screen size gives exactly the
          # moved edge, and other sizes keep the proportions.
          def resize(name, dir, cells = 1)
            axis, sign = DIRS.fetch(dir) { raise Error, "Directions are #{DIRS.keys.map(&:inspect).join(', ')} (got #{dir.inspect})" }
            path = path_to(@layout.root, name)
            chosen = nil
            path.each_cons(2).reverse_each do |parent, child|
              next unless parent.is_a?(Split) && parent.axis == axis

              i = parent.children.index { |c| c.equal?(child) }
              j = i + sign
              j = i - sign unless (0...parent.children.length).cover?(j)
              next unless (0...parent.children.length).cover?(j)

              chosen = [parent, i, j]
              break
            end
            return self unless chosen

            parent, i, j = chosen
            grow = (j > i) == (sign > 0) ? cells : -cells
            current = cells_of(parent)
            grow = grow.clamp(-(current[i] - 1), current[j] - 1)
            return self if grow == 0
            current[i] += grow
            current[j] -= grow
            flex = parent.children.each_index.reject { |k| parent.children[k].size }
            div = flex.map { |k| current[k] }.reduce(0) { |a, b| a.gcd(b) }
            div = 1 if div.zero?
            kids = parent.children.each_with_index.map do |c, k|
              c.size ? c.with(size: current[k]) : c.with(weight: current[k] / div)
            end
            change { |root| replace(root, parent, parent.with(children: kids)) }
          end

          # Equal shares for +name+'s siblings (vim's Ctrl-W =, one level).
          def equalize(name = focus)
            parent = path_to(@layout.root, name)[-2]
            change { |root| replace(root, parent, parent.with(children: parent.children.map { |c| c.with(size: nil, weight: 1) })) }
          end

          # Swaps panes +a+ and +b+ (sizes stay with the slots, like tmux's
          # swap-pane).
          def swap(a, b = focus)
            find!(a)
            find!(b)
            change { |root| rename(root, { a => b, b => a }) }
          end

          # Puts pane +new_name+ where +at+ was; if +new_name+ is already
          # shown, the two swap.
          def show(new_name, at: focus)
            find!(at)
            return swap(new_name, at).focus!(new_name) if @layout.panes.include?(new_name)

            change(focus: new_name, zoom: @layout.zoom == at ? new_name : @layout.zoom) { |root| rename(root, { at => new_name }) }
          end

          # Toggles zooming +name+ to the whole screen.
          def zoom(name = focus)
            find!(name)
            change(zoom: @layout.zoom == name ? nil : name, focus: name)
          end

          # Focuses +name+ (not an undo step).
          def focus!(name)
            find!(name)
            change(focus: name, record: false)
          end

          # Panes in reading order (top to bottom, then left to right): the
          # numbers NAV mode shows.
          def numbered = rects.sort_by { |_, r| [r.y, r.x] }.map(&:first)

          # Focus by number (1-based, see #numbered).
          def focus_index(n) = (name = numbered[n - 1]) ? focus!(name) : self

          # Focus the next (+dir+ 1) or previous (-1) pane in reading order.
          def focus_next(dir = 1)
            names = numbered
            return self if names.empty?
            focus!(names[((names.index(focus) || 0) + dir) % names.length])
          end

          # Focus the nearest pane in direction +dir+ (:left, :right, :up,
          # :down) that overlaps the focused pane's span.
          def focus_dir(dir)
            r = rects
            me = r[focus] or return self
            best = r.reject { |n, _| n == focus }.select { |_, o|
              case dir
              when :left then o.x + o.w <= me.x && o.y < me.y + me.h && me.y < o.y + o.h
              when :right then o.x >= me.x + me.w && o.y < me.y + me.h && me.y < o.y + o.h
              when :up then o.y + o.h <= me.y && o.x < me.x + me.w && me.x < o.x + o.w
              when :down then o.y >= me.y + me.h && o.x < me.x + me.w && me.x < o.x + o.w
              else raise Error, "Directions are #{DIRS.keys.map(&:inspect).join(', ')} (got #{dir.inspect})"
              end
            }.min_by { |_, o|
              case dir
              when :left then [me.x - (o.x + o.w), (o.y - me.y).abs]
              when :right then [o.x - (me.x + me.w), (o.y - me.y).abs]
              when :up then [me.y - (o.y + o.h), (o.x - me.x).abs]
              else [o.y - (me.y + me.h), (o.x - me.x).abs]
              end
            }
            best ? focus!(best[0]) : self
          end

          # The next (+dir+ 1) or previous tab of the tabs holding +name+.
          def tab(dir = 1, name = focus)
            tabs = path_to(@layout.root, name).reverse.find { |n| n.is_a?(Tabs) }
            return self unless tabs

            nt = tabs.with(active: (tabs.active + dir) % tabs.children.length)
            change(focus: nt.children[nt.active].panes.first) { |root| replace(root, tabs, nt) }
          end

          def undo
            return self if @undo.empty?

            @redo << @layout
            @layout = @undo.pop
            self
          end

          def redo
            return self if @redo.empty?

            @undo << @layout
            @layout = @redo.pop
            self
          end

          def inspect = "#<UI::Viewports::Tiler #{@layout.name.inspect} #{@w}x#{@h} focus #{focus.inspect}#{@layout.zoom ? " zoom #{@layout.zoom.inspect}" : ''}, #{@undo.length} undo>"

          private

          def record(new)
            return self if new == @layout
            @undo << @layout
            @undo.shift if @undo.length > UNDO
            @redo.clear
            @layout = new
            self
          end

          def change(focus: @layout.focus, zoom: @layout.zoom, record: true)
            root = block_given? ? yield(@layout.root) : @layout.root
            root = Viewports.normalize(root)
            new = Layout.new(name: @layout.name, root: root, focus: focus, zoom: zoom, gap: @layout.gap)
            return self if new == @layout

            if record
              record(new)
            else
              @layout = new
            end
            self
          end

          def find!(name)
            return if @layout.panes.include?(name)
            hint = DidYouMean::SpellChecker.new(dictionary: @layout.panes.map(&:to_s)).correct(name.to_s).first
            raise Error, "No pane #{name.inspect} in the layout#{hint ? " (did you mean :#{hint}?)" : ''} (panes: #{@layout.panes.map(&:inspect).join(', ')})"
          end

          # The pane nearest +name+ in reading order among +left+.
          def neighbor_of(name, left)
            order = numbered
            i = order.index(name) || 0
            (order[0...i].reverse + order[(i + 1)..]).find { |n| left.include?(n) } || left.first
          end

          # Current cells of +parent+'s children along its axis at this size
          # (zoom ignored).
          def cells_of(parent)
            slots = {}.compare_by_identity
            Viewports.place(@layout.root, Rect.new(0, 0, @w, @h), @layout.gap, [], slots)
            parent.children.map { |c| (r = slots[c]) ? (parent.axis == :cols ? r.w : r.h) : 1 }
          end

          def path_to(node, name, path = [])
            path += [node]
            return path if node.is_a?(Pane) && node.name == name
            return nil if node.is_a?(Pane)

            node.children.each do |c|
              found = path_to(c, name, path)
              return found if found
            end
            find!(name) if path.length == 1
            nil
          end

          # Replaces the leaf +name+ by the Array the block returns (given
          # the leaf and its parent's axis).
          def edit(node, name, &block)
            return node if node.is_a?(Pane)

            axis = node.is_a?(Split) ? node.axis : :tabs
            kids = node.children.flat_map do |c|
              c.is_a?(Pane) && c.name == name ? block.call(c, axis) : [edit(c, name, &block)]
            end
            node.with(children: kids)
          end

          def replace(node, old, new)
            return new if node.equal?(old)
            return node if node.is_a?(Pane)

            node.with(children: node.children.map { |c| replace(c, old, new) })
          end

          # Renames leaves (+names+ old => new); options follow the pane.
          def rename(node, names)
            if node.is_a?(Pane)
              return node unless names.key?(node.name)
              other = Viewports.find_leaf(@layout.root, names[node.name])
              return node.with(name: names[node.name], opts: other ? other.opts : {})
            end

            node.with(children: node.children.map { |c| rename(c, names) })
          end
        end
      end
    end
  end
end

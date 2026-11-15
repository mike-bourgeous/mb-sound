module MB
  module Sound
    module Plot
      # A drawing of a graph laid out by rank (design/notes/drawing.md):
      # boxes in columns from the inputs on the left to the outputs on the
      # right, typed wires between their slots, feedback routed under the
      # boxes.  Generic: it takes Boxes and Wires (plain values), never
      # graph nodes; MB::Sound::Plot.graph walks a node graph into them.
      #
      # The layout is built once, in the constructor, and the drawing is
      # frozen (Ractor-shareable), so a poll thread may build it and a
      # painter draw it.  Drawing writes runs of styled cells into a grid
      # (MB::Term::Cells or a native grid, as Canvas does): the console
      # prints a grid's lines, a pane draws a window of it into the
      # screen's grid (#draw).
      #
      #     g = Plot::Graph.new(
      #       boxes: [
      #         Plot::Graph::Box.new(title: 'saw', ins: [], outs: [Plot::Graph::Out.new(name: :out, type: :audio)]),
      #         Plot::Graph::Box.new(title: 'filter', ins: [Plot::Graph::Slot.new(name: :input, type: :audio), Plot::Graph::Slot.new(name: :cutoff, type: :control, value: '800')]),
      #       ],
      #       wires: [Plot::Graph::Wire.new(from: 0, to: 1, in: 0)],
      #     )
      #     puts g
      class Graph
        # An input slot of a box: +name+, +type+ (:audio, :control,
        # :notes), +value+ (text shown inline for a constant, or nil),
        # +feedback+ (true for a slot fed back from downstream), +active+
        # (false for an input not being read: drawn dim).
        Slot = Data.define(:name, :type, :value, :feedback, :active) do
          def initialize(name:, type: :audio, value: nil, feedback: false, active: true) = super
        end

        # An output slot of a box: +name+ and +type+.
        Out = Data.define(:name, :type) do
          def initialize(name: :out, type: :audio) = super
        end

        # A box: +title+ (a few words), input +ins+ (Slots), output +outs+
        # (Outs), and +kind+ (:node, :port for a rack's input port, :out
        # for a rack's output).
        Box = Data.define(:title, :ins, :outs, :kind) do
          def initialize(title:, ins: [], outs: [Out.new], kind: :node) = super
        end

        # A wire from box +from+'s output slot +out+ to box +to+'s input
        # slot +in+ (indexes), of +type+; +feedback+ wires run backward
        # (routed under the boxes); inactive ones are dim.
        Wire = Data.define(:from, :out, :to, :in, :type, :feedback, :active) do
          def initialize(from:, to:, out: 0, in: 0, type: :audio, feedback: false, active: true) = super
        end

        # Where a box landed: 0-based cell column +x+ and row +y+, its
        # size +w+ x +h+, and its rank column +col+ (0 = inputs).
        Placement = Data.define(:x, :y, :w, :h, :col)

        # Columns for a box title and a slot's name (cut with an ellipsis).
        MAX_TITLE = 18
        MAX_SLOT = 14
        MAX_VALUE = 10

        # Crossing counts are skipped above this many segments (the sweeps
        # still run).
        MAX_COUNTED = 1500

        # Wire glyphs by connection mask (N 1, E 2, S 4, W 8).
        N = 1
        E = 2
        S = 4
        W = 8

        SOLID = {
          N | S => '│', E | W => '─', E => '─', W => '─', N => '│', S => '│',
          E | S => '┌', S | W => '┐', N | E => '└', N | W => '┘',
          N | E | S => '├', N | S | W => '┤', E | S | W => '┬', N | E | W => '┴', N | E | S | W => '┼',
        }.freeze

        DOUBLE = {
          N | S => '║', E | W => '═', E => '═', W => '═', N => '║', S => '║',
          E | S => '╔', S | W => '╗', N | E => '╚', N | W => '╝',
          N | E | S => '╠', N | S | W => '╣', E | S | W => '╦', N | E | W => '╩', N | E | S | W => '╬',
        }.freeze

        # Straight pieces by wire type (corners and junctions are solid).
        STRAIGHT = {
          audio: ['─', '│'].freeze,
          control: ['┄', '┆'].freeze,
          notes: ['╌', '╎'].freeze,
        }.freeze

        # Box frame and slot marks.
        FRAME = { tl: '┌', tr: '┐', bl: '└', br: '┘', h: '─', v: '│', in: '▸', out: '├' }.freeze

        # The same picture in ASCII (`glyphs: :ascii`): one character for
        # one character, so the layout is the same.
        ASCII = {
          '─' => '-', '│' => '|', '┄' => '-', '┆' => '|', '╌' => '-', '╎' => '|',
          '┌' => '+', '┐' => '+', '└' => '+', '┘' => '+', '├' => '+', '┤' => '+', '┬' => '+', '┴' => '+', '┼' => '+',
          '═' => '=', '║' => '|', '╔' => '+', '╗' => '+', '╚' => '+', '╝' => '+', '╠' => '+', '╣' => '+', '╦' => '+', '╩' => '+', '╬' => '+',
          '▸' => '>', '…' => '~',
        }.freeze
        # (String#tr's arguments: a '-' in them would mean a range)
        ASCII_FROM = ASCII.keys.join.freeze
        ASCII_TO = ASCII.values.map { |c| c == '-' ? '\\-' : c }.join.freeze

        # Colors by role, used when no UI theme defines the role
        # (MB::Term::Themes): [r, g, b].
        ROLES = {
          text: [208, 208, 208], dim: [128, 128, 128], title: [135, 175, 215], name: [215, 215, 175],
          key: [95, 215, 255], warn: [255, 215, 95], band_mod: [175, 135, 215],
        }.freeze

        # The role a picture style draws in.
        STYLE_ROLES = {
          frame: :dim, title: :name, port: :key, slot: :text, slot_off: :dim, value: :key, note: :dim,
          audio: :text, control: :title, notes: :band_mod, feedback: :warn,
          skip_audio: :dim, skip_control: :dim, skip_notes: :dim,
        }.freeze

        attr_reader :boxes, :wires, :title, :placements, :width, :height

        # Extra text under the drawing (e.g. nodes left out), or nil.
        attr_reader :note

        # +boxes+ (Boxes), +wires+ (Wires), an optional +title+ (a line
        # above the drawing) and +note+ (a line below it).
        def initialize(boxes:, wires:, title: nil, note: nil)
          @boxes = boxes.to_a
          @wires = wires.to_a
          @title = title&.to_s
          @note = note&.to_s
          check_wires
          layout
          picture
          @boxes = @boxes.freeze
          @wires = @wires.freeze
          Ractor.make_shareable(self)
        end

        # [width, height] in cells (the title and note lines included).
        def size
          [@width, @height]
        end

        # The rank columns: Arrays of box indexes, inputs first.
        def columns
          cols = Array.new((@placements.map(&:col).max || -1) + 1) { [] }
          @placements.each_with_index { |p, i| cols[p.col] << i }
          cols.each { |c| c.sort_by! { |i| @placements[i].y } }
          cols
        end

        # The drawing as lines of text with SGR codes for +color+ (a color
        # mode: :truecolor, :ansi256, :ansi16, :none; default the
        # terminal's), +glyphs+ :unicode or :ascii.
        def lines(color: nil, glyphs: :unicode)
          mode = (color || Terminal.color_mode).to_sym
          mode = :ansi256 if mode == :'256'
          grid = MB::Term::Cells.new([@width, 1].max, [@height, 1].max)
          draw(grid, x: 0, y: 0, color: mode != :none, glyphs: glyphs)
          grid.lines(mode).map(&:rstrip)
        end

        # The drawing as one String (see #lines).
        def to_s(**opts)
          lines(**opts).join("\n")
        end

        # Prints the drawing.  Returns nil.
        def show(io: $stdout, **opts)
          io.puts lines(**opts)
          nil
        end

        # Writes the drawing to +path+ by its extension: .txt (plain), .ans
        # (ANSI colors), .html (colored text in a page).  Returns +path+.
        def save(path, **opts)
          data =
            case File.extname(path).downcase
            when '.txt' then to_s(color: :none, **opts) + "\n"
            when '.ans' then to_s(color: :truecolor, **opts) + "\n"
            when '.html' then AnsiHtml.page(to_s(color: :truecolor, **opts), title: @title || 'graph')
            else raise ArgumentError, "Unknown graph drawing extension in #{path.inspect} (.txt, .ans, .html)"
            end
          File.binwrite(path, data)
          path
        end

        # Shows the drawing when the console (Pry, IRB) prints it.
        def pretty_print(q)
          q.text("\n" + to_s)
        end

        def inspect
          "#<MB::Sound::Plot::Graph #{@boxes.length} boxes, #{@wires.length} wires, #{@width}x#{@height}#{@title ? " #{@title.inspect}" : ''}>"
        end

        # Draws the drawing's window from (+scroll+ column, row) into
        # +grid+ (MB::Term::Cells or a native grid) at cell (+x+, +y+),
        # at most +w+ x +h+ cells (default: the whole drawing), clipped to
        # the grid.  +color+ true resolves roles through the UI theme
        # (MB::Term::Themes, else ROLES), a Proc maps a role to [r, g, b],
        # false draws without colors.  Writes runs of cells (no terminal
        # bytes; the screen sends them).  Returns +grid+.
        def draw(grid, x:, y:, w: @width, h: @height, scroll: [0, 0], color: true, glyphs: :unicode)
          sx, sy = scroll
          sx = sx.to_i.clamp(0, [@width - 1, 0].max)
          sy = sy.to_i.clamp(0, [@height - 1, 0].max)
          rows = glyphs == :ascii ? @ascii_rows : @rows
          colors = {}
          [h, @height - sy].min.times do |r|
            row = rows[sy + r]
            gy = y + r
            @runs[sy + r].each do |rx, len, style|
              a = [rx, sx].max
              b = [rx + len, sx + w].min
              next if b <= a

              fg = colors.fetch(style) { colors[style] = style_color(style, color) }
              grid.put_run(x + a - sx, gy, row[a, b - a], fg, nil, 0)
            end
          end
          grid
        end

        # The packed color for picture +style+ (see #draw's +color+).
        def style_color(style, color)
          return nil unless color

          role = STYLE_ROLES.fetch(style)
          rgb = color.respond_to?(:call) ? color.call(role) : Graph.role_rgb(role)
          MB::Term::Cells.pack(rgb)
        end

        # [r, g, b] (or a palette index) for UI role +role+: the current
        # UI theme's (MB::Term::Themes), else ROLES.
        def self.role_rgb(role)
          MB::Term::Themes.rgb(role)
        rescue StandardError
          ROLES[role]
        end

        # The text of +str+ cut to +n+ columns with an ellipsis.
        def self.clip(str, n)
          str = str.to_s
          str.length <= n ? str : "#{str[0, n - 1]}…"
        end

        private

        def check_wires
          n = @boxes.length
          @wires.each do |w|
            raise ArgumentError, "Wire #{w.inspect} names a box that isn't there (#{n} boxes)" unless w.from.between?(0, n - 1) && w.to.between?(0, n - 1)
            raise ArgumentError, "Wire #{w.inspect} names an output slot box #{w.from} doesn't have" unless w.out.between?(0, [@boxes[w.from].outs.length - 1, 0].max)
            raise ArgumentError, "Wire #{w.inspect} names an input slot box #{w.to} doesn't have" unless w.in.between?(0, @boxes[w.to].ins.length - 1)
          end
        end

        # --- Layout --------------------------------------------------------

        # Box sizes, columns, order, rows, and x positions (see
        # design/notes/drawing.md, "The layout").
        def layout
          n = @boxes.length
          box_sizes
          @back = back_edges
          forward = @wires.each_index.reject { |i| @wires[i].feedback || @back[i] }
          @feedback = @wires.each_index.select { |i| @wires[i].feedback || @back[i] }
          col = ranks(forward)
          maxcol = col.max || 0

          # Nodes: boxes, then one placeholder per column a wire skips
          @ncol = col.dup
          @nh = @bh.dup
          @dummy_of = [] # node => wire index (placeholders only)
          @segs = [] # [src node, src row, dst node, dst row, wire index]
          forward.each do |wi|
            w = @wires[wi]
            prev = w.from
            prev_row = w.out
            (col[w.from] + 1...col[w.to]).each do |c|
              d = @ncol.length
              @ncol << c
              @nh << 1
              @dummy_of[d] = wi
              @segs << [prev, prev_row, d, 0, wi]
              prev = d
              prev_row = 0
            end
            @segs << [prev, prev_row, w.to, w.in, wi]
          end
          @nn = @ncol.length
          @out_segs = Array.new(@nn) { [] }
          @in_segs = Array.new(@nn) { [] }
          @segs.each_with_index do |s, si|
            @out_segs[s[0]] << si
            @in_segs[s[2]] << si
          end

          @cols = order(maxcol, n)
          rows_for(maxcol)
          xs_for(maxcol)
        end

        def box_sizes
          @titles = []
          @labels = [] # per box: [[name text, value text or nil], ...]
          @out_labels = []
          @bw = []
          @bh = []
          @boxes.each do |b|
            t = Graph.clip(b.title, MAX_TITLE)
            labels = b.ins.map { |s| [Graph.clip(s.name, MAX_SLOT), s.value && Graph.clip(s.value, MAX_VALUE)] }
            outs = b.outs.length > 1 ? b.outs.map { |o| Graph.clip(o.name.to_s.sub(/\Aout_/, ''), 4) } : []
            ins_w = labels.map { |nm, v| v ? nm.length + 1 + v.length : nm.length }.max || 0
            outs_w = outs.map(&:length).max || 0
            inner = [t.length + 2, ins_w + outs_w + (ins_w > 0 && outs_w > 0 ? 1 : 0), 3].max
            @titles << t
            @labels << labels
            @out_labels << outs
            @bw << inner + 2
            @bh << [b.ins.length, b.outs.length, 1].max + 2
          end
        end

        # Wires (indexes => true) that close a cycle among the forward
        # wires: drawn as feedback.
        def back_edges
          outs = Array.new(@boxes.length) { [] }
          @wires.each_with_index { |w, i| outs[w.from] << i unless w.feedback }
          state = Array.new(@boxes.length, 0) # 0 new, 1 open, 2 done
          back = {}
          @boxes.each_index do |root|
            next unless state[root] == 0

            stack = [[root, 0]]
            state[root] = 1
            until stack.empty?
              frame = stack.last
              node, k = frame
              if k < outs[node].length
                frame[1] = k + 1
                wi = outs[node][k]
                t = @wires[wi].to
                if state[t] == 1
                  back[wi] = true
                elsif state[t] == 0
                  state[t] = 1
                  stack << [t, 0]
                end
              else
                state[node] = 2
                stack.pop
              end
            end
          end
          back
        end

        # Each box's column: the longest path to an output, counted from
        # the right (rack ports first, rack outputs last).
        def ranks(forward)
          n = @boxes.length
          outs = Array.new(n) { [] }
          indeg = Array.new(n, 0)
          forward.each do |wi|
            w = @wires[wi]
            outs[w.from] << w.to
            indeg[w.to] += 1
          end
          # Topological order (forward wires are acyclic now)
          order = []
          queue = (0...n).select { |i| indeg[i] == 0 }
          deg = indeg.dup
          until queue.empty?
            i = queue.shift
            order << i
            outs[i].each do |t|
              deg[t] -= 1
              queue << t if deg[t] == 0
            end
          end
          rank = Array.new(n, 0)
          order.reverse_each do |i|
            outs[i].each { |t| rank[i] = rank[t] + 1 if rank[t] + 1 > rank[i] }
          end
          maxrank = rank.max || 0
          col = rank.map { |r| maxrank - r }
          @boxes.each_with_index do |b, i|
            col[i] = 0 if b.kind == :port
            col[i] = maxrank if b.kind == :out
          end
          # (a port box moved left can't sit right of what it feeds; an out
          # box moved right stays right of its inputs)
          col
        end

        # The order of nodes within each column: the walk order from the
        # outputs (first inputs first), then barycenter sweeps, keeping the
        # order with the fewest crossings.
        def order(maxcol, nboxes)
          seen = Array.new(@nn, false)
          first = Array.new(@nn, Float::INFINITY)
          count = 0
          sinks = (0...@nn).select { |i| @out_segs[i].empty? }
          sinks = sinks.sort_by { |i| [-@ncol[i], i] }
          sinks.each do |s|
            stack = [s]
            until stack.empty?
              i = stack.pop
              next if seen[i]

              seen[i] = true
              first[i] = count
              count += 1
              # (pushed last-first, so the first input is visited first)
              @in_segs[i].sort_by { |si| -@segs[si][3] }.each { |si| stack << @segs[si][0] unless seen[@segs[si][0]] }
            end
          end
          (0...@nn).each { |i| first[i] = count + i if first[i] == Float::INFINITY }

          cols = Array.new(maxcol + 1) { [] }
          (0...@nn).sort_by { |i| [first[i], i] }.each { |i| cols[@ncol[i]] << i }
          set_pos(cols)

          best = cols.map(&:dup)
          best_x = crossings(cols)
          4.times do
            (maxcol - 1).downto(0) { |c| sweep(cols, c, :out) }
            (1..maxcol).each { |c| sweep(cols, c, :in) }
            x = crossings(cols)
            next unless x && best_x && x < best_x

            best_x = x
            best = cols.map(&:dup)
          end
          cols = best
          set_pos(cols)
          cols
        end

        def set_pos(cols)
          @pos = Array.new(@nn, 0)
          cols.each { |c| c.each_with_index { |i, k| @pos[i] = k } }
        end

        # Sorts column +c+ by the mean position of what its nodes connect
        # to on +side+ (:out toward the outputs, :in toward the inputs).
        def sweep(cols, c, side)
          keys = {}
          cols[c].each do |i|
            list = side == :out ? @out_segs[i] : @in_segs[i]
            next if list.empty?

            sum = list.sum { |si|
              s = @segs[si]
              other, row = side == :out ? [s[2], s[3]] : [s[0], s[1]]
              @pos[other] + (row + 1.0) / (@nh[other] + 1)
            }
            keys[i] = sum / list.length
          end
          cols[c] = cols[c].each_with_index.sort_by { |i, k| [keys[i] || k, k] }.map(&:first)
          cols[c].each_with_index { |i, k| @pos[i] = k }
        end

        # Crossings between adjacent columns (nil past MAX_COUNTED).
        def crossings(cols)
          return nil if @segs.length > MAX_COUNTED

          by_col = Hash.new { |h, k| h[k] = [] }
          @segs.each do |s|
            a = @pos[s[0]] + (s[1] + 1.0) / (@nh[s[0]] + 1)
            b = @pos[s[2]] + (s[3] + 1.0) / (@nh[s[2]] + 1)
            by_col[@ncol[s[0]]] << [a, b]
          end
          by_col.values.sum { |list|
            n = 0
            list.each_with_index do |(a1, b1), i|
              (i + 1...list.length).each do |j|
                a2, b2 = list[j]
                n += 1 if (a1 - a2) * (b1 - b2) < 0
              end
            end
            n
          }
        end

        # Rows: each column stacked in order, pulled toward the rows of the
        # wires it connects (sources, then outputs, then sources again).
        def rows_for(maxcol)
          @ny = Array.new(@nn, 0)
          @cols.each { |c| stack(c, c.map { 0 }) }
          [:in, :out, :in].each do |side|
            cs = side == :in ? (1..maxcol).to_a : (maxcol - 1).downto(0).to_a
            cs.each do |c|
              want = @cols[c].map { |i| desired_row(i, side) }
              stack(@cols[c], want)
            end
          end
          top = @ny.min || 0
          @ny.map! { |y| y - top }
        end

        # The row node +i+ would like (its connected slots lined up with
        # the other ends' slots), or its current row.
        def desired_row(i, side)
          list = side == :in ? @in_segs[i] : @out_segs[i]
          return @ny[i] if list.empty?

          ys = list.map { |si|
            s = @segs[si]
            if side == :in
              slot_y(s[0], s[1], :out) - slot_offset(i, s[3], :in)
            else
              slot_y(s[2], s[3], :in) - slot_offset(i, s[1], :out)
            end
          }.sort
          ys[(ys.length - 1) / 2]
        end

        # Places +nodes+ (one column, in order) at their wanted rows,
        # pushed down below the node before (a blank row between boxes).
        def stack(nodes, want)
          bottom = nil
          prev_box = false
          nodes.each_with_index do |i, k|
            box = i < @boxes.length
            y = want[k]
            y = [y, bottom + (box && prev_box ? 1 : 0)].max if bottom
            @ny[i] = y
            bottom = y + @nh[i]
            prev_box = box
          end
        end

        # The row of node +i+'s slot +row+ (an input or output) relative to
        # its top.
        def slot_offset(i, row, _side)
          i < @boxes.length ? row + 1 : 0
        end

        def slot_y(i, row, side)
          @ny[i] + slot_offset(i, row, side)
        end

        # Column x positions and gap tracks.
        def xs_for(maxcol)
          @cw = Array.new(maxcol + 1, 1)
          (0...@nn).each { |i| @cw[@ncol[i]] = [@cw[@ncol[i]], @bw[i] || 1].max }

          # Nets crossing each gap (gap c is after column c; gap -1 before
          # column 0): a source slot and its segments
          @nets = Hash.new { |h, k| h[k] = [] } # [node, row] => segment indexes
          @segs.each_with_index { |s, si| @nets[[s[0], s[1]]] << si }
          tracks = Hash.new { |h, k| h[k] = [] } # gap => [[sort key, net key], ...]
          @nets.each do |key, list|
            src_y = slot_y(key[0], key[1], :out)
            next if list.all? { |si| slot_y(@segs[si][2], @segs[si][3], :in) == src_y }

            tracks[@ncol[key[0]]] << [src_y, key]
          end
          @fb_lane = {}
          base = (0...@nn).map { |i| @ny[i] + @nh[i] }.max || 0
          @feedback.each_with_index do |wi, k|
            w = @wires[wi]
            @fb_lane[wi] = base + 1 + k
            tracks[@ncol[w.from]] << [Float::INFINITY, [:fb_out, wi]]
            tracks[@ncol[w.to] - 1] << [-Float::INFINITY, [:fb_in, wi]]
          end
          @track_x = {}
          @gap_w = {}
          (-1..maxcol).each do |g|
            list = tracks[g].sort_by { |y, key| [y, key.to_s] }
            @gap_w[g] = list.empty? ? (g == -1 || g == maxcol ? 0 : 2) : list.length + 2
            list.each_with_index { |(_, key), t| @track_x[key] = [g, t] }
          end

          @col_x = []
          x = @gap_w[-1]
          (0..maxcol).each do |c|
            @col_x[c] = x
            x += @cw[c] + @gap_w[c]
          end
          @gap_x = { -1 => 0 }
          (0..maxcol).each { |c| @gap_x[c] = @col_x[c] + @cw[c] }
          @nx = (0...@nn).map { |i| @col_x[@ncol[i]] }

          lanes = @feedback.length
          @draw_h = (base > 0 ? base : 1) + (lanes > 0 ? lanes + 1 : 0)
          @draw_w = [x, 1].max
          head = @title ? 1 : 0
          @top = head
          @width = [@draw_w, @title.to_s.length, @note.to_s.length].max
          @height = @draw_h + head + (@note ? 1 : 0)
          @placements = (0...@boxes.length).map { |i| Placement.new(x: @nx[i], y: @ny[i] + @top, w: @bw[i], h: @bh[i], col: @ncol[i]) }.freeze
        end

        def track_x(key)
          g, t = @track_x.fetch(key)
          @gap_x[g] + 1 + t
        end

        # --- Picture -------------------------------------------------------

        # The cells: wires first (merged per net), boxes over them.
        def picture
          w = @width
          h = @height
          @lines = Array.new(w * h) # cell => [[net, mask, style], ...]
          draw_wires
          @chars = Array.new(w * h, ' ')
          @styles = Array.new(w * h)
          resolve_lines
          draw_boxes
          put_text(0, 0, @title, :title) if @title
          put_text(0, h - 1, @note, :note) if @note

          rows = []
          runs = []
          h.times do |y|
            row = @chars[y * w, w].join
            r = []
            x = 0
            while x < w
              st = @styles[y * w + x]
              if st.nil?
                x += 1
                next
              end
              x0 = x
              x += 1 while x < w && @styles[y * w + x] == st
              r << [x0, x - x0, st].freeze
            end
            rows << row.freeze
            runs << r.freeze
          end
          @rows = rows.freeze
          @ascii_rows = rows.map { |r| r.tr(ASCII_FROM, ASCII_TO).freeze }.freeze
          @runs = runs.freeze
          # (the layout's working state let go; set to nil, never removed,
          # so every drawing keeps one instance variable layout)
          %i[@lines @chars @styles @cols @segs @out_segs @in_segs @pos @nets @track_x @gap_w @gap_x @col_x @nx @ny @nh @ncol @bw @bh @cw
             @titles @labels @out_labels @dummy_of @fb_lane @back @feedback @nn @draw_w @draw_h @top].each do |v|
            instance_variable_set(v, nil)
          end
        end

        def wire_style(wi)
          w = @wires[wi]
          return :feedback if w.feedback || @back[wi]

          type = w.type == :notes ? :notes : w.type == :control ? :control : :audio
          w.active ? type : DIM[type]
        end

        # Dim styles by wire type (inactive inputs, skipped ranks).
        DIM = { audio: :skip_audio, control: :skip_control, notes: :skip_notes }.freeze

        # Adds +mask+ bits for +net+ at (+x+, +y+) in the drawing area.
        def mark(x, y, mask, net, style)
          y += @top
          return if x < 0 || y < 0 || x >= @width || y >= @height

          cell = (@lines[y * @width + x] ||= [])
          e = cell.find { |c| c[0] == net }
          if e
            e[1] |= mask
          else
            cell << [net, mask, style]
          end
        end

        def hline(x0, x1, y, net, style, start_w: false, end_e: false)
          a, b = [x0, x1].minmax
          (a..b).each do |x|
            m = 0
            m |= E if x < b || (end_e && x == b)
            m |= W if x > a || (start_w && x == a)
            mark(x, y, m, net, style)
          end
        end

        def vline(x, y0, y1, net, style)
          a, b = [y0, y1].minmax
          (a..b).each do |y|
            m = 0
            m |= S if y < b
            m |= N if y > a
            mark(x, y, m, net, style)
          end
        end

        # A box slot's x: the box's right edge (outputs) or the cell
        # before its left edge (inputs); placeholders span their column.
        def out_x(i)
          i < @boxes.length ? @nx[i] + @bw[i] - 1 : @col_x[@ncol[i]] + @cw[@ncol[i]] - 1
        end

        def in_x(i)
          @nx[i]
        end

        def draw_wires
          # Placeholders: a line across their column
          (@boxes.length...@nn).each do |d|
            wi = @dummy_of[d]
            st = DIM[wire_style(wi)] || :skip_audio
            hline(@col_x[@ncol[d]], @col_x[@ncol[d]] + @cw[@ncol[d]] - 1, @ny[d], [:dummy, d], st, start_w: true, end_e: true)
          end

          @nets.each do |key, list|
            src, row = key
            wi0 = @segs[list[0]][4]
            dim = list.any? { |si| @dummy_of[@segs[si][0]] || @dummy_of[@segs[si][2]] }
            style = wire_style(wi0)
            style = DIM[style] || style if dim
            net = [:net, src, row]
            sx = out_x(src) + 1
            sy = slot_y(src, row, :out)
            if @track_x.key?(key)
              tx = track_x(key)
              hline(sx, tx, sy, net, style, start_w: true)
              ys = [sy]
              list.each do |si|
                s = @segs[si]
                dy = slot_y(s[2], s[3], :in)
                ys << dy
                hline(tx, in_x(s[2]) - 1, dy, net, style, end_e: true)
              end
              vline(tx, ys.min, ys.max, net, style)
            else
              list.each do |si|
                s = @segs[si]
                hline(sx, in_x(s[2]) - 1, sy, net, style, start_w: true, end_e: true)
              end
            end
          end

          @feedback.each do |wi|
            w = @wires[wi]
            net = [:fb, wi]
            sx = out_x(w.from) + 1
            sy = slot_y(w.from, w.out, :out)
            dy = slot_y(w.to, w.in, :in)
            lane = @fb_lane[wi]
            t1 = track_x([:fb_out, wi])
            t2 = track_x([:fb_in, wi])
            hline(sx, t1, sy, net, :feedback, start_w: true)
            vline(t1, sy, lane, net, :feedback)
            hline(t2, t1, lane, net, :feedback)
            vline(t2, dy, lane, net, :feedback)
            hline(t2, in_x(w.to) - 1, dy, net, :feedback, end_e: true)
          end
        end

        def resolve_lines
          @lines.each_with_index do |cell, idx|
            next unless cell

            pick =
              if cell.length == 1
                cell[0]
              else
                # different nets crossing: the horizontal one over the vertical
                cell.find { |c| c[1] & (E | W) != 0 && c[1] & (N | S) == 0 } || cell[0]
              end
            _, mask, style = pick
            @chars[idx] = glyph(mask, style)
            @styles[idx] = style
          end
        end

        def glyph(mask, style)
          return DOUBLE.fetch(mask, '═') if style == :feedback

          type = style == :control || style == :skip_control ? :control : style == :notes || style == :skip_notes ? :notes : :audio
          h, v = STRAIGHT[type]
          case mask
          when E | W, E, W then h
          when N | S, N, S then v
          else SOLID.fetch(mask, '┼')
          end
        end

        def put(x, y, ch, style)
          return if x < 0 || y < 0 || x >= @width || y >= @height

          @chars[y * @width + x] = ch
          @styles[y * @width + x] = style
        end

        def put_text(x, y, str, style)
          str.to_s.each_char.with_index { |c, k| put(x + k, y, c, style) }
        end

        def draw_boxes
          in_wires = Hash.new { |h, k| h[k] = [] }
          out_wired = {}
          @wires.each_with_index do |w, wi|
            in_wires[[w.to, w.in]] << wi
            out_wired[[w.from, w.out]] = true
          end

          @boxes.each_with_index do |b, i|
            x = @nx[i]
            y = @ny[i] + @top
            bw = @bw[i]
            bh = @bh[i]
            title_style = b.kind == :node ? :title : :port

            # Frame
            put(x, y, FRAME[:tl], :frame)
            (1...bw - 1).each { |k| put(x + k, y, FRAME[:h], :frame) }
            put(x + bw - 1, y, FRAME[:tr], :frame)
            put_text(x + 2, y, @titles[i], title_style) unless @titles[i].empty?
            put(x + 1, y, ' ', :frame) unless @titles[i].empty?
            put(x + 2 + @titles[i].length, y, ' ', :frame) unless @titles[i].empty?
            (1...bh - 1).each do |r|
              put(x, y + r, FRAME[:v], :frame)
              (1...bw - 1).each { |k| put(x + k, y + r, ' ', :frame) }
              put(x + bw - 1, y + r, FRAME[:v], :frame)
            end
            put(x, y + bh - 1, FRAME[:bl], :frame)
            (1...bw - 1).each { |k| put(x + k, y + bh - 1, FRAME[:h], :frame) }
            put(x + bw - 1, y + bh - 1, FRAME[:br], :frame)

            # Input slots
            b.ins.each_with_index do |s, k|
              ry = y + 1 + k
              ws = in_wires[[i, k]]
              put(x, ry, FRAME[:in], wire_style(ws[0])) unless ws.empty?
              name, value = @labels[i][k]
              put_text(x + 1, ry, name, s.active ? :slot : :slot_off)
              put_text(x + 2 + name.length, ry, value, :value) if value
            end

            # Output slots
            b.outs.each_with_index do |_o, k|
              ry = y + 1 + k
              label = @out_labels[i][k]
              put_text(x + bw - 1 - label.length, ry, label, :slot) if label
              put(x + bw - 1, ry, FRAME[:out], :frame) if out_wired[[i, k]]
            end
          end
        end
      end
    end
  end
end

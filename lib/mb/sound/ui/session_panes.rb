module MB
  module Sound
    module UI
      module Panes
        # Buses and sends (ux-1 r3 item 29): each bus with its state (asleep,
        # muted, its CPU share), where it goes, and what its chain is; each
        # send into it as a level meter (sends are hidden knobs: a -60..+6 dB
        # meter like the knob pane's); and, with rows to spare, the routing
        # as a tree from the master: buses, the tracks they take, sends
        # marked.  Bus input/output meters need a render-thread hook in
        # Session::Buses (proposed).
        class Buses < Pane
          # Send meters show -60..+6 dB.
          FLOOR = -60.0
          TOP = 6.0

          def initialize = super(:buses, rate: 4, height: 8, width: 36, title: 'buses', min_height: 2,
                                          description: 'buses and sends: state, destination, send levels, and the routing tree')

          def draw_body(c, s, _state)
            return unless s
            buses = s.buses
            if buses.empty?
              c.puts ['no buses ', :dim], ['(bus :verb { |sig| sig.reverb(:hall, mix: 1) })', :dim]
              return
            end
            loads = s.parts.select { |p| p.kind == :bus }.to_h { |p| [p.name, p] }
            sends = Hash.new { |h, k| h[k] = [] }
            s.routes.each { |player, r| (r[:send] || {}).each { |bus, level| sends[bus] << [player, level] } }

            rows = []
            buses.each do |b|
              rows << [:bus, b, loads[b.name]]
              sends[b.name].each { |player, level| rows << [:send, player, level] }
            end
            tree_rows = c.h - rows.length - 1
            show = rows.first(c.h)
            name_w = [[buses.map { |b| b.name.to_s.length }.max.to_i, 4].max, 10].min
            show.each_with_index do |(kind, a, b), y|
              if kind == :bus
                glyph, role = a.muted ? [c.glyph(:off), :dim] : a.asleep ? [c.glyph(:off), :dim] : [c.glyph(:on), :ok]
                x = c.line(y, [glyph, role], ' ', [c.pad(a.name, name_w), :name], [" #{c.glyph(:arrow)} ", :dim], [a.to.to_s, :key])
                state = a.muted ? ' muted' : a.asleep ? ' asleep' : ''
                pct = b ? "  #{Panes.load_text(b.load)[0]}" : ''
                c.text(x, y, c.fit("#{state}#{pct}  #{a.description}", c.w - x), :dim)
              else
                x = c.line(y, ['  ', nil], [c.pad(a, name_w), :text], ' ')
                db = level_db(b)
                value = b.is_a?(Numeric) ? Panes.db(db) : b.to_s
                mw = [c.w - x - value.length - 1, 3].max
                frac = db ? ((db - FLOOR) / (TOP - FLOOR)).clamp(0.0, 1.0) : 0.0
                x = c.meter(frac, width: mw, x: x, y: y, role: :key)
                c.text(x + 1, y, value, :text)
              end
            end
            return if tree_rows < 4

            draw_tree(c.sub(0, rows.length + 1, c.w, c.h - rows.length - 1), s, sends)
          end

          # dB for a send level (a linear gain), or nil (a follow).
          def level_db(level)
            return nil unless level.is_a?(Numeric)
            level > 0 ? 20 * Math.log10(level) : -Float::INFINITY
          end

          private

          # The routing tree from the master (UI::TreeText): buses by where
          # they go, players by their main out, sends as "name (send)".
          def draw_tree(c, s, sends)
            kids = Hash.new { |h, k| h[k] = [] }
            key = ->(to) { to.nil? || to == :master ? [:node, :master] : [:bus, to] }
            s.buses.each { |b| kids[key.(b.to)] << [:bus, b.name] }
            players = (s.routes.keys + s.players.map(&:name)).uniq
            players.each { |p| kids[key.(s.routes.dig(p, :to))] << [:player, p] }
            sends.each { |bus, list| list.each { |player, _| kids[[:bus, bus]] << [:send, player] } }
            kids.default_proc = nil
            root = [:node, :master]
            lines = TreeText.lines(root, children: ->(n) { n[0] == :bus || n == root ? kids[n] || [] : [] }, glyphs: c.glyph(:sep) == '|' ? :ascii : :unicode)
            c.text(0, 0, 'routing', :dim) if c.h > 0
            lines.first(c.h - 1).each_with_index do |(prefix, (kind, name)), i|
              x = c.text(0, i + 1, prefix, :dim)
              label, role = case kind
                            when :node then [name.to_s, :title]
                            when :bus then [name.to_s, :key]
                            when :send then ["#{name} (send)", :dim]
                            else [name.to_s, :name]
                            end
              c.text(x, i + 1, label, role)
            end
          end
        end

        # The changes that landed (ux-1 r3 item 32a): the journal's landed
        # entries with where they landed, newest at the bottom.
        class Log < Pane
          def initialize = super(:log, rate: 4, height: 6, width: 30, title: 'landed', min_height: 2,
                                       description: 'changes that landed (the journal), at bar:beat, newest at the bottom')

          def draw_body(c, s, _state)
            list = s&.landed || []
            if list.empty?
              c.puts ['nothing landed yet', :dim]
              return
            end
            list.last(c.h).each_with_index do |e, y|
              x = c.line(y, [e.lands.ljust(6), :queued], ' ', [e.kind.to_s, :dim], ' ')
              c.text(x, y, e.subject.inspect, :name)
            end
          end
        end

        # The launch lane (ux-1 r3 item 32d): the next bars from the
        # playhead at the left, queued changes as marks moving toward it,
        # the next one's countdown in beats, and a flash when one lands.
        class Lane < Pane
          # Bars the lane shows.
          BARS = 4

          # Seconds a landed change flashes.
          FLASH = 0.8

          def initialize = super(:lane, rate: 15, height: 4, width: 40, title: 'launch lane', min_height: 2,
                                        description: 'queued changes moving toward the playhead, with a beat countdown to the next')

          def draw_body(c, s, _state)
            return unless s
            len = s.bar_length.to_r
            now = MB::U.clock_now
            flash = s.landed.reverse.find { |e| e.at && now - e.at < FLASH }
            q = s.queued.select { |e| e.pos }.sort_by(&:pos)
            nxt = q.find { |e| e.pos >= s.pos }
            if flash
              c.run(0, 0, c.fit(" landed: #{flash.kind} #{flash.subject.inspect} ", c.w), :ok, reverse: true)
            elsif nxt
              beats = ((nxt.pos - s.pos) * 4).to_f
              c.line(0, ['next ', :dim], ["#{nxt.kind} #{nxt.subject.inspect}", :name], [' in ', :dim], [format('%.1f', beats), :key], [' beats', :dim])
            else
              c.puts ['nothing queued', :dim]
            end
            return if c.h < 2 || c.w < 8

            span = c.w - 1
            # The lane: bar lines, the playhead, queued marks
            line = Array.new(span, '·')
            (0..BARS).each { |b| x = (b * span / BARS.to_f).floor; line[x] = '│' if x < span }
            c.text(0, 1, '▶', :ok)
            c.text(1, 1, line.join, :dim)
            labels = []
            q.each do |e|
              d = ((e.pos - s.pos) / (len * BARS)).to_f
              next unless d >= 0 && d < 1
              x = 1 + (d * span).floor
              c.text(x, 1, '◆', e.equal?(nxt) ? :key : :queued)
              labels << [x, "#{e.kind} #{e.subject}"]
            end
            labels.first(c.h - 2).each_with_index { |(x, t), i| c.text([x - 1, 0].max, 2 + i, c.fit(t, c.w - [x - 1, 0].max), :dim) }
          end
        end

        # The clips the set uses (ux-1 r3 item 32e; read-only for now: Enter
        # to swap comes later): name, kind, length in bars, a one-line
        # picture of its onsets, and where it is used.  +filter+ (a String
        # or Regexp) narrows the list.
        class Clips < Pane
          attr_accessor :filter

          def initialize
            super(:clips, rate: 2, height: 8, width: 50, title: 'clips', min_height: 2,
                          description: 'the clips tracks and scenes use: length, a picture of their notes, where used')
            @filter = nil
          end

          def draw_body(c, s, _state)
            list = s&.clips || []
            list = list.select { |e| e.name.match?(@filter.is_a?(Regexp) ? @filter : /#{Regexp.escape(@filter.to_s)}/i) } if @filter
            if list.empty?
              c.puts [@filter ? "no clips match #{@filter.inspect}" : 'no clips in tracks or scenes', :dim]
              return
            end
            name_w = [[list.map { |e| e.name.length }.max, 6].max, 14].min
            pat_w = [[c.w - name_w - 12, 8].max, Poll::PATTERN].min
            list.first(c.h).each_with_index do |e, y|
              x = c.line(y, [c.pad(e.name, name_w), :name], ' ', [format('%4s', Panes.fmt(e.bars.to_f)), :key], ['b ', :dim])
              pattern = e.pattern.length > pat_w ? e.pattern.chars.each_slice((e.pattern.length / pat_w.to_f).ceil).map { |sl| sl.include?('█') ? '█' : sl.include?('─') ? '─' : ' ' }.join : e.pattern
              x = c.text(x, y, pattern, :armed)
              c.text(x + 1, y, c.fit(e.used.map(&:to_s).join(' '), [c.w - x - 1, 0].max), :dim)
            end
          end
        end

        # MIDI (ux-1 r3 item 32f): knobs mapped to controllers with the
        # controller's last value beside the knob's (the gap a pickup
        # takeover waits to close), then the latest events, newest at the
        # bottom.
        class Midi < Pane
          def initialize = super(:midi, rate: 8, height: 8, width: 36, title: 'midi', min_height: 2,
                                        description: 'MIDI: controllers mapped to knobs (hardware vs knob) and the latest events')

          def draw_body(c, s, _state)
            m = s&.midi
            if m.nil? || (m.events.empty? && m.mapped.empty?)
              c.puts ['no MIDI yet', :dim]
              return
            end
            values = s.knobs.to_h { |k| [k.name, k] }
            y = 0
            m.mapped.each do |name, cc|
              break if y >= c.h
              k = values[name]
              hw = m.ccs[cc]
              x = c.line(y, [c.pad(name, 6), :name], [" cc#{cc} ", :dim])
              mw = [(c.w - x - 4) / 2, 3].max
              x = c.meter(hw ? hw / 127.0 : 0.0, width: mw, x: x, y: y, role: :queued)
              x = c.text(x + 1, y, '', nil)
              pos = k ? k.spec.position(k.value).to_f : 0.0
              x = c.meter(pos, width: mw, x: x, y: y, role: :key)
              gap = hw && k ? (hw / 127.0 - pos).abs : 0
              c.text(x + 1, y, gap > 0.02 ? '≠' : '', :warn)
              y += 1
            end
            rows = c.h - y
            m.events.last(rows).each do |stamp, src, kind, text|
              x = c.line(y, [stamp.ljust(6), :dim], ' ')
              x = c.text(x, y, text, kind == :on ? :name : kind == :cc ? :key : :dim)
              c.text(x + 1, y, c.fit(src.to_s, [c.w - x - 1, 0].max), :dim)
              y += 1
            end
          end
        end
      end
    end
  end
end

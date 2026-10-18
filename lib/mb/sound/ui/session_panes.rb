module MB
  module Sound
    module UI
      module Panes
        # Buses (ux-1 r3 item 29, meters ux-r4): a bus is a named chain, and
        # tracks reach it two ways, both shown as what feeds it: routed
        # whole (`to:`) or by a level (`send:`).  Each bus: its state
        # (asleep, muted, CPU), where it goes, its chain, input and output
        # meters; under it each source (`to:`) and each send with its
        # level as a -60..+6 dB gain and a meter of what it sends; with rows
        # to spare, the routing as a tree from the master.
        #
        # Data: Snapshot#buses/#routes (Poll), #bus_levels and
        # #send_levels (per buffer while this pane shows: needs :buses).
        class Buses < Pane
          # Send gains show -60..+6 dB.
          FLOOR = -60.0
          TOP = 6.0

          jump 'b'

          # (UI::PaneRates: meters first, at the target rate)
          def priority = :meter

          def initialize = super(:buses, rate: 15, height: 8, width: 40, title: 'buses', min_height: 2, needs: [:buses],
                                          description: 'buses (named chains): input and output meters, what feeds each (to: whole, send: a level), the routing tree')

          def draw_body(c, s, _state)
            return unless s
            buses = s.buses
            if buses.empty?
              c.puts ['no buses ', :dim], ['(bus :verb { |sig| sig.reverb(:hall, mix: 1) }; track :keys, send: { verb: -12.db })', :dim]
              return
            end
            loads = s.parts.select { |p| p.kind == :bus }.to_h { |p| [p.name, p] }
            feeds = feeds_of(s)
            levels = s.bus_levels || {}
            sends = s.send_levels || {}

            rows = []
            buses.each do |b|
              rows << [:bus, b, loads[b.name]]
              rows << [:levels, b, levels[b.name]] if s.bus_levels && c.w >= 30
              feeds[b.name].each { |player, how, gain| rows << [:feed, player, how, gain, sends[[player, b.name]]] }
            end
            name_w = [[(buses.map { |b| b.name.to_s.length } + feeds.values.flatten(1).map { |f| f[0].to_s.length + 2 }).max.to_i, 4].max, 12].min
            rows.first(c.h).each_with_index do |row, y|
              case row[0]
              when :bus then bus_row(c, y, row[1], row[2], name_w)
              when :levels then levels_row(c, y, row[2], name_w)
              else feed_row(c, y, *row.drop(1), name_w)
              end
            end
            return if c.h - rows.length - 1 < 4

            draw_tree(c.sub(0, rows.length + 1, c.w, c.h - rows.length - 1), s, feeds)
          end

          # What feeds each bus: { bus => [[player, :to or :send, gain], ...] }
          # (gain a linear send level, a follow's name, or nil for to:).
          def feeds_of(s)
            feeds = Hash.new { |h, k| h[k] = [] }
            s.routes.each do |player, r|
              feeds[r[:to]] << [player, :to, nil] if r[:to] && r[:to] != :master
              (r[:send] || {}).each { |bus, level| feeds[bus] << [player, :send, level] }
            end
            feeds
          end

          private

          def bus_row(c, y, b, load, name_w)
            glyph, role = b.muted || b.asleep ? [c.glyph(:off), :dim] : [c.glyph(:on), :ok]
            x = c.line(y, [glyph, role], ' ', [c.pad(b.name, name_w), :name], [" #{c.glyph(:arrow)} ", :dim], [b.to.to_s, :key])
            state = b.muted ? ' muted' : b.asleep ? ' asleep' : ''
            pct = load ? "  #{Panes.load_text(load.load)[0]}" : ''
            c.text(x, y, c.fit("#{state}#{pct}  #{b.description}", c.w - x), :dim)
          end

          # Input and output meters side by side ("in ▕███  ▏-18.2 out ...").
          def levels_row(c, y, lv, name_w)
            x = name_w + 2
            half = (c.w - x) / 2
            [['in ', lv&.input], ['out ', lv&.output]].each_with_index do |(label, l), i|
              x0 = x + i * half
              db = l ? l.short : nil
              peak = l ? l.peak.max : nil
              v = Panes.db(peak).rjust(5)
              x1 = c.text(x0, y, label, :dim)
              mw = [half - label.length - v.length - 2, 2].max
              x1 = c.meter(Panes.db_frac(db), width: mw, x: x1, y: y, zones: Panes::DB_ZONES, hold: Panes.db_frac(peak))
              c.text(x1 + 1, y, v, peak && peak > -1.0 ? :bad : :dim)
            end
          end

          # A source: "← kick  to:" or "← bass  -12.0 dB" with the sent
          # signal's meter.
          def feed_row(c, y, player, how, gain, send, name_w)
            x = c.line(y, [' ', nil], ["#{c.glyph(:sep) == '|' ? '<' : '←'} ", :dim], [c.pad(player, name_w - 2), :text], ' ')
            label = if how == :to
                      'to:'
                    else
                      db = send ? send.gain : level_db(gain)
                      db ? "#{Panes.db(db)} dB" : "follows #{gain}"
                    end
            x = c.text(x, y, label.rjust(9), how == :to ? :key : :text)
            l = send&.level
            return unless l
            peak = l.peak.max
            v = Panes.db(peak).rjust(5)
            mw = [c.w - x - v.length - 2, 2].max
            x = c.meter(Panes.db_frac(l.short), width: mw, x: x + 1, y: y, role: :key, hold: Panes.db_frac(peak))
            c.text(x + 1, y, v, :dim)
          end

          public

          # dB for a send level (a linear gain), or nil (a follow).
          def level_db(level)
            return nil unless level.is_a?(Numeric)
            level > 0 ? 20 * Math.log10(level) : -Float::INFINITY
          end

          private

          # The routing tree from the master (UI::TreeText): buses by where
          # they go, players by their main out, sends as "name (send)".
          def draw_tree(c, s, feeds)
            kids = Hash.new { |h, k| h[k] = [] }
            key = ->(to) { to.nil? || to == :master ? [:node, :master] : [:bus, to] }
            s.buses.each { |b| kids[key.(b.to)] << [:bus, b.name] }
            players = (s.routes.keys + s.players.map(&:name)).uniq
            players.each { |p| kids[key.(s.routes.dig(p, :to))] << [:player, p] }
            feeds.each { |bus, list| list.each { |player, how, _| kids[[:bus, bus]] << [:send, player] if how == :send } }
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
            # Clocks (time-automation) on the bottom rows the labels leave
            clocks = s.clocks
            free = c.h - 2 - [labels.length, c.h - 2].min
            shown = clocks.first([free, clocks.length].min)
            labels.first(c.h - 2 - shown.length).each_with_index { |(x, t), i| c.text([x - 1, 0].max, 2 + i, c.fit(t, c.w - [x - 1, 0].max), :dim) }
            shown.each_with_index { |k, i| Lane.clock_row(c, c.h - shown.length + i, k) }
          end

          # One clock row: name, a phase bar, what it is, and its count.
          def self.clock_row(c, y, k)
            x = c.line(y, ['⏱ ', :dim], [k.name.to_s, :name], ' ')
            bar = [[c.w / 5, 4].max, 10].min
            x = c.meter(k.phase, width: bar, x: x, y: y, role: :key)
            c.text(x + 1, y, c.fit("#{k.unit == :cycles ? 'cycle' : 'bar'} #{k.count} · #{k.what}", [c.w - x - 1, 0].max), :dim)
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

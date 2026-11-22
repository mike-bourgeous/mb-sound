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
        #
        # In its mode (NAV Enter or b; ui-phase1-1, the plan's Phase 1 item
        # 6: "it shows each send's level in dB but nothing can change it"):
        # Up/Down pick a bus or a send row (reversed; the rows scroll to
        # it), Left/Right the picked send a dB down or up (Shift or H/L 0.1
        # dB; the row shows the value at once, carried as the other panes'
        # values are, and ONE `feed :pad, :verb, -11.0.db` line runs when
        # the keys stop: see #key_send), 0 closes the send (`feed :pad,
        # :verb, 0`), Enter types its level, m mutes or unmutes the picked
        # bus (or the bus of the picked send: `mute :verb`).  A bus has no
        # level of its own (no fader; `level` refuses a bus), so its row's
        # arrows say so.  Feed lines show on the pane's last row in the mode,
        # as level lines do; outside the mode the pane draws as before.
        class Buses < Pane
          include CarriedValues

          # Send gains show -60..+6 dB.
          FLOOR = -60.0
          TOP = 6.0

          # The unit after a send's level, by tap point (#feed_row).
          FEED_UNITS = { send: 'dB', pre_send: 'pre', pre_mute_send: 'prm' }.freeze

          # The loudest send the keys set (Session::Buses::MAX_SEND, +24 dB).
          MAX_DB = (20 * Math.log10(Session::Buses::MAX_SEND)).floor.to_f

          # Where Right takes a send that is off.
          OFF_START = -40.0

          # Seconds without a send key before its line runs (as a held
          # level key's: UI::TurnGesture::GAP).
          GAP = TurnGesture::GAP

          jump 'b'

          mode_keys do
            group 'Buses'
            on [:up, 'k'], :pick, -1, help: 'the bus or send above, below', label: 'Up Down'
            on [:down, 'j'], :pick, 1, help: 'the bus or send above, below', label: 'Up Down'
            on [:left, 'h'], :send, -1.0, help: 'the send a dB down, up (held: one feed line when you let go)', label: 'Left Right'
            on [:right, 'l'], :send, 1.0, help: 'the send a dB down, up (held: one feed line when you let go)', label: 'Left Right'
            on [:left, :shift], :send, -0.1, help: 'the send 0.1 dB down'
            on [:right, :shift], :send, 0.1, help: 'the send 0.1 dB up'
            on ['H'], :send, -0.1, help: 'the send 0.1 dB down'
            on ['L'], :send, 0.1, help: 'the send 0.1 dB up'
            on '0', :close_send, help: 'close the send (feed :pad, :verb, 0)'
            on :enter, :ask_send, help: 'type the send\'s level (feed :pad, :verb, -9.db)', label: 'Enter'
            on 'm', :mute_bus, help: 'mute, unmute the bus (mute :verb)'
            on 'e', :edit_line, help: PaneKeys::EDIT_HELP
            on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
          end

          # (UI::PaneRates: meters first, at the target rate)
          def priority = :meter

          def initialize = super(:buses, rate: 15, height: 8, width: 40, title: 'buses', min_height: 2, needs: [:buses],
                                          description: 'buses (named chains): input and output meters, what feeds each (to: whole, send: a level), the routing tree; turn sends and mute buses from its keys')

          def draw_body(c, s, state)
            return unless s
            state[:snap] = s
            mode = state[:mode]
            if mode && state[:turn_line] && c.h >= 4
              c.text_fit(0, c.h - 1, state[:turn_line], c.w, :dim)
              c = c.sub(0, 0, c.w, c.h - 1)
            end
            buses = s.buses
            if buses.empty?
              state[:rows] = nil
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
              feeds[b.name].each { |player, how, gain| rows << [:feed, player, how, gain, sends[[player, b.name]], b.name] }
            end
            name_w = [[(buses.map { |b| b.name.to_s.length } + feeds.values.flatten(1).map { |f| f[0].to_s.length + 2 }).max.to_i, 4].max, 12].min
            return draw_mode(c, state, rows, name_w) if mode
            rows.first(c.h).each_with_index do |row, y|
              case row[0]
              when :bus then bus_row(c, y, row[1], row[2], name_w)
              when :levels then levels_row(c, y, row[2], name_w)
              else feed_row(c, y, row[1], row[2], row[3], row[4], name_w)
              end
            end
            return if c.h - rows.length - 1 < 4

            draw_tree(c.sub(0, rows.length + 1, c.w, c.h - rows.length - 1), s, feeds)
          end

          # Up/Down: the bus or send row above or below (a send's pending
          # line goes out first).
          def key_pick(state, d)
            out = flush_send(state)
            list = pickable(state)
            return [*out, 'no buses'] if list.empty?
            i = list.index { |r| row_key(r) == state[:pick] }
            i = i ? (i + d).clamp(0, list.length - 1) : (d > 0 ? 0 : list.length - 1)
            r = list[i]
            state[:pick] = row_key(r)
            note = r[0] == :bus ? "#{r[1].name} (m mutes it; its sends below: Left Right, 0, Enter)" : "#{r[1]} > #{r[5]} (Left Right its level, 0 closes it, Enter types it, m mutes #{r[5]})"
            [*out, note]
          end

          # The arrows' scrolling (Pane's) picks here.
          def key_scroll(state, *) = key_pick(state, 1)

          # Left/Right: the picked send by +d+ dB, on from the level the last
          # key set (CarriedValues: a held key steps every repeat), shown at
          # once; its ONE `feed` line runs when the keys stop (#key_tick,
          # GAP seconds after the last key) or another key comes.  Not live
          # while held: a send isn't a Session knob gesture yet, so the
          # change is heard when the line lands.
          def key_send(state, d)
            r = picked_row(state) or return 'pick a send first (Up Down)'
            why = not_a_send(r) and return why
            player, gain, bus = r[1], r[3], r[5]
            key = [player, bus]
            due = state[:send_due]
            out = due && (due[0] != player || due[1] != bus) ? flush_send(state) : nil
            now = carried(state, key) || level_db(gain)
            if now.finite?
              db = (now + d).round(1)
            else
              return "#{player} > #{bus} is off (Right opens it at #{OFF_START.round} dB)" if d < 0
              db = OFF_START
            end
            db = [db, MAX_DB].min
            return [*out, "#{player} > #{bus} at #{Panes.fmt(db)} dB (the most a send goes)"] if db == now && d > 0
            carry(state, key, db)
            state[:send_due] = [player, bus, db, self.class.clock.call + GAP]
            [*out, "#{player} > #{bus} at #{Panes.fmt(db)} dB (one feed line when you let go)"]
          end

          # 0: closes the picked send (`feed :pad, :verb, 0`).
          def key_close_send(state)
            r = picked_row(state) or return 'pick a send first (Up Down)'
            why = not_a_send(r) and return why
            state[:send_due] = nil
            carry(state, [r[1], r[5]], -Float::INFINITY)
            PaneKeys::Turn["feed #{r[1].inspect}, #{r[5].inspect}, 0", "#{r[1]} > #{r[5]} closed (u or undo opens it again)"]
          end

          # Enter: type the picked send's level (a prompt line starting with
          # it, selected so typing replaces it); #key_typed_send runs it.
          def key_ask_send(state)
            r = picked_row(state) or return 'pick a send first (Up Down)'
            why = not_a_send(r) and return why
            out = flush_send(state)
            db = carried(state, [r[1], r[5]]) || level_db(r[3])
            [*out, PaneKeys::Ask["feed #{r[1].inspect}, #{r[5].inspect}, ", db.finite? ? "#{RubyValue.to_ruby(db.round(2))}.db" : '0', :typed_send, select: true]]
          end

          # The typed answer to #key_ask_send: one `feed` line with it
          # (-9.db, 0.5, 0, a knob name to follow).
          def key_typed_send(state, text)
            r = picked_row(state) or return 'pick a send first (Up Down)'
            why = not_a_send(r) and return why
            text = text.to_s.strip
            return 'nothing typed' if text.empty?
            problem = KnobTurns.typed_problem(text) and return "#{r[1]} > #{r[5]}: #{problem}"
            PaneKeys::Turn["feed #{r[1].inspect}, #{r[5].inspect}, #{text}", "#{r[1]} > #{r[5]} #{text}"]
          end

          # m: mutes the picked bus (a send row's bus), or unmutes it.
          def key_mute_bus(state)
            r = picked_row(state) or return 'pick a bus first (Up Down)'
            out = flush_send(state)
            bus = r[0] == :bus ? r[1].name : r[5]
            info = state[:snap].buses.find { |b| b.name == bus }
            run = info&.muted ? PaneKeys::Run["unmute #{bus.inspect}", "#{bus} unmuted"] : PaneKeys::Run["mute #{bus.inspect}", "#{bus} muted"]
            [*out, run]
          end

          # e: a send row's `feed` line at its level, a bus row's `mute`
          # (PaneKeys#key_edit_line).
          def edit_line(state)
            r = picked_row(state) or return 'pick a bus or a send first (Up Down)'
            return key_mute_bus(state).last if r[0] == :bus
            why = not_a_send(r) and return why
            db = carried(state, [r[1], r[5]]) || level_db(r[3])
            PaneKeys::Turn["feed #{r[1].inspect}, #{r[5].inspect}, #{db.finite? ? "#{RubyValue.to_ruby(db.round(2))}.db" : '0'}"]
          end

          # The pending send line, once the keys stopped (GAP), else nil.
          def key_tick(state)
            due = state[:send_due] or return nil
            return nil if self.class.clock.call < due[3]
            flush_send(state)[0]
          end

          # Seconds until #key_tick has a line, or nil.
          def key_wait(state)
            due = state[:send_due] or return nil
            w = due[3] - self.class.clock.call
            w < 0 ? 0.0 : w
          end

          # dB for a send level (a linear gain), or nil (a follow).
          def level_db(level)
            return nil unless level.is_a?(Numeric)
            level > 0 ? 20 * Math.log10(level) : -Float::INFINITY
          end

          # What feeds each bus: { bus => [[player, how, gain], ...] }, +how+
          # :to, :send, :pre_send (pre-fader), or :pre_mute_send (pre-mute),
          # +gain+ a linear send level, a follow's name, or nil for to:.
          def feeds_of(s)
            feeds = Hash.new { |h, k| h[k] = [] }
            s.routes.each do |player, r|
              feeds[r[:to]] << [player, :to, nil] if r[:to] && r[:to] != :master
              MB::Sound::Session::Buses::SEND_KEYWORDS.each do |kw|
                (r[kw] || {}).each { |bus, level| feeds[bus] << [player, kw, level] }
              end
            end
            feeds
          end

          private

          def bus_row(c, y, b, load, name_w)
            glyph, role = b.muted || b.asleep ? [c.glyph(:off), :dim] : [c.glyph(:on), :ok]
            x = c.line(y, [glyph, role], ' ', [c.pad(b.name, name_w), :name], [" #{c.glyph(:arrow)} ", :dim], [b.to.to_s, :key])
            state = b.muted ? ' muted' : b.asleep ? ' asleep' : ''
            pct = load ? "  #{Panes.load_text(load.load)[0]}" : ''
            c.text_fit(x, y, "#{state}#{pct}  #{b.description}", c.w - x, :dim)
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

          # A source: "← kick  to:", "← bass  -12.0 dB", or (pre-fader,
          # pre-mute) "← lead -12.0 pre", "← lead -12.0 prm" with the sent
          # signal's meter.
          def feed_row(c, y, player, how, gain, send, name_w, db: nil)
            x = c.line(y, [' ', nil], ["#{c.glyph(:sep) == '|' ? '<' : '←'} ", :dim], [c.pad(player, name_w - 2), :text], ' ')
            label = if how == :to
                      'to:'
                    else
                      db ||= send ? send.gain : level_db(gain)
                      unit = FEED_UNITS[how]
                      db ? "#{Panes.db(db)} #{unit}" : "follows #{gain}#{how == :send ? '' : " #{unit}"}"
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

          # The rows in the mode: scrolled to the picked bus or send, its
          # name reversed, a send's carried level (a key just set it) over
          # the snapshot's.
          def draw_mode(c, state, rows, name_w)
            state[:rows] = rows
            pick = rows.index { |r| r[0] != :levels && row_key(r) == state[:pick] }
            top = state[:top].to_i
            top = pick if pick && pick < top
            top = pick - c.h + 1 if pick && c.h > 0 && pick >= top + c.h
            state[:top] = top = top.clamp(0, [rows.length - c.h, 0].max)
            rows[top, c.h].each_with_index do |row, y|
              sel = top + y == pick
              case row[0]
              when :bus
                bus_row(c, y, row[1], row[2], name_w)
                c.run(2, y, c.pad(row[1].name, name_w), :key, reverse: true) if sel
              when :levels then levels_row(c, y, row[2], name_w)
              else
                db = carried(state, [row[1], row[5]])
                feed_row(c, y, row[1], row[2], row[3], row[4], name_w, db: db)
                c.run(3, y, c.pad(row[1], name_w - 2), :key, reverse: true) if sel
              end
            end
          end

          # The rows the keys pick (buses and what feeds them), from the
          # last frame drawn in the mode.
          def pickable(state)
            (state[:rows] || []).reject { |r| r[0] == :levels }
          end

          # What identifies a row across frames: [:bus, name] or [:feed,
          # player, bus].
          def row_key(r) = r[0] == :bus ? [:bus, r[1].name] : [:feed, r[1], r[5]]

          # The picked row, or nil.
          def picked_row(state)
            k = state[:pick] or return nil
            pickable(state).find { |r| row_key(r) == k }
          end

          # Why row +r+ has no send level to change, or nil.
          def not_a_send(r)
            return "#{r[1].name}: a bus has no fader (its sends set what reaches it: pick one below; m mutes the bus)" if r[0] == :bus
            return "#{r[1]} goes to #{r[5]} whole (to:): no send level" if r[2] == :to
            return "#{r[1]} > #{r[5]} follows #{r[3]} (feed #{r[1].inspect}, #{r[5].inspect}, -12.db sets a level)" unless r[3].is_a?(Numeric)
            nil
          end

          # The pending send line now, as an Array (empty without one).
          def flush_send(state)
            due = state[:send_due] or return []
            state[:send_due] = nil
            player, bus, db = due
            carry(state, [player, bus], db) # (until the poll has the landed level)
            [PaneKeys::Turn["feed #{player.inspect}, #{bus.inspect}, #{RubyValue.to_ruby(db)}.db", "#{player} > #{bus} at #{Panes.fmt(db)} dB"]]
          end

          # The routing tree from the master (UI::TreeText): buses by where
          # they go, players by their main out, sends as "name (send)".
          def draw_tree(c, s, feeds)
            kids = Hash.new { |h, k| h[k] = [] }
            key = ->(to) { to.nil? || to == :master ? [:node, :master] : [:bus, to] }
            s.buses.each { |b| kids[key.(b.to)] << [:bus, b.name] }
            players = (s.routes.keys + s.players.map(&:name)).uniq
            players.each { |p| kids[key.(s.routes.dig(p, :to))] << [:player, p] }
            feeds.each { |bus, list| list.each { |player, how, _| kids[[:bus, bus]] << [how, player] unless how == :to } }
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
                            when :pre_send then ["#{name} (pre-fader send)", :dim]
                            when :pre_mute_send then ["#{name} (pre-mute send)", :dim]
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
        #
        # In its mode (NAV Enter; ui-phase1-1) the queue pane's keys
        # (QueuedKeys): Up/Down pick a queued change, shown reversed on the
        # top row, x cancels it.
        class Lane < Pane
          include QueuedKeys

          # Bars the lane shows.
          BARS = 4

          # Seconds a landed change flashes.
          FLASH = 0.8

          def initialize = super(:lane, rate: 15, height: 4, width: 40, title: 'launch lane', min_height: 2,
                                        description: 'queued changes moving toward the playhead, with a beat countdown to the next; cancel one from its keys')

          def draw_body(c, s, state)
            return unless s
            state[:snap] = s
            len = s.bar_length.to_r
            now = MB::U.clock_now
            flash = s.landed.reverse.find { |e| e.at && now - e.at < FLASH }
            q = s.queued.select { |e| e.pos }.sort_by(&:pos)
            nxt = q.find { |e| e.pos >= s.pos }
            picked = state[:mode] && !s.queued.empty? ? (sq = sorted_queued(state))[picked_index(state, sq)] : nil
            if picked
              c.run(0, 0, c.fit(" #{picked.kind} #{picked.subject.inspect} lands #{picked.lands}  x cancels ", c.w), :name, reverse: true)
            elsif flash
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
            labels.first(c.h - 2 - shown.length).each_with_index { |(x, t), i| c.text_fit([x - 1, 0].max, 2 + i, t, c.w - [x - 1, 0].max, :dim) }
            shown.each_with_index { |k, i| Lane.clock_row(c, c.h - shown.length + i, k) }
          end

          # One clock row: name, a phase bar, what it is, and its count.
          def self.clock_row(c, y, k)
            x = c.line(y, ['⏱ ', :dim], [k.name.to_s, :name], ' ')
            bar = [[c.w / 5, 4].max, 10].min
            x = c.meter(k.phase, width: bar, x: x, y: y, role: :key)
            c.text_fit(x + 1, y, "#{k.unit == :cycles ? 'cycle' : 'bar'} #{k.count} · #{k.what}", [c.w - x - 1, 0].max, :dim)
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
              c.text_fit(x + 1, y, src.to_s, [c.w - x - 1, 0].max, :dim)
              y += 1
            end
          end
        end
      end
    end
  end
end

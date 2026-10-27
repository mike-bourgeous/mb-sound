module MB
  module Sound
    module UI
      # The sound-design screen's panes (sound-design-ui-1; `ui :sound`,
      # design/notes/sound_design_ui.md): the patch inspector (a track's
      # knobs to turn and its nodes' params), the selected node's preview,
      # the graph's code, and, until the library index lands
      # (library-core-1), placeholders for the picker and the audition
      # line.  Every pane draws from Slow#inspector (Inspect, gathered by
      # Poll while a pane needs :inspect) and the snapshot's knobs; keys
      # change the set only through console lines (PaneKeys::Run).
      module Panes
        # The patch inspector: the knobs a track's graph reads, as knob
        # rows to turn (name, a meter on the knob's curve, value with unit,
        # range and curve), then the nodes the graph is made of and the
        # selected node's params (read-only; knob-driven ones name their
        # knob).  Follows the clip matrix's track (else the first playing
        # one) until t (or n, a node) picks one.
        #
        # Mode keys (NAV Enter, or NAV d): Up/Down pick a knob,
        # Left/Right turn it (Shift or H/L fine; a held key is a live sweep
        # and one `turn` line when it stops), Enter types a value (`turn
        # :cut, 3000.hz`), 0 its default, m learns a MIDI controller for it
        # (`learn :cut`), t/T the next/previous track, n/N (] [) the
        # next/previous node.
        class Inspector < Pane
          include KnobTurns
          jump 'd'

          mode_keys do
            group 'Inspector'
            on [:up, 'k'], :pick, -1, help: 'previous knob', label: 'Up Down'
            on [:down, 'j'], :pick, 1, help: 'next knob', label: 'Up Down'
            on [:right, 'l'], :turn, KnobTurns::STEP, help: 'turn the knob up (held: a live sweep, one turn line)', label: 'Left Right'
            on [:left, 'h'], :turn, -KnobTurns::STEP, help: 'turn the knob down (held: a live sweep, one turn line)', label: 'Left Right'
            on [:right, :shift], :turn, KnobTurns::FINE, help: 'turn up, fine'
            on [:left, :shift], :turn, -KnobTurns::FINE, help: 'turn down, fine'
            on ['L'], :turn, KnobTurns::FINE, help: 'turn up, fine'
            on ['H'], :turn, -KnobTurns::FINE, help: 'turn down, fine'
            on :enter, :ask, help: 'type a value for the knob (turn :cut, 3000.hz)', label: 'Enter'
            on '0', :reset, help: "the knob's default"
            on 'm', :learn, help: 'learn a MIDI controller for the knob (learn :cut: turn one)'
            on ['t'], :track, 1, help: 'the next track', label: 't T'
            on ['T'], :track, -1, help: 'the previous track', label: 't T'
            on ['n', ']'], :node, 1, help: 'the next node (preview and params)', label: 'n N'
            on ['N', '['], :node, -1, help: 'the previous node', label: 'n N'
          end

          keys do
            group 'Inspector'
            doc 'Enter', 'turn the track\'s knobs, pick nodes (Esc back to NAV)'
          end

          def priority = :live

          def initialize = super(:inspector, rate: 15, height: 14, width: 52, needs: [:inspect], title: 'inspector', min_height: 4,
                                             description: 'a track\'s knobs to turn (ranges, units, curves) and the params of the nodes it is made of')

          # What Enter does now, for the status line (the design's rule:
          # name Enter's action before it is pressed).
          def enter_hint(state)
            cell = picked(state)
            cell ? "type #{cell[0]}'s value" : nil
          end

          def draw_body(c, s, state)
            state[:snap] = s
            info = s&.inspector
            if info.nil? || info.track.nil?
              c.puts ['nothing to inspect ', :dim], ['(play a track: bg :bass, clip)', :dim]
              return
            end
            knobs = s.knobs.to_h { |k| [k.name, k] }
            list = info.knobs
            pick = list.empty? ? nil : (state[:pick] = state[:pick].to_i.clamp(0, list.length - 1))

            idx = info.tracks.index(info.track)
            x = c.line(0, [info.track.to_s, :name], ["  #{idx ? idx + 1 : '?'}/#{info.tracks.length}", :dim])
            c.text(x, 0, c.fit(state[:mode] ? '  t: next track' : '', [c.w - x, 0].max), :dim)
            y = 1
            if info.error
              c.text(0, y, c.fit(info.error, c.w), :warn)
              y += 1
            end

            if list.empty?
              c.text(0, y, c.fit('no knobs: knob :cut, 800.hz then knob(:cut) in the patch', c.w), :dim)
              y += 1
            end
            list.each_with_index do |kn, i|
              break if y >= c.h - 1 && i > 0
              k = knobs[kn]
              value, turning = shown_value(state, kn, k)
              spec = k&.spec
              sel = state[:mode] && i == pick
              x = c.run(0, y, " #{c.fit(kn.to_s, 9).ljust(9)}", sel ? :key : :name, reverse: sel)
              unless spec
                c.text(x + 1, y, '(not in the session yet)', :dim)
                y += 1
                next
              end
              vtext = "#{Panes.fmt(value)}#{spec.unit ? " #{spec.unit}" : ''}"
              range = " #{Panes.fmt(spec.range.begin)}..#{Panes.fmt(spec.range.end)}#{spec.curve == :exp ? ' exp' : ''}"
              range = '' if c.w < 40
              mw = (c.w - x - vtext.length - range.length - 3).clamp(3, 32)
              x = c.meter(spec.position(value.to_f).to_f, width: mw, x: x + 1, y: y, role: :key)
              x = c.text(x + 1, y, vtext, turning ? :queued : :text)
              c.text(x, y, c.fit(range, [c.w - x, 0].max), :dim)
              y += 1
            end
            if pick && state[:mode] && y < c.h && (desc = knobs[list[pick]]&.spec&.param&.description)
              c.text(1, y, c.fit(desc, c.w - 1), :dim)
              y += 1
            end

            draw_node(c, info, y + (y < c.h - 2 ? 1 : 0)) if y < c.h - 1
          end

          # The selected node (title row: label, copies, which of how many)
          # and its params below.
          def draw_node(c, info, y)
            n = info.selected
            unless n
              c.text(0, y, 'no nodes with params', :dim)
              return
            end
            # The nodes as a row of chips (the selected one reversed), then
            # the selected node's class and params
            x = c.text(0, y, 'nodes ', :dim)
            info.nodes.each_with_index do |m, i|
              chip = "#{m.label}#{m.count > 1 ? "×#{m.count}" : ''}"
              if x + chip.length + 1 > c.w
                y += 1
                x = 6
                break if y >= c.h - 1
              end
              x = c.run(x, y, chip, i == info.node ? :key : m.knobs.empty? ? :text : :name, reverse: i == info.node)
              x += 1
            end
            y += 1
            return if y >= c.h
            x = c.line(y, [n.label, :key], ["  #{n.kind}#{n.count > 1 ? " ×#{n.count}" : ''}", :dim], ["  #{info.node + 1}/#{info.nodes.length}", :dim])
            c.text(x, y, c.fit('  n N: other nodes', [c.w - x, 0].max), :dim)
            y += 1
            n.params.values.each do |name, v|
              break if y >= c.h
              x = c.text(1, y, c.pad(name.to_s, 10), :name)
              text, role =
                if v.label.is_a?(Symbol) then ["#{c.glyph(:arrow)} knob #{v.label} #{Panes.fmt(v.value)}#{v.unit ? " #{v.unit}" : ''}", :key]
                elsif !v.value.nil? then ["#{Panes.fmt(v.value)}#{v.unit ? " #{v.unit}" : ''}", :text]
                else ["#{c.glyph(:arrow)} #{v.label || v.detail}", :dim]
                end
              c.text(x + 1, y, c.fit(text, [c.w - x - 1, 0].max), role)
              y += 1
            end
            c.text(1, y, '(no params of its own)', :dim) if n.params.values.empty? && y < c.h
          end

          def key_pick(state, d)
            out = flush(state)
            state[:pick] = state[:pick].to_i + d
            out
          end

          def key_ask(state)
            cell = picked(state) or return no_knob_note
            kn, k = cell
            value, = shown_value(state, kn, k)
            [*flush(state), PaneKeys::Ask["turn #{kn.inspect}, ", TurnGesture.number(value), :typed]]
          end

          # The typed answer to #key_ask: one `turn` line with it (Ruby:
          # 3000, 3000.hz, -6.db).
          def key_typed(state, text)
            cell = picked(state) or return no_knob_note
            text = text.to_s.strip
            return 'nothing typed' if text.empty?
            PaneKeys::Run["turn #{cell[0].inspect}, #{text}", "#{cell[0]} #{text}"]
          end

          def key_learn(state)
            cell = picked(state) or return no_knob_note
            [*flush(state), PaneKeys::Run["learn #{cell[0].inspect}", "learn #{cell[0]}: turn a controller"]]
          end

          def key_track(state, d)
            info = state[:snap]&.inspector or return 'nothing to inspect'
            return 'no tracks playing' if info.tracks.empty?
            i = info.tracks.index(info.track) || 0
            t = info.tracks[(i + d) % info.tracks.length]
            state[:pick] = 0
            Inspect.target = { track: t, node: nil }.freeze
            [*flush(state), "inspecting #{t}"]
          end

          def key_node(state, d)
            info = state[:snap]&.inspector or return 'nothing to inspect'
            return 'no nodes' if info.nodes.empty?
            i = ((info.node || 0) + d) % info.nodes.length
            Inspect.target = { track: info.track, node: i }.freeze
            n = info.nodes[i]
            "node #{n.label} (#{n.kind}) #{i + 1}/#{info.nodes.length}"
          end

          private

          def no_knob_note = 'no knob to turn: the graph reads none (knob :cut, 800.hz; then knob(:cut) in the patch)'

          def picked(state)
            s = state[:snap] or return nil
            info = s.inspector or return nil
            return nil if info.knobs.empty?
            kn = info.knobs[state[:pick].to_i.clamp(0, info.knobs.length - 1)]
            k = s.knobs.find { |kv| kv.name == kn } or return nil
            [kn, k]
          end
        end

        # The selected node's preview (Plot::Panels: a filter's response, a
        # shaper's curve, an envelope's note), drawn through Plot::Live like
        # the scope; follows turned knobs (the node's snapshot is taken
        # again every poll).  An envelope's playhead (NodeInfo#live, read
        # 4 times a second) moves on between polls by the clock while its
        # segment runs (Clock: a lambda for specs).
        class Preview < Pane
          class << self
            # The clock the playhead moves by (monotonic seconds; specs set
            # a lambda).
            attr_writer :clock

            def now = @clock ? @clock.call : Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def initialize = super(:preview, rate: 8, height: 10, width: 48, needs: [:inspect], title: 'preview', min_height: 3,
                                           description: 'the inspected node\'s preview: a filter\'s response, a shaper\'s transfer curve, an envelope\'s note with a playhead')

          def plot?
            true
          end

          def draw(c, s, state, look: nil)
            w = c.w
            h = c.h
            return if w <= 0 || h <= 0
            n = s&.inspector&.selected
            chart = n&.preview ? chart_for(n, state) : nil
            unless chart
              c.clear
              c.text(0, 0, c.fit(n ? "#{n.label}: no preview (filters, shapers, and envelopes have one)" : 'no node selected (the inspector: n)', w), :dim)
              return
            end
            native = c.grid.is_a?(FastUI::Grid)
            lk = look && look != :auto ? look : Scope.auto_look(w, h)
            live = state[:live]
            if live.nil? || live.width != w || live.height != h || state[:native] != native || state[:look] != lk
              live = state[:live] = Plot::Live.new(width: w, height: h, look: lk, native: native)
              state[:native] = native
              state[:look] = lk
            end
            live.draw(chart, c.grid, x: c.x, y: c.y)
          end

          private

          # The node's chart, rebuilt only when its params (or a playhead)
          # change.
          def chart_for(n, state)
            live = live_now(n.live)
            key = [n.params, live]
            return state[:chart] if state[:chart_of] == key
            b = Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
            chart = Plot::Panels.preview(n.params.node_class, n.params, b, live: live) ? b.build : nil
            state[:chart_of] = key
            state[:chart] = chart
          rescue StandardError => e
            state[:chart_of] = key
            state[:chart] = nil
            warn "preview of #{n.label}: #{e.class}: #{e.message}"
            nil
          end

          # +live+ (NodeInfo#live) with +:elapsed+, the seconds since it was
          # read while its segment runs (rounded to a tenth of a frame at
          # 8 per second, so a held sustain doesn't rebuild the chart).
          def live_now(live)
            return live unless live && live[:at] && live[:stage] == :segment
            live.merge(elapsed: ((Preview.now - live[:at]) * 80).floor / 80.0)
          end
        end

        # A preview of the inspected track's voice (sound-design-ui-2: "a
        # one-shot render of the processed waveform updated periodically
        # when parameters change"): a second copy of one voice
        # (UI::PatchRender) plays one note (the clip's first, else a guess
        # from the track's role) from a reset state, drawn as one settled
        # cycle from a rising zero crossing (a few cycles when detuned
        # unison copies never repeat) above the settled sound's spectrum,
        # with the note's envelope (half a second, min/max) below them in a
        # tall pane; the render before it faintly behind; LUFS, peak, and
        # RMS on the first row.  It renders again 0.1 s after the knobs the
        # voice reads stop moving, at most every 0.2 s while they move; the
        # live graph is never touched.
        #
        # Mode keys (NAV Enter, or NAV w): s the views (all that fit, the
        # cycle, the envelope, the spectrum), o the faint previous render on
        # or off, p the role's guessed note instead of the clip's first, +
        # and - the envelope's length, r render again.
        class Render < Pane
          jump 'w'

          mode_keys do
            group 'Render'
            on 's', :view, help: 'the views: all that fit, the cycle, the envelope, the spectrum'
            on 'o', :overlay, help: 'the previous render (faint) on or off'
            on 'p', :phrase, help: "the role's guessed note or the clip's first note"
            on ['+', '='], :length, 1, help: 'a longer envelope view', label: '+ -'
            on '-', :length, -1, help: 'a shorter envelope view', label: '+ -'
            on 'r', :again, help: 'render again'
          end

          # The color of the previous render behind the current one.
          PREVIOUS = '#5c6370'

          # Render lengths + and - step through (seconds).
          LENGTHS = [0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 16.0, 20.0].freeze

          # Views s cycles through.
          VIEWS = %i[all cycle envelope spectrum].freeze

          # The fewest rows of each plot when both are stacked, and the
          # fewest columns of each side by side.
          STACK_ROWS = 5
          SIDE_COLS = 45

          def initialize = super(:render, rate: 10, height: 12, width: 48, needs: [:inspect, :render], title: 'render', min_height: 3,
                                          description: 'a preview of one note through a copy of the inspected voice: a settled cycle, its spectrum, the envelope, peak, RMS, LUFS, redone when its knobs change')

          def plot?
            true
          end

          # The pane's PatchRender::Driver in +state+ (made on first use).
          def self.driver(state) = (state[:driver] ||= PatchRender::Driver.new)

          def draw(c, s, state, look: nil)
            c.clear
            return if c.w <= 0 || c.h <= 0
            if @title && !state[:title_in_rule]
              c.text(0, 0, 'RENDER', :title)
              c = c.sub(0, 1, c.w, c.h - 1)
              return if c.h <= 0
            end
            src = s&.render_source
            unless src
              c.text(0, 0, c.fit('nothing to render (play a track: bg :bass, clip)', c.w), :dim)
              return
            end
            unless src.synth
              c.text(0, 0, c.fit(src.note || 'no voice to copy', c.w), :dim)
              return
            end
            driver = Render.driver(state)
            driver.guess = !!state[:guess]
            driver.tick(src, s.knobs, s.inspector&.knobs || [].freeze)
            r = driver.shown
            r = nil if r && r.track != src.track
            draw_header(c, r, driver)
            return if c.h < 2
            if r.nil? || r.error
              c.text(0, 1, c.fit(r ? r.error : 'rendering...', c.w), r ? :warn : :dim)
              return
            end
            prev = state[:overlay] == false ? nil : driver.previous
            areas(c.sub(0, 1, c.w, c.h - 1), state[:view] || :all).each do |view, body|
              chart = chart_for(r, prev, view, state)
              plot(body, chart, state, view, look) if chart
            end
          end

          # [[view, canvas], ...]: the plots that fit +body+ for +view+ (:all:
          # the cycle above the spectrum above the envelope, as many as fit
          # STACK_ROWS rows each; side by side in a wide, short pane).
          def areas(body, view)
            return [[view, body]] unless view == :all
            rows = body.h / STACK_ROWS
            if rows >= 2
              list = rows >= 3 ? %i[cycle spectrum envelope] : %i[cycle spectrum]
              h = body.h / list.length
              list.each_with_index.map { |v, i| [v, body.sub(0, i * h, body.w, i == list.length - 1 ? body.h - i * h : h)] }
            elsif body.w >= 2 * SIDE_COLS
              left = body.w / 2
              [[:cycle, body.sub(0, 0, left, body.h)], [:spectrum, body.sub(left, 0, body.w - left, body.h)]]
            else
              [[:cycle, body]]
            end
          end

          # Draws +chart+ into +body+ through a Plot::Live kept per view.
          def plot(body, chart, state, view, look)
            native = body.grid.is_a?(FastUI::Grid)
            lk = look && look != :auto ? look : Scope.auto_look(body.w, body.h)
            lives = (state[:lives] ||= {})
            live, was = lives[view]
            if live.nil? || live.width != body.w || live.height != body.h || was != [native, lk]
              live = Plot::Live.new(width: body.w, height: body.h, look: lk, native: native)
              lives[view] = [live, [native, lk]]
            end
            live.draw(chart, body.grid, x: body.x, y: body.y)
          end

          # The first row: the track and its figures, what it played (and
          # whether its period settled), the copy's rate, the render's time,
          # and a mark while a newer render waits or runs.
          def draw_header(c, r, driver)
            x = c.text(0, 0, r&.track.to_s, :name)
            if r && !r.error
              x = c.line(0, ['  ', :dim], [Panes.db(r.lufs), :text], [' LUFS', :dim], ['  peak ', :dim], [Panes.db(r.peak), :text],
                         ['  rms ', :dim], [Panes.db(r.rms), :text], x: x)
              how = r.settled ? "settled #{(r.settled * 1000).round} ms" : "#{r.periods} cycles"
              tail = "  #{r.input}, #{how}, #{Panes.fmt(r.rate / 1000.0)} kHz, #{r.ms.round} ms"
            else
              tail = r ? "  #{r.input}" : ''
            end
            x = c.text(x, 0, c.fit(tail, [c.w - x - 2, 0].max), :dim)
            c.text(x, 0, ' …', :queued) if driver.pending? && x + 2 <= c.w
          end

          def key_view(state)
            i = VIEWS.index(state[:view] || :all) || 0
            state[:view] = VIEWS[(i + 1) % VIEWS.length]
            { all: 'render: the cycle, the spectrum, and the envelope (where they fit)', cycle: 'render: the settled cycle',
              envelope: 'render: the envelope', spectrum: 'render: the spectrum' }[state[:view]]
          end

          def key_overlay(state)
            state[:overlay] = state[:overlay] == false
            state[:overlay] ? 'render: the previous render behind' : 'render: no previous render'
          end

          def key_phrase(state)
            state[:guess] = !state[:guess]
            state[:guess] ? "render: the role's guessed note" : "render: the clip's first note (a guess without a clip)"
          end

          def key_length(_state, d)
            now = PatchRender.seconds
            i = LENGTHS.index { |l| l >= now - 1e-9 } || LENGTHS.length - 1
            i += 1 if d > 0 && LENGTHS[i] <= now + 1e-9
            i -= 1 if d < 0
            PatchRender.seconds = LENGTHS[i.clamp(0, LENGTHS.length - 1)]
            "render: the envelope #{Panes.fmt(PatchRender.seconds)} s (PatchRender.seconds)"
          end

          def key_again(state)
            Render.driver(state).again
            'render: again'
          end

          # What Enter does in the pane (the status line).
          def enter_hint(_state) = nil

          private

          # The chart for Result +r+ (and +prev+ faintly behind, if any) in
          # +view+ (:cycle, :envelope, or :spectrum), rebuilt only when they
          # change.
          def chart_for(r, prev, view, state)
            charts = (state[:charts] ||= {})
            key = [r.seq, prev&.seq]
            hit = charts[view]
            return hit[1] if hit && hit[0] == key
            b = Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
            case view
            when :spectrum
              return nil unless r.spectrum
              f, db = r.spectrum
              ps = prev&.spectrum
              top = [db.max, ps ? ps[1].max : -Float::INFINITY].max
              b.x :frequency, 20.0..[r.rate / 2.0, ps ? prev.rate / 2.0 : 0].max
              b.y Plot::Scale::DB.new(-90.0..[(top / 10.0).ceil * 10, -40].max.to_f)
              b.line(ps[1], x: ps[0], color: PREVIOUS) if ps
              b.line(db, x: f)
            when :cycle
              return nil unless r.cycle && r.cycle[0].length > 1
              ms = ->(res) { (0..(res.cycle[0].length - 1) * 1000.0 / res.rate) }
              peak = [*r.cycle.map { |d| d.abs.max }, *(prev&.cycle || []).map { |d| d.abs.max }].max.to_f
              peak = 1.0 if peak <= 0
              b.x :linear, label: 'ms'
              b.y Plot::Scale::Symmetric.new(-peak..peak, label: nil)
              prev&.cycle&.each { |d| b.line(d, x: ms.(prev), color: PREVIOUS) }
              r.cycle.each_with_index { |d, i| b.line(d, x: ms.(r), color: i) }
            else
              b.x :time, sample_rate: r.rate
              peak = [r.hi.max, -r.lo.min, prev ? [prev.hi.max, -prev.lo.min].max : 0].max.to_f
              peak = 1.0 if peak <= 0
              b.y Plot::Scale::Symmetric.new(-peak..peak, label: nil)
              # (two areas from 0 draw the min/max envelope: in C, where a
              # band mark's fill is Ruby, 1.3-3 ms a draw)
              if prev
                b.area(prev.hi, x: 0..(prev.frames * r.rate / prev.rate), base: 0.0, color: PREVIOUS)
                b.area(prev.lo, x: 0..(prev.frames * r.rate / prev.rate), base: 0.0, color: PREVIOUS)
              end
              b.area(r.hi, x: 0..r.frames, base: 0.0, color: 0)
              b.area(r.lo, x: 0..r.frames, base: 0.0, color: 0)
            end
            chart = b.build
            charts[view] = [key, chart]
            chart
          rescue StandardError => e
            charts[view] = [key, nil]
            warn "render pane: #{e.class}: #{e.message}"
            nil
          end
        end

        # The inspected graph's code: the knobs it reads at their values now
        # (`knob :cut, (150.hz..8000.hz).at(3100.hz)`), then its Ruby
        # (`to_ruby`), redrawn only when either changes.  Arrows scroll.
        class Code < Pane
          jump 'c'

          def initialize = super(:code, rate: 4, height: 12, width: 56, needs: [:inspect], title: 'code', min_height: 3,
                                        description: 'the inspected graph\'s Ruby (to_ruby) with the knobs it reads at their values now')

          mode_keys do
            group 'Code'
            on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
            on [:up, 'k'], :scroll, -1, help: 'scroll up', label: 'Up Down'
            on [:down, 'j'], :scroll, 1, help: 'scroll down', label: 'Up Down'
            on :page_up, :scroll, -10, help: 'a page up', label: 'PgUp PgDn'
            on :page_down, :scroll, 10, help: 'a page down', label: 'PgUp PgDn'
          end

          # The code's lines for +info+ with the snapshot's +knobs+ (cached
          # in +state+ while neither changes).
          def self.lines(info, knobs, state = {})
            read = info.knobs.filter_map { |kn| knobs.find { |k| k.name == kn } }
            key = [info.code, read.map(&:value)]
            return state[:lines] if state[:lines_of] == key
            out = read.map { |k| Code.knob_line(k) }
            out << '' unless out.empty?
            out << "# #{info.track}: the graph it plays (to_ruby)"
            out.concat((info.code || '# (no recipe: this graph was not built by the DSL)').lines.map(&:chomp))
            state[:lines_of] = key
            state[:lines] = out.freeze
          end

          # `knob :cut, (150.hz..8000.hz).at(3100.hz)` for KnobValue +k+ at
          # its value now.
          def self.knob_line(k)
            "knob #{k.spec.call_args(value: k.value).join(', ')}"
          rescue StandardError
            "knob #{k.name.inspect}, #{TurnGesture.number(k.value)}"
          end

          def draw_body(c, s, state)
            info = s&.inspector
            unless info&.track
              c.puts ['no graph (the inspector follows a playing track)', :dim]
              return
            end
            lines = Code.wrapped(Code.lines(info, s.knobs, state), c.w, state)
            top = state[:top] = state[:top].to_i.clamp(0, [lines.length - c.h, 0].max)
            lines[top, c.h].each_with_index do |(l, role), y|
              c.text(0, y, c.fit(l, c.w), role)
            end
            c.text(c.w - 6, c.h - 1, ' more ', :dim) if top + c.h < lines.length && c.w > 12
          end

          # +lines+ wrapped to +width+ (a hanging indent of 4 past each
          # line's own), as [text, role] pairs (knob lines in the key color,
          # comments dim), cached in +state+ per lines and width.
          def self.wrapped(lines, width, state = {})
            key = [lines.object_id, width]
            return state[:wrapped] if state[:wrapped_of] == key
            out = lines.flat_map { |l|
              role = l.start_with?('knob ') ? :key : l.lstrip.start_with?('#') ? :dim : :text
              ind = l[/\A */].length
              next [[l, role]] if l.length <= width || width - ind < 12
              Canvas.wrap(l.lstrip, width - ind, indent: 4).map { |x| [' ' * ind + x, role] }
            }
            state[:wrapped_of] = key
            state[:wrapped] = out.freeze
          end

          def key_scroll(state, d = 1)
            state[:top] = state[:top].to_i + d
            nil
          end

          # The pane's text for `y` (Tiles#copy_pane copies what is drawn;
          # this is the whole code).
          def full_text(state) = (state[:lines] || []).join("\n")
        end

        # Where the library picker goes (library-core-1 builds the index;
        # this screen's design: find-as-you-type, Enter does the likely
        # action named on the status line, a shortcut per action, a side
        # panel with description, tags, facts, and crosslinks).  A
        # placeholder until the index lands: the inspector never needs it.
        class Picker < Pane
          def initialize = super(:picker, rate: 1, height: 10, width: 30, title: 'library', min_height: 2,
                                          description: 'the library picker (placeholder until the library index lands)')

          LINES = [
            ['the library picker goes here:', :dim],
            ['find-as-you-type, then', :dim],
            ['Enter: the likely action', :dim],
            ['(named on the status line),', :dim],
            ['a key per action, auditions', :dim],
            ['on CUE only.', :dim],
          ].freeze

          def draw_body(c, _s, _state)
            c.line(0, ['find ', :dim], ['▏', :key])
            LINES.each_with_index { |(t, r), i| c.text(0, i + 2, c.fit(t, c.w), r) if i + 2 < c.h }
          end
        end

        # One line about CUE (the phones): parts on CUE, the phones level
        # and CUE/MAIN blend knobs, and what an audition would play.
        class Audition < Pane
          def initialize = super(:audition, rate: 4, height: 1, width: 60, description: 'CUE (the phones): parts cued, the phones level and blend, the audition')

          def draw_body(c, s, _state)
            return c.text(0, 0, 'CUE  no session', :dim) unless s
            cued = s.players.select { |p| p.name.to_s.end_with?('/cue') }.map { |p| p.name.to_s.delete_suffix('/cue') }
            k = s.knobs.to_h { |kv| [kv.name, kv] }
            x = c.line(0, ['CUE ', :title], [cued.empty? ? c.glyph(:off) : c.glyph(:on), cued.empty? ? :dim : :ok], ' ')
            x = c.text(x, 0, cued.empty? ? 'nothing cued' : cued.join(' '), cued.empty? ? :dim : :name)
            if (ph = k[:phones])
              x = c.line(0, ['  phones ', :dim], [Panes.fmt(ph.value), :text], x: x)
            end
            if (mx = k[:cue_mix])
              x = c.line(0, ['  cue_mix ', :dim], [Panes.fmt(mx.value), :text], x: x)
            end
            c.line(0, ["  #{c.glyph(:sep)} audition: ", :dim], ['the picker\'s entry plays here (cue :x, sound)', :dim], x: x)
          end
        end

        # The sound-design screen's keys: the inspector's (from its keymap,
        # so they can't drift) and the ones the design plans (dim, marked
        # later).
        class SoundKeys < Pane
          def initialize = super(:sound_keys, rate: 1, height: 9, width: 40, title: 'keys', min_height: 2,
                                              description: 'the sound-design screen\'s keys: the inspector\'s and the planned ones')

          # Keys the design plans but this build doesn't have yet.
          PLANNED = [
            ['/', 'find in the library'], ['a', 'audition on CUE'], ['Enter', "the picker's likely action"],
            ['S', 'save (name, tags, params)'], ['b', 'A/B against the loaded preset'], ['*', 'favourite'],
          ].freeze

          # [built, planned]: [[keys, help], ...] each; the inspector's
          # bindings grouped by their label ("Up Down": "previous knob /
          # next knob"), fine turns left out (Shift is on the status line).
          def self.rows
            groups = {}
            Inspector.mode_keymap.help_groups.flat_map { |_, rows| rows }.each do |keys, help|
              next if help.include?('fine')
              label = keys.split.length > 2 ? keys.split.first(2).join(' ') : keys
              (groups[label] ||= []) << help.sub(/ \(.*\z/, '')
            end
            [groups.map { |label, helps| [label, helps.uniq.join(' / ')] }, PLANNED]
          end

          def draw_body(c, _s, _state)
            built, planned = SoundKeys.rows
            w = [[built.map { |l, _| l.length }.max.to_i, 10].min, 6].max
            y = 0
            built.each do |label, help|
              break if y >= c.h
              x = c.text(0, y, c.pad(label, w), :key)
              c.text(x + 1, y, c.fit(help, [c.w - x - 1, 0].max), :text)
              y += 1
            end
            planned.each do |label, help|
              break if y >= c.h
              x = c.text(0, y, c.pad(label, w), :dim)
              c.text(x + 1, y, c.fit("#{help} (later)", [c.w - x - 1, 0].max), :dim)
              y += 1
            end
          end
        end
      end
    end
  end
end

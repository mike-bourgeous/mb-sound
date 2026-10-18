module MB
  module Sound
    module UI
      module Panes
        # The clip matrix (ux-r4 item 12): a row per track, a column per
        # scene (the slot the scene gives the track: its clip, ■ stop, or ·
        # keep) and then the track's other slots (captures, launched and
        # tweaked clips).  Cells show what plays (▶), what is queued (◆ and
        # its countdown in beats), and the cursor while the pane's mode is
        # on (NAV Enter).  Keys launch the cell's clip or a scene, stop a
        # track, and tweak the track's clip, each a console line (`launch
        # :bass, 3`, `go :drop`, `stop :bass`, `tweak :bass, transpose: 2`)
        # run through UI.run_line: journaled, undoable, at the track's
        # launch point, printed in the REPL pane.  The clip under the cursor
        # is the clip detail pane's (`:clip`).
        #
        # Data: Snapshot#matrix (MatrixInfo from Poll) and #lane_state.
        class Clips < Pane
          jump 'a'

          # Width of the track-name column and of a cell, at most.
          NAME_W = 10
          CELL_W = 12
          CELL_MIN = 6

          # The edits by key: [key, label, tweak arguments as Ruby].  One
          # table for the keymap, the help, and the lines run.
          EDITS = [
            ['+', 'transpose up a semitone', 'transpose: 1'],
            ['-', 'transpose down a semitone', 'transpose: -1'],
            ['>', 'up an octave', 'transpose: 12'],
            ['<', 'down an octave', 'transpose: -12'],
            ['L', 'legato (notes to the next)', 'legato: 1.0'],
            ['S', 'swing 0.6', 'swing: 0.6'],
            ['Q', 'quantize to 1/16', 'quantize: 1/16r'],
            ['D', 'double: repeat to twice the length', ':double'],
            ['H', 'half: the first half', ':half'],
            ['*', 'halftime (twice as long)', ':halftime'],
            ['/', 'doubletime (half as long)', ':doubletime'],
            ['R', 'reverse', ':reverse'],
          ].freeze

          mode_keys do
            group 'Clip matrix'
            on [:up, 'k'], :move, 0, -1, help: 'cursor up', label: 'arrows hjkl'
            on [:down, 'j'], :move, 0, 1, help: 'cursor down', label: 'arrows hjkl'
            on [:left, 'h'], :move, -1, 0, help: 'cursor left', label: 'arrows hjkl'
            on [:right, 'l'], :move, 1, 0, help: 'cursor right', label: 'arrows hjkl'
            on [:home], :move_to, :first, help: 'first column'
            on [:end], :move_to, :last, help: 'last column'
            on :enter, :launch, help: 'launch the cell: its clip on the track (■: stop the track)'
            on 'g', :scene, help: "launch the cursor column's scene (go)"
            on ['x', '.'], :stop, help: 'stop the track (rings out)'
            group 'Tweak the track\'s clip (a new slot, at its launch point)'
            EDITS.each { |key, help, _| on key, :tweak, key, help: help }
            group 'Clip matrix'
            on 'u', :undo, help: 'undo the last change (at the next bar)'
          end

          keys do
            group 'Clip matrix'
            doc 'Enter', 'cursor keys, launch, tweak (Esc back to NAV)'
          end

          # (UI::PaneRates: a list at its own rate, 10/s for the countdowns)
          def priority = :list

          def initialize = super(:clips, rate: 10, height: 8, width: 60, title: 'clips', min_height: 3,
                                         description: 'the clip matrix: tracks x scenes and slots, playing and queued with countdowns; launch and tweak from its keys')

          # The cell under the cursor as [LaneInfo, slot index, SceneInfo]
          # (+slot+ also :stop, :keep, or nil for an empty cell; +scene+ nil
          # past the scene columns), or nil.
          def self.cell(m, row, col)
            return nil unless m && !m.tracks.empty?
            t = m.tracks[row.clamp(0, m.tracks.length - 1)]
            if col < m.scenes.length
              sc = m.scenes[col]
              [t, sc.cells.fetch(t.name, :stop), sc]
            else
              [t, others(m, t)[col - m.scenes.length], nil]
            end
          end

          # The slot indexes of track +t+ that no scene names, in order.
          def self.others(m, t)
            named = m.scenes.filter_map { |sc| sc.cells[t.name] }.grep(Integer)
            (0...t.slots.length).reject { |i| named.include?(i) }
          end

          # Columns: the scenes, then the most other slots any track has.
          def self.columns(m) = m.scenes.length + (m.tracks.map { |t| others(m, t).length }.max || 0)

          # The clip the cursor is on (for the detail pane): [track name,
          # ClipInfo] or nil.  Kept per process: one screen at a time.
          class << self
            attr_accessor :selected
          end

          def draw_body(c, s, state)
            state[:snap] = s
            m = s&.matrix
            if m.nil? || m.tracks.empty?
              c.puts ['no tracks yet ', :dim], ['(track :bass { |c| ... }; scene :drop, bass: riff)', :dim]
              Clips.selected = nil
              return
            end
            cols = Clips.columns(m)
            row, col = clamp_cursor(state, m, cols)
            select(m, row, col)
            name_w = [[m.tracks.map { |t| t.name.to_s.length }.max + 2, 6].max, NAME_W].min
            cell_w = [[(c.w - name_w) / [cols, 1].max, CELL_W].min, CELL_MIN].max
            vis_cols = [(c.w - name_w) / cell_w, 1].max
            left = state[:left].to_i
            left = col if col < left
            left = col - vis_cols + 1 if col >= left + vis_cols
            state[:left] = left = left.clamp(0, [cols - 1, 0].max)
            body_h = c.h - 1
            top = state[:top].to_i
            top = row if row < top
            top = row - body_h + 1 if body_h > 0 && row >= top + body_h
            state[:top] = top = [top, 0].max

            # Header: scene names (▶ current, ◆ queued), then "more"
            c.text(0, 0, c.fit(left > 0 ? '…' : '', name_w), :dim)
            (left...[left + vis_cols, cols].min).each do |j|
              x = name_w + (j - left) * cell_w
              if j < m.scenes.length
                sc = m.scenes[j]
                mark = sc.current ? c.glyph(:play) : sc.queued ? '◆' : ' '
                c.text(x, 0, c.fit("#{mark}#{sc.name}", cell_w - 1), sc.current ? :ok : sc.queued ? :queued : :title)
              elsif j == m.scenes.length
                c.text(x, 0, c.fit(' slots', cell_w - 1), :dim)
              end
            end

            m.tracks[top, [body_h, 0].max].to_a.each_with_index do |t, i|
              y = i + 1
              r = top + i
              lstate = s.lane_state(t.name)
              on = %i[playing starting].include?(lstate)
              x = c.text(0, y, on ? c.glyph(:play) : ' ', on ? :ok : :dim)
              c.text(x, y, c.fit("#{t.name}#{lstate == :muted ? ' m' : ''}", name_w - 2), lstate == :muted ? :dim : :name)
              (left...[left + vis_cols, cols].min).each do |j|
                draw_cell(c, s, m, t, j, name_w + (j - left) * cell_w, y, cell_w - 1, state[:mode] && r == row && j == col, lstate)
              end
            end
          end

          # One cell: [mark][clip name][countdown], reversed under the cursor.
          def draw_cell(c, s, m, t, j, x, y, w, cursor, lstate)
            _, slot, = Clips.cell(m, m.tracks.index(t), j)
            q = t.queued.last
            text, role =
              case slot
              when Integer
                clip = t.slots[slot]
                name = clip ? (clip.key || clip.name).to_s : "##{slot}"
                if q && q.kind == :launch && q.slot == slot
                  ["◆#{name}", :queued]
                elsif t.playing == slot && lstate != :stopped
                  ["#{c.glyph(:play)}#{name}", lstate == :ringing || lstate == :stopping ? :dim : :ok]
                else
                  [" #{name}", :text]
                end
              when :stop then ["#{q && q.kind == :stop ? '◆' : ' '}#{c.glyph(:stop)}", :dim]
              when :keep then [' ·', :dim]
              else ['', :dim]
              end
            if q && role == :queued && q.pos
              beats = ((q.pos - s.pos) * 4).to_f
              cd = beats > 0 ? format(' %.1f', beats) : ''
              text = c.fit(text, [w - cd.length, 1].max).ljust([w - cd.length, 1].max) + cd
            end
            c.run(x, y, c.fit(text, w).ljust(w), cursor ? :key : role, reverse: cursor)
          end

          # Keys (the pane's mode; see PaneKeys).

          def key_move(state, dx, dy)
            state[:cursor] = [state.dig(:cursor, 0).to_i + dy, state.dig(:cursor, 1).to_i + dx]
            m = state[:snap]&.matrix and clamp_cursor(state, m, Clips.columns(m))
            nil
          end

          def key_move_to(state, where)
            m = state[:snap]&.matrix or return nil
            r = state.dig(:cursor, 0).to_i
            state[:cursor] = [r, where == :first ? 0 : Clips.columns(m) - 1]
            nil
          end

          def key_launch(state)
            cell = cursor_cell(state) or return 'no clip here'
            t, slot, = cell
            case slot
            when Integer then PaneKeys::Run["launch #{t.name.inspect}, #{slot}", "launch #{label(t, slot)} on #{t.name.inspect}"]
            when :stop then PaneKeys::Run["stop #{t.name.inspect}", "stop #{t.name.inspect}"]
            else "#{t.name.inspect}: nothing in this cell (· keeps what plays)"
            end
          end

          def key_scene(state)
            cell = cursor_cell(state) or return 'no scene here'
            _, _, sc = cell
            return 'not a scene column (scenes are the first columns)' unless sc
            PaneKeys::Run["go #{sc.name.inspect}", "scene #{sc.name.inspect}"]
          end

          def key_stop(state)
            cell = cursor_cell(state) or return 'no track here'
            t = cell[0]
            PaneKeys::Run["stop #{t.name.inspect}", "stop #{t.name.inspect}"]
          end

          def key_tweak(state, key)
            cell = cursor_cell(state) or return 'no track here'
            t = cell[0]
            edit = EDITS.find { |k, _, _| k == key } or return "no tweak on #{key}"
            _, help, args = edit
            return "#{t.name.inspect} plays no clip to tweak" if t.playing.nil? && t.queued.none? { |q| q.kind == :launch }
            PaneKeys::Run["tweak #{t.name.inspect}, #{args}", "#{t.name.inspect}: #{help}"]
          end

          def key_undo(_state) = PaneKeys::Run['undo', 'undo']

          private

          def cursor_cell(state)
            m = state[:snap]&.matrix or return nil
            r, cl = state[:cursor] || [0, 0]
            Clips.cell(m, r, cl)
          end

          def label(t, slot)
            clip = t.slots[slot]
            clip ? (clip.key || clip.name).to_s : "slot #{slot}"
          end

          def clamp_cursor(state, m, cols)
            r, cl = state[:cursor] || [0, 0]
            r = r.clamp(0, m.tracks.length - 1)
            cl = cl.clamp(0, [cols - 1, 0].max)
            state[:cursor] = [r, cl]
          end

          # Publishes the cursor's clip for the detail pane.
          def select(m, row, col)
            t, slot, = Clips.cell(m, row, col)
            slot = t.playing if !slot.is_a?(Integer) && t
            Clips.selected = t && slot.is_a?(Integer) && t.slots[slot] ? [t.name, t.slots[slot]].freeze : nil
          end
        end

        # The clip detail pane (ux-r4 item 12): the clip under the matrix's
        # cursor (else the first playing one): its name, length, loop,
        # range, the Ruby that made it (its recipe: transforms applied), and
        # a piano roll of its notes (kit rows by name) with velocity shades
        # and marks (! accent, ~ slide, f flam).
        class ClipDetail < Pane
          MARKS = { accent: '!', slide: '~', flam: 'f' }.freeze

          def priority = :list

          def initialize = super(:clip, rate: 4, height: 10, width: 50, title: 'clip', min_height: 3,
                                        description: 'the clip under the matrix cursor: length, loop, its Ruby, and a piano roll of its notes')

          def draw_body(c, s, _state)
            track, clip = Clips.selected || first_playing(s)
            unless clip
              c.puts ['no clip selected ', :dim], ['(the clips pane: NAV a, Enter, arrows)', :dim]
              return
            end
            len = clip.length || (clip.bars.to_r * (s&.bar_length || 1r))
            range = clip.range ? "  #{note_name(clip.range.begin)}..#{note_name(clip.range.end)}" : ''
            c.line(0, [(clip.key || clip.name).to_s, :name], ['  ', nil], [Panes.fmt(clip.bars.to_f), :key], [clip.bars == 1 ? ' bar' : ' bars', :dim],
                   [clip.loop ? '  loop' : '  once', :dim], [range, :dim], [track ? "  on #{track}" : '', :dim],
                   ["  #{clip.events.length} notes", :dim])
            y = 1
            if clip.ruby && c.h > 4
              c.text(0, y, c.fit(clip.ruby.lines.first.to_s.strip, c.w), :key)
              y += 1
            end
            roll(c.sub(0, y, c.w, c.h - y), clip, len.to_r)
          end

          private

          def first_playing(s)
            t = s&.matrix&.tracks&.find { |l| l.playing && l.slots[l.playing] }
            t && [t.name, t.slots[t.playing]]
          end

          def note_name(n) = n ? "#{Poll::NOTE_NAMES[n % 12]}#{n / 12 - 1}" : '?'

          # Rows: kit rows by name, else pitches from high to low (only
          # those played when they don't all fit); columns: time.
          def roll(c, clip, len)
            return if c.h < 1 || c.w < 8 || clip.events.empty? || len <= 0
            kit = clip.events.any? { |e| e.note.nil? }
            keys = kit ? clip.events.map(&:row).uniq : clip.events.map(&:note).uniq.sort.reverse
            if !kit && clip.range && (clip.range.end - clip.range.begin + 1) <= c.h
              keys = clip.range.end.downto(clip.range.begin).to_a
            end
            label_w = kit ? [[keys.map { |k| k.to_s.length }.max, 3].max, 8].min : 4
            span = c.w - label_w - 1
            return if span < 4
            shown = keys.first(c.h)
            shown.each_with_index do |k, y|
              c.text(0, y, c.fit(kit ? k.to_s : note_name(k), label_w), k.is_a?(Integer) && k % 12 == 0 ? :key : :dim)
              c.text(label_w + 1, y, '·' * span, :dim)
            end
            clip.events.each do |e|
              y = shown.index(kit ? e.row : e.note) or next
              x0 = (e.start.to_r / len * span).floor.clamp(0, span - 1)
              x1 = ((e.start.to_r + e.length.to_r) / len * span).ceil.clamp(x0 + 1, span)
              mark = e.marks.filter_map { |mk| MARKS[mk] }.first
              role = e.marks.include?(:accent) || e.velocity.to_f >= 0.86 ? :warn : e.velocity.to_f < 0.4 ? :dim : :armed
              x = c.run(label_w + 1 + x0, y, mark || '█', role, reverse: !mark.nil?)
              c.text(x, y, '█' * (x1 - x0 - 1), role) if x1 - x0 > 1
            end
            c.text(0, c.h - 1, "+#{keys.length - shown.length} rows", :dim) if keys.length > shown.length && c.h > 1
          end
        end

        # Racks (ux-r4 item 12): a block per rack instance: its path (or
        # name), kind, signature, typed ports in and out, latency, and its
        # macros as knob rows with ranges.  In the pane's mode (NAV Enter)
        # Up/Down pick a macro and Left/Right turn it (Shift: fine), each
        # turn a `turn :"bass/dub/space", 0.42` console line.
        #
        # Data: Snapshot#racks (Rack::RackInfo per instance), macro values
        # from Snapshot#knobs.
        class Racks < Pane
          jump 'r'

          # Position steps of a turn: coarse and fine (Shift).
          STEP = 0.02
          FINE = 0.002

          # Seconds a turned value is used over the snapshot's (keys faster
          # than the snapshot's knob values catch up).
          PENDING = 0.6

          mode_keys do
            group 'Racks'
            on [:up, 'k'], :pick, -1, help: 'previous macro', label: 'Up Down j k'
            on [:down, 'j'], :pick, 1, help: 'next macro', label: 'Up Down j k'
            on [:right, 'l'], :turn, STEP, help: 'turn the macro up', label: 'Right l'
            on [:left, 'h'], :turn, -STEP, help: 'turn the macro down', label: 'Left h'
            on [:right, :shift], :turn, FINE, help: 'turn up, fine'
            on [:left, :shift], :turn, -FINE, help: 'turn down, fine'
            on ['L'], :turn, FINE, help: 'turn up, fine'
            on ['H'], :turn, -FINE, help: 'turn down, fine'
            on '0', :reset, help: "the macro's default"
          end

          keys do
            group 'Racks'
            doc 'Enter', 'pick and turn macros (Esc back to NAV)'
          end

          def priority = :list

          def initialize = super(:racks, rate: 10, height: 10, width: 44, title: 'racks', min_height: 3,
                                         description: 'rack instances: kind, typed ports, latency, macros as knobs to turn')

          # The turnable macros of +racks+ in pane order: [[knob name,
          # macro, RackInfo], ...] (only instances playing have knobs).
          def self.macros(racks, knobs)
            names = knobs.to_h { |k| [k.name, k] }
            racks.flat_map { |r|
              r.macros.filter_map { |kn| names[kn] && [kn, kn.to_s.split('/').last.to_sym, r] }
            }
          end

          def draw_body(c, s, state)
            state[:snap] = s
            racks = s&.racks || []
            if racks.empty?
              c.puts ['no racks ', :dim], ['(arack :dub do |sig| ... end; sig.then(&rack(:dub)))', :dim]
              return
            end
            knobs = s.knobs.to_h { |k| [k.name, k] }
            list = Racks.macros(racks, s.knobs)
            pick = list.empty? ? nil : (state[:pick] = state[:pick].to_i.clamp(0, list.length - 1))
            picked = pick && list[pick][0]
            y = 0
            racks.each do |r|
              break if y >= c.h
              # Title: path kind  latency
              lat = r.latency.nil? ? '' : r.latency.to_i > 0 ? "  lat #{r.latency} smp" : '  lat 0'
              x = c.line(y, [(r.path || r.name || 'rack').to_s, :name], ['  ', nil], [r.kind.to_s, :key])
              c.text(x, y, c.fit(lat, [c.w - x, 0].max), :dim)
              y += 1
              break if y >= c.h
              ins = r.ports.map { |p| "#{p[:name]}:#{p[:type]}#{p[:role] == :main ? '' : p[:required] ? '' : '?'}" }
              out = r.signature.to_s.split('->').last.to_s.strip
              c.line(y, ['  in ', :dim], [ins.join(' '), :text], ['  out ', :dim], [out, :text])
              y += 1
              r.macros.each do |kn|
                break if y >= c.h
                k = knobs[kn]
                macro = kn.to_s.split('/').last
                spec = k&.spec || r.macro_specs[macro.to_sym]
                value = pending(state, kn) || k&.value || spec&.default
                sel = state[:mode] && kn == picked
                x = c.run(0, y, "  #{c.fit(macro, 8).ljust(8)}", sel ? :key : :name, reverse: sel)
                range = spec ? " #{Panes.fmt(spec.range.begin)}..#{Panes.fmt(spec.range.end)}#{spec.curve == :exp ? ' exp' : ''}" : ''
                vtext = "#{Panes.fmt(value)}#{spec&.unit ? " #{spec.unit}" : ''}"
                mw = [c.w - x - vtext.length - range.length - 2, 3].max
                x = c.meter(spec ? spec.position(value).to_f : 0.0, width: mw, x: x + 1, y: y, role: k ? :key : :dim)
                x = c.text(x + 1, y, vtext, :text)
                c.text(x, y, c.fit(range, [c.w - x, 0].max), :dim)
                y += 1
              end
            end
          end

          def key_pick(state, d)
            state[:pick] = state[:pick].to_i + d
            nil
          end

          def key_turn(state, step)
            cell = picked(state) or return 'no macro to turn (racks playing with macros have knobs)'
            kn, k = cell
            v = pending(state, kn) || k.value
            nv = k.spec.clamp(k.spec.value((k.spec.position(v) + step).clamp(0.0, 1.0)))
            set(state, kn, nv)
          end

          def key_reset(state)
            cell = picked(state) or return 'no macro'
            kn, k = cell
            set(state, kn, k.spec.default)
          end

          private

          def set(state, kn, value)
            (state[:pending] ||= {})[kn] = [value, MB::U.clock_now]
            PaneKeys::Run["turn #{kn.inspect}, #{Racks.number(value)}", "#{kn} #{Racks.number(value)}"]
          end

          # A value to 4 significant figures, as Ruby.
          def self.number(v)
            v = v.to_f
            v == v.round ? v.round.to_s : MB::M.sigfigs(v, 4).to_s
          end

          def picked(state)
            s = state[:snap] or return nil
            list = Racks.macros(s.racks || [], s.knobs)
            return nil if list.empty?
            kn = list[state[:pick].to_i.clamp(0, list.length - 1)][0]
            [kn, s.knobs.find { |k| k.name == kn }]
          end

          def pending(state, kn)
            v, at = state[:pending]&.[](kn)
            v if at && MB::U.clock_now - at < PENDING
          end
        end
      end
    end
  end
end

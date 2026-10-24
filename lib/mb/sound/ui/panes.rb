module MB
  module Sound
    module UI
      # The built-in panes (see UI.panes; `pane :name do ... end` adds
      # more).
      module Panes
        # Meters show -60..0 dBFS.
        METER_FLOOR = -60.0

        # Meter zones: green to -18 dBFS, yellow to -6, then red.
        DB_ZONES = [[42.0 / 60, :low], [54.0 / 60, :mid], [1.0, :high]].freeze

        module_function

        # A number for a pane: whole numbers without a decimal point, others
        # to 3 significant figures.
        def fmt(v)
          return '-' if v.nil?
          v = v.to_f
          return '-inf' if v == -Float::INFINITY
          v.abs >= 100 || v == v.round ? v.round.to_s : format('%.3g', v)
        end

        # A dB value to one decimal ("-8.1", "-inf").
        def db(v)
          return '-' if v.nil?
          v.finite? ? format('%.1f', v) : '-inf'
        end

        # 0..1 for a dBFS level on the meter scale.
        def db_frac(v)
          return 0.0 if v.nil? || !v.finite?
          ((v - METER_FLOOR) / -METER_FLOOR).clamp(0.0, 1.0)
        end

        # A load fraction as a percentage and its role.
        def load_text(load)
          return ['-', :dim] if load.nil?
          pct = (load * 100).round
          [format('%d%%', pct), load < 0.5 ? :ok : load < 0.8 ? :warn : :bad]
        end

        # Transport: play state, bar:beat, tempo, meter, render load, and
        # output underruns.
        class Transport < Pane
          def initialize = super(:transport, rate: 30, height: 1, width: 44, description: 'play state, bar:beat, tempo, meter, render load, underruns')

          def draw_body(c, s, state)
            unless s
              c.puts ['no session yet ', :dim], ['(bg something to start one)', :dim]
              return
            end

            hist = (state[:loads] ||= [])
            if s.load && state[:seq] != s.seq
              hist << s.load
              hist.shift while hist.length > 16
              state[:seq] = s.seq
            end

            load, role = Panes.load_text(s.load)
            segs = [
              [s.playing ? c.glyph(:play) : c.glyph(:stop), s.playing ? :ok : :dim], ' ',
              [s.stamp.ljust(6), :key], ' ',
              [Panes.fmt(s.bpm), :name], [' bpm ', :dim], [s.meter, :name],
              ['  load ', :dim], [load.rjust(4), role], ' ',
            ]
            x = c.line(0, *segs)
            x = c.sparkline(hist, lo: 0.0, hi: 1.0, width: 8, x: x, y: 0, role: role)
            if s.underruns
              c.line(0, ['  xruns ', :dim], [s.underruns.to_s, s.underruns > (state[:xruns_at_start] ||= s.underruns) ? :bad : :ok], x: x)
            end
          end
        end

        # Form: the section playing, how far through it, and what comes
        # next; the current scene without a form.
        class Form < Pane
          def initialize = super(:form, rate: 8, height: 1, width: 44, description: 'the form\'s section, how far through, and what comes next (or the scene)')

          def draw_body(c, s, state)
            return unless s

            f = s.form
            if f.nil? || f.ended
              text = f&.ended ? 'form ended' : 'no form'
              x = c.line(0, [text, :dim])
              c.line(0, ['  scene ', :dim], [s.scene.to_s, :key], x: x) if s.scene
              return
            end

            len = s.bar_length.to_r
            bars = ((f.to - f.from) / len).to_f
            bar = ((s.pos - f.from) / len).floor + 1
            bar = bar.clamp(1, [bars.ceil, 1].max)
            x = c.line(0, [f.section.to_s, :key], [" #{f.pass}#{f.looping ? ' ∞' : ''} ", :dim])
            x = c.meter(bars > 0 ? (bar - 1 + (s.beat.to_f - 1) / (len * 4).to_f) / bars : 0.0, width: 8, x: x, y: 0, role: :key)
            x = c.line(0, [" #{bar}/#{Panes.fmt(bars)}", :dim], x: x)
            c.line(0, ["  #{c.glyph(:arrow)} ", :dim], [f.next ? f.next.to_s : '?', f.committed ? :name : :dim], [" #{f.next_at}", :dim], x: x)
          end
        end

        # Tracks and other players: state, clip, armed and recording.
        class Tracks < Pane
          def initialize = super(:tracks, rate: 8, height: 6, width: 30, title: 'tracks', min_height: 2, description: 'tracks and players: state, clip, armed, recording')

          STATE_ROLES = {
            playing: :ok, starting: :queued, stopping: :warn, fading: :warn, ringing: :warn,
            muted: :dim, asleep: :dim, stopped: :dim,
          }.freeze

          def draw_body(c, s, state)
            return unless s

            parts = s.players.to_h { |p| [p.name, p] }
            rec = s.recording.to_h { |r| [r.name, r] }
            rows = s.tracks.map { |t| [t.name, t.clip, parts[t.name]&.state || :stopped, t.armed, t.trigger] }
            names = s.tracks.map(&:name)
            parts.each_value do |p|
              next if names.include?(p.name) || Arrangement::Recording.monitored_track(p.name)
              rows << [p.name, 'bg', p.state, false]
            end
            if rows.empty?
              c.puts ['nothing playing', :dim]
              return
            end

            name_w = [[rows.map { |r| r[0].to_s.length }.max, 6].max, 12].min
            show = rows.length > c.h ? rows.first(c.h - 1) : rows
            show.each_with_index do |(name, clip, st, armed, trigger), y|
              r = rec[name]
              glyph, role =
                if r then [c.glyph(:rec), :rec]
                elsif armed then [c.glyph(:armed), :armed]
                elsif st == :stopped then [c.glyph(:off), :dim]
                else [c.glyph(:on), STATE_ROLES.fetch(st, :text)]
                end
              x = c.line(y, [glyph, role], ' ', [c.pad(name, name_w), :name], ' ')
              what = r ? "rec #{c.glyph(:arrow)}#{r.ends}#{r.queued ? ' (queued)' : ''}" : st == :playing ? clip.to_s : "#{st} #{clip}"
              what = "trigger #{what}" if trigger # (a trigger track: heard only by sidechains)
              c.text(x, y, c.fit(what, c.w - x), r ? :rec : st == :playing ? :text : :dim)
            end
            c.text(0, c.h - 1, "+#{rows.length - show.length} more", :dim) if show.length < rows.length
          end
        end

        # Queued changes, soonest first, with where each lands.
        class Queue < Pane
          def initialize = super(:queue, rate: 4, height: 6, width: 26, title: 'queued', description: 'queued changes, soonest first, with where each lands')

          def draw_body(c, s, state)
            return unless s

            q = s.queued.sort_by { |e| [e.pos || Float::INFINITY, e.seq] }
            if q.empty?
              c.puts ['nothing queued', :dim]
              return
            end
            q.first(c.h).each_with_index do |e, y|
              x = c.line(y, [e.lands.ljust(6), :queued], ' ', [e.kind.to_s, :dim], ' ')
              c.text(x, y, c.fit(e.subject.inspect, c.w - x), :name)
            end
          end
        end

        # Knobs: a meter at each knob's position in its range, and its value.
        class Knobs < Pane
          def initialize = super(:knobs, rate: 15, height: 6, width: 28, title: 'knobs', description: 'session knobs: a meter of each one\'s position and its value')

          def draw_body(c, s, state)
            return unless s

            if s.knobs.empty?
              c.puts ['no knobs', :dim]
              return
            end
            name_w = [[s.knobs.map { |k| k.name.to_s.length }.max, 4].max, 8].min
            s.knobs.first(c.h).each_with_index do |k, y|
              spec = k.spec
              value = "#{Panes.fmt(k.value)}#{spec.unit ? " #{spec.unit}" : ''}"
              x = c.line(y, [c.pad(k.name, name_w), :name], ' ')
              mw = [c.w - x - value.length - 1, 3].max
              x = c.meter(spec.position(k.value).to_f, width: mw, x: x, y: y, role: :key)
              c.text(x + 1, y, value, :text)
            end
          end
        end

        # Master meters: peak per channel (with a 1.5 s hold), RMS,
        # short-term loudness, and true peak.
        class Meters < Pane
          # Seconds a peak is held.
          HOLD = 1.5

          def initialize = super(:meters, rate: 30, height: 6, width: 30, needs: [:meters], title: 'master', min_height: 4, description: 'master meters: peak with hold, RMS, short-term LUFS, true peak')

          def draw_body(c, s, state)
            m = s&.master
            if m.nil?
              c.puts ['no audio yet', :dim]
              return
            end

            holds = (state[:holds] ||= [])
            labels = m.peak.length == 2 ? %w[L R] : m.peak.each_index.map { |i| (i + 1).to_s }
            rows = [c.h - 2, m.peak.length].min
            rows.times do |ch|
              peak = m.peak[ch]
              h = holds[ch]
              holds[ch] = h = [peak, s.time] if h.nil? || peak >= h[0] || s.time - h[1] > HOLD
              x = c.line(ch, [labels[ch], :dim], ' ')
              mw = [c.w - x - 6, 3].max
              x = c.meter(Panes.db_frac(peak), width: mw, x: x, y: ch, zones: DB_ZONES, hold: Panes.db_frac(h[0]))
              c.text(x + 1, ch, Panes.db(h[0]).rjust(5), h[0] > -1.0 ? :bad : :text)
            end
            y = rows
            c.line(y, ['S ', :dim], [Panes.db(m.lufs_s), :key], [' LUFS  ', :dim], ['TP ', :dim], [Panes.db(m.true_peak), m.true_peak > -1.0 ? :bad : :text])
            c.line(y + 1, ['RMS ', :dim], m.rms.map { |r| Panes.db(r) }.join(' '))
          end
        end

        # Warnings and live errors while the UI is up (UI.messages), newest
        # at the bottom, each wrapped to the pane's width with a hanging
        # indent beside its gutter (its number for `ui.message n`, and its
        # repeat count), errors in the bad color (ux-1 r3 item 38: long
        # warnings kept their important tail off screen).  Entries that
        # don't fit go off the top.
        class Messages < Pane
          ROLES = { error: :bad, warn: :warn, note: :dim }.freeze

          mode_keys do
            group 'Messages'
            on [:up, 'k'], :scroll, 1, help: 'older, newer messages', label: 'Up Down'
            on [:down, 'j'], :scroll, -1, help: 'older, newer messages', label: ''
            on [:end, 'G'], :scroll, :newest, help: 'back to the newest', label: 'End'
            on 'y', :copy_text, help: 'copy the pane\'s text (OSC 52)'
          end

          # Scrolls back +by+ messages (positive: older), or to the newest.
          def key_scroll(state, by)
            n = UI.messages.recent(10_000).length
            state[:scroll] = by == :newest ? 0 : (state[:scroll].to_i + by).clamp(0, [n - 1, 0].max)
            state[:scroll] == 0 ? 'newest messages' : "#{state[:scroll]} newer message#{state[:scroll] == 1 ? '' : 's'} above... below (End: newest)"
          end

          def initialize = super(:messages, rate: 4, height: 6, width: 40, title: 'messages', min_height: 2, description: 'warnings and live errors while a screen is up, wrapped, numbered (ui.message n)')

          def draw_body(c, _s, state)
            skip = state ? state[:scroll].to_i : 0
            list = UI.messages.recent(c.h + skip).drop(skip)
            if list.empty?
              c.puts [skip > 0 ? 'no older warnings (Down: newer)' : 'no warnings', :dim]
              return
            end
            gutters = list.each_with_index.map { |e, i| "#{i + skip + 1}#{e.count > 1 ? " ×#{e.count}" : ''} " }
            gw = [gutters.map(&:length).max, c.w / 3].min
            # Newest first until the pane is full, then drawn oldest first
            blocks = []
            used = 0
            list.each_with_index do |e, i|
              lines = Canvas.wrap(e.text, c.w - gw)
              lines = lines.last(c.h - used) if used + lines.length > c.h && blocks.empty? # (the newest alone overflows: its tail)
              break if used + lines.length > c.h
              blocks << [gutters[i], lines, ROLES.fetch(e.severity, :warn)]
              used += lines.length
            end
            # From the top down, newest at the bottom (maintainer, 2026-10-18:
            # "would prefer starting from the top"); once full it scrolls
            y = 0
            blocks.reverse_each do |gutter, lines, role|
              c.text(0, y, gutter.rjust(gw)[0, gw], :dim)
              lines.each_with_index { |l, k| c.text(gw, y + k, l, role) }
              y += lines.length
            end
          end
        end

        # One message in full (`ui.message n`: the newest is 1): wrapped to
        # the pane, with its count and age, the rest cut with an ellipsis
        # and a note of the lines left.
        class MessageDetail < Pane
          # Which message (1: the newest).
          attr_accessor :index

          def initialize
            super(:message, rate: 2, height: 10, width: 60, title: 'message detail', min_height: 3, description: 'one message in full (ui.message n opens it)')
            @index = 1
          end

          def draw_body(c, _s, _state)
            e = UI.messages.recent(@index)[@index - 1]
            unless e
              c.puts ["no message #{@index}", :dim]
              return
            end
            age = Process.clock_gettime(Process::CLOCK_MONOTONIC) - e.last
            c.puts ["##{@index} ", :key], [e.severity.to_s, MESSAGE_ROLES.fetch(e.severity, :warn)],
                   [e.count > 1 ? "  ×#{e.count}" : '', :dim], ["  #{age.round}s ago", :dim]
            c.wrap(e.text, y: 1, role: :text)
          end

          MESSAGE_ROLES = Messages::ROLES
        end

        # A page of text to read while the tiled screen is up (help pages:
        # Help.show opens them here through UI::Tiles#page; ux-fix-1):
        # scrolled with its own keys, q closes it.
        class Page < Pane
          mode_keys do
            group 'Page'
            on [:up, 'k'], :scroll, -1, help: 'scroll up, down a line', label: 'Up Down j k'
            on [:down, 'j'], :scroll, 1, help: 'scroll up, down a line', label: 'Up Down j k'
            on [:page_up, 'b'], :scroll, :page_up, help: 'scroll a page up, down', label: 'PgUp PgDn b Space'
            on [:page_down, ' '], :scroll, :page_down, help: 'scroll a page up, down', label: 'PgUp PgDn b Space'
            on [:home, 'g'], :scroll, :top, help: 'top, bottom', label: 'Home End g G'
            on [:end, 'G'], :scroll, :bottom, help: 'top, bottom', label: 'Home End g G'
            on 'q', :close, help: 'close the page (back to the console)'
          end

          keys do
            group 'Page'
            doc 'Enter', 'scroll the page (q closes it, Esc back to NAV)'
          end

          # The text's lines, and the first line shown.
          attr_reader :lines, :offset

          def initialize
            super(:page, rate: 4, height: 20, width: 80, title: 'page', min_height: 3, description: 'a help page to scroll while the tiled screen is up (help opens it; q closes it)')
            @lines = [].freeze
            @offset = 0
            @rows = 1
            @label = nil
          end

          # Shows +text+ from its top; +title+ is the status line's label.
          def show(text, title: nil)
            @lines = text.to_s.lines.map(&:chomp).freeze
            @offset = 0
            @label = title
            self
          end

          def draw_body(c, _s, state)
            @rows = [c.h - 1, 1].max
            @offset = @offset.clamp(0, [@lines.length - @rows, 0].max)
            @lines[@offset, @rows].to_a.each_with_index do |l, y|
              c.text(0, y, c.fit(l, c.w), :text)
            end
            last = [@offset + @rows, @lines.length].min
            status = "#{@label ? "#{@label}  " : ''}lines #{@offset + 1}-#{last} of #{@lines.length}  " \
                     "#{state[:mode] ? 'j k PgUp PgDn g G, q closes' : 'Enter scrolls, q closes'}"
            c.text(0, c.h - 1, c.fit(status, c.w), :dim)
          end

          def key_scroll(_state, by)
            page = [@rows - 1, 1].max
            @offset = case by
                      when :page_up then @offset - page
                      when :page_down then @offset + page
                      when :top then 0
                      when :bottom then @lines.length
                      else @offset + by
                      end
            @offset = @offset.clamp(0, [@lines.length - @rows, 0].max)
            nil
          end

          def key_close(_state) = :close
        end

        # CPU per part: render load, then each player, bus, and master
        # chain by its share of the audio time.
        class CPU < Pane
          def initialize = super(:cpu, rate: 4, height: 6, width: 24, title: 'cpu', description: 'CPU per part: render load, each player, bus, and master chain')

          def draw_body(c, s, state)
            return unless s

            load, role = Panes.load_text(s.load)
            max, max_role = Panes.load_text(s.load_max)
            c.puts ['all ', :dim], [load.rjust(4), role], [' max ', :dim], [max, max_role]
            parts = s.parts.sort_by { |p| -p.load }
            name_w = [[parts.map { |p| p.name.to_s.length }.max.to_i, 4].max, 8].min
            parts.first(c.h - 1).each do |p|
              pct, prole = Panes.load_text(p.load)
              x = c.line(c.row, [c.pad(p.name, name_w), p.kind == :player ? :name : :title], ' ')
              mw = [c.w - x - 5, 2].max
              x = c.meter(p.load * 4, width: mw, x: x, y: c.row, role: prole) # full at 25%
              c.text(x + 1, c.row, pct.rjust(4), prole)
              c.row += 1
            end
          end
        end

        # A scope of the master mix through Plot::Live (look :auto by
        # default: Braille for short or wide panes, see .auto_look;
        # `ui look: :quad`, a layout's `pane :scope, look: :blocks`, or
        # `ui.look` on the focused pane to change it).  Draws its cells into
        # the screen's grid like every pane (never its own terminal bytes,
        # which would paint over overlays: ui-fix-3).
        class Scope < Pane
          # The looks `ui.look` cycles through, Braille first.
          LOOK_CYCLE = %i[scope quad blocks mosaic spark ascii].freeze

          # Rows up to which :auto picks Braille whatever the width.
          AUTO_BRAILLE_ROWS = 16

          # The look :auto means for a +w+ x +h+ pane: :scope (Braille, the
          # finest trace) for short or wide panes, :quad for tall narrow ones
          # (ux-1 r3 item 4; measured 2026-10-17: the same painter CPU as
          # :quad within noise, about 2x the bytes per scope frame, 1.9 kB
          # per written frame of :tiles at 120x40, ~56 kB/s at 30 frames/s,
          # far under a terminal's throughput).
          def self.auto_look(w, h)
            h <= AUTO_BRAILLE_ROWS || w >= 3 * h ? :scope : :quad
          end

          def initialize(name = :scope, look: nil)
            super(name, rate: 30, height: 6, width: 40, needs: [:scope], title: name.to_s, min_height: 3,
                        description: name == :spectrum ? 'the master mix\'s spectrum, log frequency with note names (look: Braille by default)' : 'a scope of the master mix (look: Braille by default; ui.look cycles)')
            @look = look
          end

          def plot?
            true
          end

          # Draws the plot into +c+'s rectangle of the screen grid, in the
          # pane's own look, else +look+ (the layout's or the screen's; :auto
          # by size).
          def draw(c, s, state, look: nil)
            w = c.w
            h = c.h
            return if w <= 0 || h <= 0
            native = c.grid.is_a?(FastUI::Grid)
            live = state[:live]
            lk = @look || look || :auto
            lk = Scope.auto_look(w, h) if lk == :auto
            if live.nil? || live.width != w || live.height != h || state[:native] != native || state[:look] != lk
              live = state[:live] = Plot::Live.new(width: w, height: h, look: lk, native: native)
              state[:native] = native
              state[:look] = lk
            end
            data = s&.scope
            data = state[:silence] ||= [Numo::SFloat.zeros(256)] if data.nil? || data.empty?
            live.draw(chart(data, s&.sample_rate || 48000), c.grid, x: c.x, y: c.y)
          end

          private

          def chart(data, rate)
            Plot.chart(legend: false) { |c|
              c.x :time, sample_rate: rate
              c.y Plot::Scale::Linear.new(-1.0..1.0)
              data.each { |d| c.line d }
            }
          end
        end

        # The master mix's spectrum (log frequency with note names, -90..0
        # dBFS; a Hann-windowed FFT of the scope samples, channels mixed),
        # through Plot::Live like the scope.  `vis spectrum: true` shows it
        # while a UI is up.
        class Spectrum < Scope
          # dBFS at the bottom of the pane.
          FLOOR = -90.0

          def initialize(name = :spectrum, look: nil)
            super
            @rate = 15
          end

          private

          def chart(data, rate)
            mix = data.length == 1 ? data[0] : data.reduce { |a, b| a + b } * (1.0 / data.length)
            f, db = Plot::Presets.spectrum_db(mix, rate, FLOOR)
            Plot.chart(legend: false) { |c|
              c.x :frequency, 20.0..(rate / 2.0), notes: true
              c.y Plot::Scale::DB.new(FLOOR..0.0)
              c.line db, x: f
            }
          end
        end
      end
    end
  end
end

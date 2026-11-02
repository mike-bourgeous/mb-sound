module MB
  module Sound
    module UI
      # The player screen's panes (bin/play.rb; MB::Sound::Player): what
      # plays and where (:now), the playlist, the file's info, and a view
      # per kind: an audio file's overview with the play head (:overview),
      # a module's pattern rows with a VU per channel (:pattern), a MIDI
      # file's notes as a piano roll (:roll).  They draw from the Player
      # (its files' data, read before they play, and positions read
      # without a lock) and the Snapshot (latency, so the views follow what
      # is heard), never from the Session's locked readers.
      module PlayerPanes
        # The panes for +player+ by name (merged into UI.panes for its
        # screen).
        def self.for(player)
          [Now, Playlist, Info, Overview, Pattern, Roll].map { |k| k.new(player) }.to_h { |p| [p.name, p] }
        end

        # Seconds of +player+'s file heard at snapshot +s+ (its position
        # less what's queued ahead of the speakers).
        def self.heard(player, s)
          [player.position - (s&.latency || 0.0), 0.0].max
        end

        # A player pane: holds its Player.
        class Base < Pane
          def initialize(player, name, **opts)
            @player = player
            super(name, **opts)
          end
        end

        # One row: state, which file of how many, its name, the time, a
        # progress meter, and the volume.
        class Now < Base
          STATES = { loading: ['…', :queued], playing: [:play, :ok], paused: ['‖', :warn], ended: [:stop, :dim], failed: ['!', :bad], quit: [:stop, :dim] }.freeze

          def initialize(player) = super(player, :now, rate: 10, height: 1, width: 80, description: 'the player: state, file n of m, its name, time, progress, volume')

          def draw_body(c, s, _state)
            pl = @player
            it = pl.item
            g, role = STATES.fetch(pl.state, ['?', :dim])
            g = c.glyph(g) if g.is_a?(Symbol)
            pos = PlayerPanes.heard(pl, s)
            len = it.length
            time = "#{Player::Item.clock(pos)} / #{Player::Item.clock(len)}"
            vol = pl.volume_db
            vol_text = vol.finite? ? format('vol %+d dB', vol.round) : 'vol muted'
            count = pl.items.length > 1 ? "#{pl.index + 1}/#{pl.items.length} " : ''
            right = "  #{time}  "
            x = c.line(0, [g, role], ' ', [count, :dim])
            room = c.w - x - right.length - vol_text.length - 12
            x = c.text(x, 0, c.fit(it.title, [room, 8].max), :name)
            x = c.text(x, 0, right, :key)
            meter_w = c.w - x - vol_text.length - 2
            x = c.meter(len && len > 0 ? pos / len : 0.0, width: meter_w, x: x, y: 0, role: :key) if meter_w >= 4
            c.text(x + 2, 0, vol_text, vol.finite? && vol >= -0.05 ? :text : :warn)
          end
        end

        # The playlist: each file, the one playing marked, its length once
        # loaded.
        class Playlist < Base
          def initialize(player) = super(player, :playlist, rate: 4, height: 6, width: 34, title: 'playlist', min_height: 2, description: 'the files, the one playing marked')

          def draw_body(c, _s, _state)
            items = @player.items
            cur = @player.index
            first = (cur - c.h / 2).clamp(0, [items.length - c.h, 0].max)
            items[first, c.h].each_with_index do |it, y|
              i = first + y
              mark, role = if i == cur then [c.glyph(:play), :ok]
                           elsif it.error then ['!', :bad]
                           elsif i < cur then [' ', :dim]
                           else [' ', :text]
                           end
              len = it.length ? Player::Item.clock(it.length) : ''
              x = c.line(y, [mark, role], ' ')
              c.text(x, y, c.fit(it.title, c.w - x - len.length - 1), i == cur ? :name : i < cur ? :dim : :text)
              c.text(c.w - len.length, y, len, :dim) unless len.empty?
            end
          end
        end

        # The file's info (format, rate, channels, length, loudness; a
        # module's format, channels, patterns, samples; a MIDI file's notes).
        class Info < Base
          def initialize(player) = super(player, :info, rate: 2, height: 8, width: 34, title: 'file', min_height: 2, description: "the file's format, rate, channels, length, loudness")

          def draw_body(c, _s, state)
            it = @player.item
            rows = state[:rows] if state[:item].equal?(it) && state[:loaded] == it.loaded?
            unless rows
              rows = state[:rows] = it.info
              state[:item] = it
              state[:loaded] = it.loaded?
            end
            w = [rows.map { |k, _| k.length }.max.to_i, 8].min
            y = 0
            rows.each do |k, v|
              break if y >= c.h
              x = c.line(y, [c.pad(k, w), :dim], ' ')
              y += c.wrap(v.to_s, y: y, x: x, indent: x, role: :text, rows: c.h - y)
            end
          end
        end

        # An audio file's overview: its peaks across the pane, played part
        # bright, the play head, and the time at each end.
        class Overview < Base
          # Partial blocks for a column's top (1 to 8 eighths).
          BLOCKS = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'].freeze

          def initialize(player) = super(player, :overview, rate: 10, height: 6, width: 60, title: 'overview', min_height: 3, description: 'the whole file\'s peaks, the play head, the time')

          def draw_body(c, s, state)
            it = @player.item
            peaks = it.respond_to?(:overview) ? it.overview : nil
            unless peaks && it.length
              c.puts [it.loaded? ? 'no overview' : 'loading', :dim]
              return
            end
            rows = c.h - 1
            w = c.w
            cols = state[:cols] if state[:of].equal?(peaks) && state[:w] == w
            unless cols
              # (each column: the loudest of its bins, linear, scaled to the
              # file's own peak so quiet files show their shape too)
              top = [peaks.max.to_f, 0.05].max
              cols = Array.new(w) { |x|
                a = x * peaks.length / w
                b = [((x + 1) * peaks.length / w), a + 1].max
                (peaks[a...b].max.to_f / top).clamp(0.0, 1.0)
              }
              state[:cols] = cols
              state[:of] = peaks
              state[:w] = w
            end
            frac = (PlayerPanes.heard(@player, s) / it.length).clamp(0.0, 1.0)
            head = (frac * (w - 1)).round
            rows.times do |r|
              line = +''
              roles = []
              cols.each_with_index do |f, x|
                e = (f * rows * 8).round - (rows - 1 - r) * 8
                ch = e >= 8 ? '█' : e > 0 ? BLOCKS[e - 1] : ' '
                ch = '│' if x == head && ch == ' '
                line << ch
                roles << (x == head ? :warn : x < head ? :key : :dim)
              end
              # (runs of one role as one write)
              x = 0
              while x < w
                role = roles[x]
                y = x
                y += 1 while y < w && roles[y] == role
                c.text(x, r, line[x...y], role)
                x = y
              end
            end
            left = Player::Item.clock(PlayerPanes.heard(@player, s))
            right = Player::Item.clock(it.length)
            c.text(0, rows, left, :key)
            c.text(w - right.length, rows, right, :dim)
          end
        end

        # A module's pattern rows, tracker style, the row playing in the
        # middle and highlighted, with a VU per channel on top (each
        # channel's volume on that tick, from the import's recording: what
        # the trackers' VUs showed).
        class Pattern < Base
          NOTE_NAMES = %w[C- C# D- D# E- F- F# G- G# A- A# B-].freeze

          def initialize(player) = super(player, :pattern, rate: 30, height: 20, width: 80, title: 'pattern', min_height: 4, description: "a module's pattern rows, the row playing highlighted, a VU per channel")

          def draw_body(c, s, _state)
            it = @player.item
            unless it.respond_to?(:set) && it.set && s
              c.puts [it.loaded? ? 'no patterns' : 'loading', :dim]
              return
            end
            set = it.set
            song = set.song
            # (what is heard: the timeline less what's queued)
            pos = [s.pos - (s.latency || 0.0).rationalize(1/1000r) * Rational(s.bpm.rationalize(1/1000r), 240), 0r].max
            at = it.row_at(pos)
            unless at
              c.puts ['the end', :dim]
              return
            end
            visit, ri = at
            pattern = song.patterns[visit.pattern] if visit.pattern
            chans = channel_list(set)
            cw = cell_width(c.w - 4, chans.length)
            shown = [(c.w - 4) / (cw + 1), chans.length].min
            tick = (pos * Tracker::TICKS_PER_WHOLE).floor
            # VU row: a meter per channel
            x = 4
            c.text(0, 0, format('%02X', visit.order.to_i), :dim)
            chans.first(shown).each do |ch, log|
              v = log && (log.freq[tick] ? log.volume[tick].to_f : 0.0)
              c.meter(v.to_f, width: cw, x: x, y: 0, zones: [[0.7, :low], [0.9, :mid], [1.0, :high]])
              x += cw + 1
            end
            c.text(x, 0, "+#{chans.length - shown}", :dim) if shown < chans.length
            # Rows around the current one
            body = c.h - 1
            mid = body / 2
            rows = visit.rows
            body.times do |y|
              i = ri + y - mid
              next if i < 0 || i >= rows.length
              row = rows[i][0]
              current = i == ri
              role = current ? :key : (row % 4 == 0 ? :text : :dim)
              cells = pattern&.rows&.[](row) || []
              line = +format('%02d', row)
              line << '  '
              chans.first(shown).each do |ch, _|
                line << cell_text(cells[ch], cw, song.format) << ' '
              end
              c.run(0, y + 1, line.ljust(c.w), role, reverse: current)
            end
          end

          private

          # [[pattern channel index, Log], ...] for the channels the set
          # plays (tracks :ch1.. in order).
          def channel_list(set)
            @channels = nil unless @channels_of.equal?(set)
            @channels ||= begin
              @channels_of = set
              logs = set.import.result.logs.to_h { |l| [l.name, l] }
              set.tracks.filter_map { |t|
                m = t.to_s.match(/\Ach(\d+)\z/) or next
                [m[1].to_i - 1, logs[t]]
              }
            end
          end

          # The widest cell format that fits +n+ channels in +room+ columns.
          def cell_width(room, n)
            [10, 6, 3].find { |w| n * (w + 1) <= room } || 3
          end

          def cell_text(cell, w, format)
            return '·' * [w, 3].min + ' ' * [w - 3, 0].max if cell.nil? || cell.empty?
            note = cell.note ? note_name(cell.note) : '...'
            return note if w == 3
            inst = cell.instrument ? format('%02d', cell.instrument % 100) : '..'
            return "#{note} #{inst}" if w == 6
            fx = cell.effect ? "#{effect_letter(cell.effect, format)}#{format('%02X', cell.param.to_i)}" : '...'
            "#{note} #{inst} #{fx}"
          end

          # Key off, note cut, and IT's note fade as trackers showed them.
          OFF_NOTES = { off: '===', cut: '^^^', fade: '~~~' }.freeze

          def note_name(n)
            return OFF_NOTES.fetch(n, '???') if n.is_a?(Symbol)
            "#{NOTE_NAMES[n % 12]}#{(n / 12) - 1}"
          end

          def effect_letter(e, format)
            if %i[s3m it].include?(format.to_s.downcase.to_sym)
              (64 + e).chr
            else
              e < 10 ? e.to_s : (55 + e).chr
            end
          end
        end

        # A MIDI file's notes as a piano roll around the play head (a few
        # seconds before, more after), notes sounding now bright.
        class Roll < Base
          BEFORE = 2.0
          AFTER = 6.0

          def initialize(player) = super(player, :roll, rate: 20, height: 16, width: 80, title: 'notes', min_height: 4, description: "a MIDI file's notes around the play head")

          def draw_body(c, s, state)
            it = @player.item
            notes = it.respond_to?(:notes) ? it.notes : nil
            unless notes && !notes.empty?
              c.puts [it.loaded? ? 'no notes' : 'loading', :dim]
              return
            end
            unless state[:of].equal?(notes)
              nums = notes.map { |n| n[:number] }
              state[:lo] = nums.min
              state[:hi] = nums.max
              state[:of] = notes
            end
            now = PlayerPanes.heard(@player, s)
            rows = c.h
            lo, hi = state[:lo], state[:hi]
            span = hi - lo + 1
            if span > rows
              mid = (lo + hi) / 2
              lo = mid - rows / 2
              hi = lo + rows - 1
            end
            w = c.w - 4
            t0 = now - BEFORE
            per = (BEFORE + AFTER) / w
            head = (BEFORE / per).round
            grid = Array.new(rows) { ' ' * w }
            on = Array.new(rows) { Array.new(w, false) }
            notes.each do |n|
              off = n[:sustain_time] || n[:off_time]
              next if off < t0 || n[:on_time] > now + AFTER
              y = hi - n[:number]
              next if y < 0 || y >= rows
              a = ((n[:on_time] - t0) / per).floor.clamp(0, w - 1)
              b = ((off - t0) / per).ceil.clamp(a + 1, w)
              (a...b).each { |x| grid[y][x] = '▬' }
              (a...b).each { |x| on[y][x] = true } if n[:on_time] <= now && off > now
            end
            rows.times do |y|
              num = hi - y
              label = num % 12 == 0 ? "C#{num / 12 - 1}".ljust(4) : '    '
              c.text(0, y, label, :dim)
              line = grid[y]
              x = 0
              while x < w
                role = on[y][x] ? :key : x == head ? :warn : x < head ? :dim : :text
                z = x
                z += 1 while z < w && (on[y][z] ? :key : z == head ? :warn : z < head ? :dim : :text) == role
                str = line[x...z]
                str = str.tr(' ', '│') if role == :warn
                c.text(4 + x, y, str, role)
                x = z
              end
            end
          end
        end
      end
    end
  end
end

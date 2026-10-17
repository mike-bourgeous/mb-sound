module MB
  module Sound
    module UI
      module Panes
        # The virtual keyboard (UI::Keyboard, UI.keyboard): a piano strip
        # of the two rows of keys with their letters, the notes held, the
        # octave, velocity, channel, and note-off mode, and the notes just
        # played, or in step entry the clip being built as Ruby.  KEYS mode
        # (in :tiles: NAV then p, `ui.keys`, or `ui :keys`) sends the
        # computer keyboard to it.
        class Keyboard < Pane
          # Semitones of the white keys in an octave.
          WHITE = [0, 2, 4, 5, 7, 9, 11].freeze

          def initialize(keyboard = nil)
            super(:keyboard, rate: 30, height: 8, width: 44)
            @keyboard = keyboard
          end

          def keyboard = @keyboard || UI.keyboard

          # The column of semitone +s+ (from the base C): two cells per
          # white key, black keys between them.
          def self.column(s)
            oct, k = s.divmod(12)
            if WHITE.include?(k)
              2 * (oct * 7 + WHITE.index(k))
            else
              2 * (oct * 7 + WHITE.index(k - 1)) + 1
            end
          end

          # (+state+[:keyboard] is the screen's keyboard, if not UI.keyboard)
          # +text+ in lines of at most +w+ characters, broken after spaces
          # where possible.
          def self.wrap(text, w)
            w = [w, 1].max
            text.scan(/.{1,#{w}}(?:\s+|\z)|.{1,#{w}}/).map(&:rstrip)
          end

          # White keys in the playable span.
          def self.span_whites = @span_whites ||= (0...UI::Keyboard::SPAN).count { |k| WHITE.include?(k % 12) }

          # Colors of the scaled piano: white and black keys, the octaves
          # around the span (not playable), and labels on each.
          WHITE_KEY = [225, 225, 225].freeze
          BLACK_KEY = [40, 40, 40].freeze
          WHITE_DIM = [120, 120, 120].freeze
          BLACK_DIM = [25, 25, 25].freeze

          def draw_body(c, _s, state)
            kb = state[:keyboard] || keyboard
            v = kb.view
            header(c, v, kb)
            held = v.held.map { |n| n - v.base }
            bottom = v.step ? [4, c.h / 3].max : 2
            ph = [c.h - 1 - bottom, 12].min
            ww = [c.w / Keyboard.span_whites, 5].min
            if ww >= 2 && ph >= 4
              piano(c, 1, ph, ww, held, v, kb)
              info = 1 + ph
            else
              # Compact: letters over and under a two-row strip
              letters(c, 1, UI::Keyboard::UPPER, held, v)
              keys(c, 2, held, v, kb)
              letters(c, 4, UI::Keyboard::LOWER, held, v)
              info = 5
            end
            v.step ? step(c, v, info) : played(c, v, kb, info)
          end

          private

          # The scaled piano (ux-1 item 14): white keys +ww+ columns wide
          # (one of them a gap), black keys about 60% of that and of the
          # height +ph+, the computer keys' letters inside the keys and
          # the C's names, held keys filled from the bottom by velocity,
          # and the octaves beside the span dimmed where there is room.
          def piano(c, y0, ph, ww, held, v, kb)
            extra = (c.w - Keyboard.span_whites * ww) / ww
            left = [extra / 2, 7].min
            right = [extra - left, 7].min
            x0 = (c.w - (left + Keyboard.span_whites + right) * ww) / 2 + left * ww
            bh = [(ph * 0.6).round, 1].max
            bw = [(ww * 0.6).round, 1].max
            letters = UI::Keyboard::KEYS.each_with_object({}) { |(ch, s), h| (h[s] ||= []) << ch }
            first = -semis_for_whites(left)
            last = UI::Keyboard::SPAN - 1 + semis_after(UI::Keyboard::SPAN - 1, right)
            # White keys
            (first..last).each do |s|
              next unless WHITE.include?(s % 12)
              x = x0 + white_index(s) * ww
              playable = s >= 0 && s < UI::Keyboard::SPAN
              fill = playable && held.include?(s) ? fill_rows(ph, v.velocities[v.base + s]) : 0
              ph.times do |dy|
                filled = dy >= ph - fill
                rgb = filled ? Themes.rgb(:armed) : playable ? WHITE_KEY : WHITE_DIM
                c.run(x, y0 + dy, ' ' * (ww - 1), rgb, reverse: true)
              end
              next unless playable
              ink = ->(dy) { [[30, 30, 30], { bg: dy >= ph - fill ? Themes.rgb(:armed) : WHITE_KEY }] }
              label = letters[s]&.join || ''
              unless label.empty?
                fg, o = ink.(ph - 1)
                c.run(x, y0 + ph - 1, label[0, ww - 1], fg, **o)
              end
              if s % 12 == 0 && ph >= 3
                fg, o = ink.(ph - 2)
                c.run(x, y0 + ph - 2, kb.note_name(v.base + s)[0, ww - 1], fg, **o)
              end
            end
            # Black keys over them
            (first..last).each do |s|
              next if WHITE.include?(s % 12)
              gap = x0 + white_index(s - 1) * ww + ww - 1
              x = gap - bw / 2
              playable = s >= 0 && s < UI::Keyboard::SPAN
              fill = playable && held.include?(s) ? fill_rows(bh, v.velocities[v.base + s]) : 0
              bh.times do |dy|
                filled = dy >= bh - fill
                rgb = filled ? Themes.rgb(:armed) : playable ? BLACK_KEY : BLACK_DIM
                c.run(x, y0 + dy, ' ' * bw, rgb, reverse: true)
              end
              next unless playable && letters[s]
              filled = bh - 1 >= bh - fill
              c.run(x, y0 + bh - 1, letters[s].join[0, bw], filled ? [20, 20, 20] : [210, 210, 210], bg: filled ? Themes.rgb(:armed) : BLACK_KEY)
            end
          end

          # Rows of a held key filled for raw velocity +vel+ (1..127).
          def fill_rows(rows, vel)
            [(rows * (vel || 96) / 127.0).ceil, 1].max
          end

          # The white key index of semitone +s+ from the base C (negative
          # below it).
          def white_index(s)
            oct, k = s.divmod(12)
            oct * 7 + WHITE.index(WHITE.include?(k) ? k : k - 1)
          end

          # Semitones below the base C covering +n+ white keys.
          def semis_for_whites(n)
            return 0 if n <= 0
            s = 0
            count = 0
            while count < n
              s += 1
              count += 1 if WHITE.include?((-s) % 12)
            end
            s
          end

          # Semitones after +s+ covering +n+ more white keys.
          def semis_after(s, n)
            return 0 if n <= 0
            d = 0
            count = 0
            while count < n
              d += 1
              count += 1 if WHITE.include?((s + d) % 12)
            end
            d
          end

          def header(c, v, kb)
            x = if v.active
                  c.run(0, 0, v.entry == :step ? ' STEP ' : ' KEYS ', v.entry == :step ? :queued : :armed, reverse: true, bold: true)
                else
                  c.text(0, 0, 'KEYBOARD', :title)
                end
            mode = v.off_mode.to_s
            mode += ' (no key-up)' unless v.releases
            c.line(0, ' ', [kb.note_name(v.base), :key], ['-', :dim], [kb.note_name(v.base + UI::Keyboard::SPAN - 1), :key],
                   ['  vel ', :dim], [v.velocity.to_s, :key], ['  ch ', :dim], [(v.channel + 1).to_s, :key],
                   ['  ', nil], [mode, v.releases ? :ok : :warn], (v.sustain ? ['  sustain', :armed] : ''), x: x)
          end

          # Key letters over (or under) their keys.
          def letters(c, y, row, held, _v)
            row.each do |ch, s|
              c.text(Keyboard.column(s), y, ch, held.include?(s) ? :armed : :dim)
            end
          end

          # Black keys on row +y+, white keys (note names on the Cs) below.
          def keys(c, y, held, v, kb)
            UI::Keyboard::SPAN.times do |s|
              x = Keyboard.column(s)
              on = held.include?(s)
              if WHITE.include?(s % 12)
                label = s % 12 == 0 ? kb.note_name(v.base + s)[0, 2] : kb.note_name(v.base + s)[0]
                label = label.ljust(2)[0, 2] if s % 12 == 0
                c.run(x, y + 1, label, on ? :armed : :text, reverse: on)
              else
                c.run(x, y, ' ', on ? :armed : :dim, reverse: true)
              end
            end
          end

          def played(c, v, kb, y = 5)
            notes = v.played.last(12).map { |p| kb.note_name(p.note) }
            c.line(y, ['played ', :dim], [notes.join(' '), :name]) unless notes.empty?
            c.line(y, [v.message.to_s, :dim]) if notes.empty? && v.message
            hint = v.active ? 'Ctrl-] back  -/+ octave  Up/Dn vel  Space sus  Esc off  Enter capture  ` mode  Tab step' : 'NAV p (or ui.keys): play the keyboard'
            c.text(0, c.h - 1, c.fit(hint, c.w), :dim) if c.h > y + 1
          end

          def step(c, v, y = 5)
            st = v.step
            c.line(y, ['len ', :dim], [st.length, :key], ['  steps ', :dim], [st.count.to_s, :key],
                   ['  ', nil], [Panes.fmt(st.total.to_f), :key], [' whole notes', :dim])
            text = st.text || 'lower row: notes  1-7 length  8 dot  9 triplet  r rest  t tie'
            rows = [c.h - y - 1, 1].max
            Keyboard.wrap(text, c.w).last(rows).each_with_index { |l, i| c.text(0, y + 1 + i, l, st.text ? :name : :dim) }
          end
        end
      end
    end
  end
end

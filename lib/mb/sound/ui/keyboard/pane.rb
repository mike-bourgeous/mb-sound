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

          def draw_body(c, _s, state)
            kb = state[:keyboard] || keyboard
            v = kb.view
            header(c, v, kb)
            held = v.held.map { |n| n - v.base }
            letters(c, 1, UI::Keyboard::UPPER, held, v)
            keys(c, 2, held, v, kb)
            letters(c, 4, UI::Keyboard::LOWER, held, v)
            v.step ? step(c, v) : played(c, v, kb)
          end

          private

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

          def played(c, v, kb)
            notes = v.played.last(12).map { |p| kb.note_name(p.note) }
            c.line(5, ['played ', :dim], [notes.join(' '), :name]) unless notes.empty?
            c.line(5, [v.message.to_s, :dim]) if notes.empty? && v.message
            hint = v.active ? 'Ctrl-] back  -/+ octave  Up/Dn vel  Space sus  Esc off  Enter capture  ` mode  Tab step' : 'NAV p (or ui.keys): play the keyboard'
            c.text(0, c.h - 1, c.fit(hint, c.w), :dim) if c.h > 6
          end

          def step(c, v)
            st = v.step
            c.line(5, ['len ', :dim], [st.length, :key], ['  steps ', :dim], [st.count.to_s, :key],
                   ['  ', nil], [Panes.fmt(st.total.to_f), :key], [' whole notes', :dim])
            text = st.text || 'lower row: notes  1-7 length  8 dot  9 triplet  r rest  t tie'
            rows = [c.h - 6, 1].max
            Keyboard.wrap(text, c.w).last(rows).each_with_index { |l, i| c.text(0, 6 + i, l, st.text ? :name : :dim) }
          end
        end
      end
    end
  end
end

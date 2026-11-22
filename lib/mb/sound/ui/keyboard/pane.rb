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
            super(:keyboard, rate: 30, height: 8, width: 44, min_height: 6, description: 'the virtual keyboard: a piano of the computer keys, held notes, octave, velocity, step entry')
            @keyboard = keyboard
            # (kept between draws: the pane draws at the target rate, and the
            # piano's Strings and Arrays were ~740 objects a draw, 90k/s at
            # 122 fps on ui :wall; 2026-11-17)
            @spaces = []
            @names = {}
            @cuts = {}
            @fill = 0
            @fill_rgb = nil
            @arm_shown = true
            @sections = {}
            @parts = nil
            @parts_key = [nil, 0, 0, 0, 0, nil]
          end

          # The computer keys' letters by semitone ({semitone => "zs"}; made
          # on first use: UI::Keyboard loads after this file).
          def self.letters = @letters ||= UI::Keyboard::KEYS.each_with_object({}) { |(ch, s), h| (h[s] ||= +'') << ch }.transform_values(&:freeze).freeze

          # The ink of labels on white keys.
          LABEL_INK = [30, 30, 30].freeze
          BLACK_INK_FILLED = [20, 20, 20].freeze
          BLACK_INK = [210, 210, 210].freeze

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
          def self.wrap(text, w) = Canvas.wrap(text, w)

          # White keys in the playable span.
          def self.span_whites = @span_whites ||= (0...UI::Keyboard::SPAN).count { |k| WHITE.include?(k % 12) }

          # Colors of the scaled piano: white and black keys, the octaves
          # around the span (not playable), and labels on each.
          WHITE_KEY = [225, 225, 225].freeze
          BLACK_KEY = [40, 40, 40].freeze
          WHITE_DIM = [120, 120, 120].freeze
          BLACK_DIM = [25, 25, 25].freeze

          # Seconds of notes the roll shows.
          ROLL_SECONDS = 4.0

          # The pane's sections (UI::Sections), in screen order: the header,
          # the piano (taller keys with more rows), the step clip in step
          # entry, the chord held, what was played and the keys' hint, a
          # roll of the last ROLL_SECONDS of notes, and the armed tracks with
          # what Enter does.  At the usual 8 rows: header, a 5-row piano,
          # played and hint; zoomed, the rest appear (ux-1 r3 item 31).
          def sections(step)
            @sections[step] ||= make_sections(step)
          end

          private def make_sections(step)
            list = [
              Sections::Section.new(name: :header, min: 1, priority: 0),
              Sections::Section.new(name: :piano, min: 4, pref: step ? 4 : 5, max: 14, priority: 1),
            ]
            if step
              list << Sections::Section.new(name: :step, min: 2, pref: 3, max: 10, priority: 2)
            else
              list << Sections::Section.new(name: :chord, min: 1, priority: 4)
              list << Sections::Section.new(name: :played, min: 1, pref: 2, priority: 2)
            end
            list << Sections::Section.new(name: :roll, min: 4, pref: 8, max: 16, priority: 5)
            # (the armed tracks outrank the chord and the roll: ux-friction-3,
            # the maintainer: "the message about arming should be shown on
            # smaller keyboard sizes whenever possible.  I keep forgetting
            # that \"arm\" is a thing"; without room for it, the header
            # says it: #arm_hint)
            list << Sections::Section.new(name: :armed, min: 2, pref: 3, max: 6, priority: 3)
            list.freeze
          end

          # The section canvases of +c+ (kept while the canvas, its place,
          # and the step flag stay; their rows reset).
          private def parts_of(c, step)
            k = @parts_key
            if @parts && k[0].equal?(c) && k[1] == c.x && k[2] == c.y && k[3] == c.w && k[4] == c.h && k[5] == step
              @parts.each_value { |p| p.row = 0 }
              return @parts
            end
            k[0] = c
            k[1] = c.x
            k[2] = c.y
            k[3] = c.w
            k[4] = c.h
            k[5] = step
            @parts = Sections.canvases(c, sections(step))
          end

          def draw_body(c, s, state)
            kb = state[:keyboard] || keyboard
            v = kb.view
            track_roll(state, v)
            parts = parts_of(c, !v.step.nil?)
            x = header(parts[:header], v, kb)
            @arm_shown = parts[:armed] ? true : arm_hint(parts[:header], x, s)
            held = v.held.map { |n| n - v.base }
            inputs = Keyboard.input_fills(s, v.base)
            if (pc = parts[:piano])
              ww = [pc.w / Keyboard.span_whites, 5].min
              if ww >= 2 && pc.h >= 4
                piano(pc, 0, pc.h, ww, held, v, kb, inputs)
              else
                # Compact: letters over and under a two-row strip
                letters(pc, 0, UI::Keyboard::UPPER, held, v)
                keys(pc, 1, held, v, kb, inputs)
                letters(pc, 3, UI::Keyboard::LOWER, held, v)
              end
            end
            step(parts[:step], v, 0) if parts[:step]
            chord(parts[:chord], v, kb, s) if parts[:chord]
            played(parts[:played], v, kb, 0) if parts[:played]
            roll(parts[:roll], state, kb) if parts[:roll]
            armed(parts[:armed], s) if parts[:armed]
          end

          # Notes from the Session's MIDI input (ux-r4 item 9: external
          # keyboards; Snapshot#notes, not the UI keyboard's own, which
          # Keyboard#held shows) as { semitone from +base+ => [velocity
          # 1..127, :input or :pressed] }.  With Snapshot#sounding (a scale
          # transform's output, from midi-consol-2), sounding notes fill and
          # keys pressed but mapped elsewhere show :pressed (one row).
          def self.input_fills(s, base)
            notes = (s.respond_to?(:notes) && s.notes) || []
            ext = notes.reject { |n| n.source == :keyboard }
            return {}.freeze if ext.empty? && !(s.respond_to?(:sounding) && s.sounding)
            sounding = s.respond_to?(:sounding) ? s.sounding : nil
            fills = {}
            if sounding
              ext.each { |n| fills[n.note - base] = [n.velocity, :pressed] }
              sounding.reject { |n| n.respond_to?(:source) && n.source == :keyboard }.each { |n| fills[n.note - base] = [n.velocity, :input] }
            else
              ext.each { |n| fills[n.note - base] = [n.velocity, :input] }
            end
            fills
          end

          private

          # Color of input notes (a second color beside the keyboard's own).
          def input_rgb = MB::Term::Themes.rgb(:key)

          # The scaled piano (ux-1 item 14): white keys +ww+ columns wide
          # (one of them a gap), black keys about 60% of that and of the
          # height +ph+, the computer keys' letters inside the keys and
          # the C's names, held keys filled from the bottom by velocity,
          # and the octaves beside the span dimmed where there is room.
          def piano(c, y0, ph, ww, held, v, kb, inputs = {})
            extra = (c.w - Keyboard.span_whites * ww) / ww
            left = [extra / 2, 7].min
            right = [extra - left, 7].min
            x0 = (c.w - (left + Keyboard.span_whites + right) * ww) / 2 + left * ww
            bh = [(ph * 0.6).round, 1].max
            bw = [(ww * 0.6).round, 1].max
            letters = Keyboard.letters
            first = -semis_for_whites(left)
            last = UI::Keyboard::SPAN - 1 + semis_after(UI::Keyboard::SPAN - 1, right)
            # White keys
            (first..last).each do |s|
              next unless WHITE.include?(s % 12)
              x = x0 + white_index(s) * ww
              playable = s >= 0 && s < UI::Keyboard::SPAN
              key_fill(ph, s, playable, held, v, inputs)
              fill = @fill
              frgb = @fill_rgb
              blank = spaces(ww - 1)
              dy = 0
              while dy < ph
                filled = dy >= ph - fill
                rgb = filled ? frgb : playable ? WHITE_KEY : WHITE_DIM
                c.run(x, y0 + dy, blank, rgb, reverse: true)
                dy += 1
              end
              next unless playable
              label = letters[s]
              if label
                c.run(x, y0 + ph - 1, cut(label, ww - 1), LABEL_INK, bg: ph - 1 >= ph - fill ? frgb : WHITE_KEY)
              end
              if s % 12 == 0 && ph >= 3
                c.run(x, y0 + ph - 2, cut(note_name(kb, v.base + s), ww - 1), LABEL_INK, bg: ph - 2 >= ph - fill ? frgb : WHITE_KEY)
              end
            end
            # Black keys over them
            (first..last).each do |s|
              next if WHITE.include?(s % 12)
              gap = x0 + white_index(s - 1) * ww + ww - 1
              x = gap - bw / 2
              playable = s >= 0 && s < UI::Keyboard::SPAN
              key_fill(bh, s, playable, held, v, inputs)
              fill = @fill
              frgb = @fill_rgb
              blank = spaces(bw)
              dy = 0
              while dy < bh
                filled = dy >= bh - fill
                rgb = filled ? frgb : playable ? BLACK_KEY : BLACK_DIM
                c.run(x, y0 + dy, blank, rgb, reverse: true)
                dy += 1
              end
              next unless playable && letters[s]
              filled = bh - 1 >= bh - fill
              c.run(x, y0 + bh - 1, cut(letters[s], bw), filled ? BLACK_INK_FILLED : BLACK_INK, bg: filled ? frgb : BLACK_KEY)
            end
          end

          # +n+ spaces (kept per length).
          def spaces(n) = @spaces[n] ||= (' ' * n).freeze

          # The first +n+ characters of frozen +str+ (kept per String and
          # length).
          def cut(str, n)
            return str if str.length <= n
            (@cuts[str] ||= [])[n] ||= str[0, n].freeze
          end

          # Note +n+'s name as the keyboard writes it (kept per note).
          def note_name(kb, n) = @names[n] ||= kb.note_name(n).freeze

          # Rows filled (@fill) and their color (@fill_rgb) for semitone +s+:
          # the keyboard's own held keys first (only in the playable span),
          # else an input note (anywhere on the strip; :pressed ones a
          # single dim row).  (Set in ivars, not returned as a pair: no
          # Array a key.)
          def key_fill(rows, s, playable, held, v, inputs)
            if playable && held.include?(s)
              @fill = fill_rows(rows, v.velocities[v.base + s])
              @fill_rgb = MB::Term::Themes.rgb(:armed)
              return
            end
            e = inputs[s]
            kind = e && e[1]
            if !kind
              @fill = 0
              @fill_rgb = nil
            elsif kind == :pressed
              @fill = 1
              @fill_rgb = MB::Term::Themes.rgb(:dim)
            else
              @fill = fill_rows(rows, e[0])
              @fill_rgb = input_rgb
            end
          end

          # Rows of a held key filled for raw velocity +vel+ (1..127).
          def fill_rows(rows, vel)
            [(rows * (vel || 96) / 127.0).ceil, 1].max
          end

          # The white key index of semitone +s+ from the base C (negative
          # below it).
          def white_index(s)
            oct = s / 12 # (floored, as divmod: no Array)
            k = s % 12
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
            mode = kb.off_mode_label
            mode += ' (no key-up)' unless v.releases
            c.line(0, ' ', [note_name(kb, v.base), :key], ['-', :dim], [note_name(kb, v.base + UI::Keyboard::SPAN - 1), :key],
                   ['  vel ', :dim], [v.velocity.to_s, :key], ['  ch ', :dim], [(v.channel + 1).to_s, :key],
                   ['  ', nil], [mode, v.releases ? :ok : :warn], (v.sustain ? ['  sustain', :armed] : ''),
                   (v.scale ? ['  ', nil] : ''), (v.scale ? [v.scale, :queued] : ''), x: x)
          end

          # Key letters over (or under) their keys.
          def letters(c, y, row, held, _v)
            row.each do |ch, s|
              c.text(Keyboard.column(s), y, ch, held.include?(s) ? :armed : :dim)
            end
          end

          # Black keys on row +y+, white keys (note names on the Cs) below.
          def keys(c, y, held, v, kb, inputs = {})
            UI::Keyboard::SPAN.times do |s|
              x = Keyboard.column(s)
              on = held.include?(s)
              role = on ? :armed : inputs[s] ? (inputs[s][1] == :pressed ? :dim : :key) : nil
              if WHITE.include?(s % 12)
                label = s % 12 == 0 ? note_name(kb, v.base + s)[0, 2] : note_name(kb, v.base + s)[0]
                label = label.ljust(2)[0, 2] if s % 12 == 0
                c.run(x, y + 1, label, role || :text, reverse: !role.nil?)
              else
                c.run(x, y, ' ', role || :dim, reverse: true)
              end
            end
          end

          def played(c, v, kb, y = 5)
            notes = v.played.last(12).map { |p| note_name(kb, p.note) }
            c.line(y, ['played ', :dim], [notes.join(' '), :name]) unless notes.empty?
            c.line(y, [v.message.to_s, :dim]) if notes.empty? && v.message
            return unless c.h > y + 1

            # (no room for the arm hint in the header: it leads the keys' hint)
            x = @arm_shown ? 0 : c.line(c.h - 1, [ARM, :key], [ARM_AFTER, :dim])
            c.text_fit(x, c.h - 1, v.active ? ACTIVE_HINT : NAV_HINT, c.w - x, :dim)
          end

          # The keys' hint under the piano, playing and not.
          ACTIVE_HINT = 'Ctrl-] back  -/+ octave  Up/Dn vel  Space sus  Esc off  Enter capture  ` mode  Tab step'
          NAV_HINT = 'NAV K (or ui.keys, F2): play the keyboard'

          # The arm hint's command, and its forms after the header (longest
          # first; #arm_hint takes the first that fits), and before the
          # keys' hint.
          ARM = 'arm :name'
          ARM_AFTER = ' plays a track  '
          ARM_FORMS = [
            ['  nothing armed: ', ' plays a track'],
            ['  ', ' plays a track'],
            ['  ', ''],
          ].map { |a| a.map(&:freeze).freeze }.freeze
          ARMED = '  -> '

          # After the header's text (ending at +x+): with nothing armed, the
          # longest arm hint that fits (ARM_FORMS), else the armed tracks'
          # names.  True if it showed.
          def arm_hint(c, x, s)
            armed = s.respond_to?(:armed) ? s.armed : nil
            if armed && !armed.empty?
              names = armed.length == 1 ? armed[0].to_s : armed.map(&:to_s).join(' ')
              return false if x + ARMED.length + names.length > c.w

              c.line(0, [ARMED, :dim], [names, :armed], x: x)
              return true
            end
            ARM_FORMS.each do |before, after|
              next if x + before.length + ARM.length + after.length > c.w

              c.line(0, [before, :dim], [ARM, :key], [after, :dim], x: x)
              return true
            end
            false
          end

          # The notes held and their chord's name ("held C3 E3 G3  C").
          def chord(c, v, kb, s = nil)
            ext = ((s.respond_to?(:notes) && s.notes) || []).reject { |n| n.source == :keyboard }.map(&:note).uniq
            x = 0
            unless v.held.empty?
              name = ChordName.of(v.held)
              x = c.line(0, ['held ', :dim], [v.held.sort.map { |n| note_name(kb, n) }.join(' '), :name])
              x = c.line(0, ['  ', nil], [name, :key], x: x) if name
              x = c.text(x, 0, '  ', nil)
            end
            return if ext.empty?
            name = ChordName.of(ext)
            x = c.line(0, ['input ', :dim], [ext.sort.map { |n| note_name(kb, n) }.join(' '), :key], x: x)
            c.line(0, ['  ', nil], [name, :key], x: x) if name
          end

          # Notes start when they show up held and end when they go, at the
          # pane's draw rate (the keyboard's own events carry no times).
          def track_roll(state, v)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            roll = (state[:roll] ||= [])
            open = (state[:roll_open] ||= {})
            v.held.each { |n| open[n] ||= (roll << [n, v.velocities[n] || v.velocity, now, nil]).last }
            open.keys.each { |n| (open.delete(n)[3] = now) unless v.held.include?(n) }
            roll.shift while roll.first && roll.first[3] && roll.first[3] < now - ROLL_SECONDS
            state[:roll_now] = now
          end

          # The roll: the last ROLL_SECONDS of notes as bars on a time axis
          # (now at the right), one row per note played, highest on top.
          def roll(c, state, kb)
            now = state[:roll_now]
            notes = state[:roll].map(&:first).uniq.sort.reverse
            c.text(0, 0, c.fit("last #{ROLL_SECONDS.round} s", c.w), :dim)
            return if notes.empty?
            label_w = 4
            span = c.w - label_w - 1
            return if span < 4
            rows = notes.first(c.h - 1)
            rows.each_with_index do |n, i|
              y = i + 1
              c.text(0, y, note_name(kb, n).ljust(label_w), :name)
              state[:roll].each do |note, vel, on, off|
                next unless note == n
                x0 = ((on - (now - ROLL_SECONDS)) / ROLL_SECONDS * span).floor.clamp(0, span - 1)
                x1 = (((off || now) - (now - ROLL_SECONDS)) / ROLL_SECONDS * span).ceil.clamp(x0 + 1, span)
                c.run(label_w + 1 + x0, y, ' ' * (x1 - x0), vel.to_i >= 110 ? :warn : off ? :key : :armed, reverse: true)
              end
            end
            c.text(0, c.h - 1, "+#{notes.length - rows.length} more", :dim) if notes.length > rows.length && c.h > 2
          end

          # The armed tracks and what Enter does now.
          def armed(c, s)
            armed = s&.armed || []
            if armed.empty?
              c.puts ['nothing armed: ', :dim], ['the default patch plays; ', :dim], ['arm :name', :key], [' to play a track', :dim]
              c.puts ['Enter: ', :dim], ['nothing to capture into', :dim]
              return
            end
            c.puts ['armed ', :dim], [armed.map(&:to_s).join(' '), :armed]
            c.puts ['Enter: ', :dim], ["capture what you played into #{armed.map(&:inspect).join(', ')}", :key]
          end

          def step(c, v, y = 5)
            st = v.step
            # The length the next note gets (a length key sets it for the
            # notes that follow, until the next length key; panel round 2,
            # K17: "I couldn't predict what 1 and 2 meant"), and the legend
            c.line(y, ['next note ', :dim], [st.length, :key], ['  steps ', :dim], [st.count.to_s, :key],
                   ['  ', nil], [Panes.fmt(st.total.to_f), :key], [' whole notes', :dim])
            y += 1
            c.text(0, y, UI::Keyboard::StepEntry.legend, :dim)
            text = st.text || 'lower row: notes  r rest  t tie  Enter done  Shift-Enter swap'
            rows = [c.h - y - 1, 1].max
            Keyboard.wrap(text, c.w).last(rows).each_with_index { |l, i| c.text(0, y + 1 + i, l, st.text ? :name : :dim) }
          end
        end
      end
    end
  end
end

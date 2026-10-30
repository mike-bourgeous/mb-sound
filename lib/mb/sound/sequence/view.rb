module MB
  module Sound
    module Sequence
      # A text view of a Clip or grid Kit for reading music in the console
      # (people and agents; parity-1, 2026-10-30, backlog 12.5): made by
      # Clip#show and Kit#show, printed by Pry like a Plot::Chart, and a
      # String with #to_s.
      #
      # Kinds:
      # - :grid: one row per note value (a Kit: per row name), one column
      #   per step, in MB::Sound#grid's characters (x hit, X accent, 1-9
      #   velocity ninths, - held, ? chance, f/F flam, . empty, | bar
      #   lines), so a Kit's rows parse back: `grid(16, **beat.show.rows)`.
      # - :roll: a piano roll: every semitone from the highest note to the
      #   lowest, a bar ruler on top.
      # - :degrees: one line per bar of scale degrees counted from 1 in a
      #   scale (the session key's by default): `#4` for a note a semitone
      #   above the 4th, `'` per octave above the middle note's octave and
      #   `,` per octave below (ABC notation's marks), `/` joining notes
      #   that start together, `-` held, `.` empty.
      #
      # Steps are the clip's own (the coarsest of 16ths, 32nds, 16th
      # triplets, 64ths, 96ths that holds every start and end exactly),
      # or +step:+ (a note division like 16 or a Duration); notes off the
      # steps are drawn at the nearest one and the header says "about".
      # Loops show one cycle (+cycle:+, with its variations); lines wrap
      # to +width+ columns at bar lines.
      View = Data.define(:kind, :text, :rows) do
        def to_s = text

        def inspect
          "#<#{self.class.name} :#{kind}, #{text.lines.length} lines>"
        end

        # Pry prints the view itself.
        def pretty_print(q)
          q.text("\n" + text)
        end
      end

      class View
        KINDS = %i[grid roll degrees].freeze

        # Step divisions tried, coarsest first (whole notes per step: 1/n).
        DIVISIONS = [16, 32, 48, 64, 96].freeze

        # Default line width (the help pages' width).
        WIDTH = 100

        # The View of +kind+ for +source+ (a Clip or Kit).  See View.
        def self.of(source, kind = :grid, step: nil, cycle: 0, scale: nil, width: WIDTH, bar: nil)
          unless KINDS.include?(kind)
            hint = DidYouMean::SpellChecker.new(dictionary: KINDS.map(&:to_s)).correct(kind.to_s).first
            raise ArgumentError, "show takes #{KINDS.map(&:inspect).join(', ')} (got #{kind.inspect}#{hint ? "; did you mean :#{hint}?" : ''})"
          end

          bar ||= Sequence.current_transport.bar_length
          bar = Duration.whole_notes(bar)
          rows = source.is_a?(Kit) ? kit_rows(source, cycle) : clip_rows(source, cycle)
          length = rows.map { |r| r[:length] }.max || 0r
          return View.new(kind: kind, text: '(empty clip)', rows: {}) if length <= 0

          events = rows.flat_map { |r| r[:events] }
          div, exact = division(events, length, step)
          builder = Builder.new(rows, length, div, exact, bar, width)
          case kind
          when :grid then builder.grid(source.is_a?(Kit))
          when :roll then source.is_a?(Kit) ? builder.grid(true, ruler: true) : builder.roll
          when :degrees
            raise ArgumentError, "A drum kit's rows have no scale degrees; show it as :grid" if source.is_a?(Kit)
            builder.degrees(scale || MB::Sound.scale)
          end
        end

        # [{ name:, events:, length: }] for one Kit row each.
        def self.kit_rows(kit, cycle)
          kit.rows.map { |name, clip| { name: name.to_s, events: cycle_events(clip, cycle), length: clip.length } }
        end

        # One entry for the whole clip (rows by value come later).
        def self.clip_rows(clip, cycle)
          [{ name: nil, events: cycle_events(clip, cycle), length: clip.length }]
        end

        # The events of +clip+'s +cycle+ that play (probabilities are
        # drawn as ?, so every event with a chance shows).
        def self.cycle_events(clip, cycle)
          list = clip.looping? ? clip.events_for(cycle) : clip.events
          list.select { |e| e.start >= 0 && e.start < clip.length }
        end

        # [steps per whole note, exact?] for +events+ within +length+.
        def self.division(events, length, step)
          if step
            div = (1 / Duration.whole_notes(step)).to_r
            raise ArgumentError, "show's step: must divide a whole note into whole steps (got #{step.inspect})" unless div.denominator == 1 && div > 0
            div = div.to_i
            return [div, on_steps?(events, length, div)]
          end

          found = DIVISIONS.find { |d| on_steps?(events, length, d) }
          found ? [found, true] : [32, false]
        end

        def self.on_steps?(events, length, div)
          [length, *events.flat_map { |e| [e.start, e.end_time] }].all? { |t| (t.to_r * div).denominator == 1 }
        end

        # Draws the views (see View.of).
        class Builder
          def initialize(rows, length, div, exact, bar, width)
            @rows = rows
            @length = length
            @div = div
            @exact = exact
            @bar = bar
            @width = width
            @steps = (length * div).ceil
            @bar_steps = MB::M.max((bar * div).round, 1)
          end

          # A grid view: one row per Kit row, or per note value of a clip
          # (highest first).  +ruler+ adds a bar ruler.
          def grid(kit, ruler: false)
            lines = kit ? @rows.map { |r| [r[:name], cells(r[:events], (r[:length] * @div).ceil)] } : value_rows(roll: false)
            rows = lines.to_h { |name, c| [name.to_sym, with_bars(c)] }
            View.new(kind: ruler ? :roll : :grid, text: layout(header('grid'), lines, ruler: ruler), rows: rows)
          end

          # A piano roll: every semitone between the highest and lowest
          # note values.
          def roll
            lines = value_rows(roll: true)
            View.new(kind: :roll, text: layout(header('roll'), lines, ruler: true), rows: lines.to_h { |n, c| [n.to_sym, with_bars(c)] })
          end

          # Scale degrees, one line per bar (see View).
          def degrees(scale)
            events = @rows[0][:events]
            numbered = events.filter_map { |e| [e, number_of(e.value)] if number_of(e.value) }
            return View.new(kind: :degrees, text: '(no notes)', rows: {}) if numbered.empty?

            # (the octave of the middle note is 1-7: ' marks octaves above,
            # , octaves below)
            degs = numbered.map { |_, n| scale.degree(n)[0] }.sort
            ref = (degs[(degs.length - 1) / 2].to_f / scale.size).floor * scale.size
            slots = Array.new(@steps) { [] }
            held = Array.new(@steps, false)
            numbered.sort_by { |e, n| [e.start, n] }.each do |e, n|
              i = step_of(e.start)
              next if i >= @steps
              slots[i] << degree_token(scale, n, ref)
              last = [step_of(e.end_time), @steps].min
              ((i + 1)...last).each { |j| held[j] = true }
            end
            tokens = slots.each_with_index.map { |s, i| s.empty? ? (held[i] ? '-' : '.') : s.join('/') }
            w = tokens.map(&:length).max
            bars = tokens.each_slice(@bar_steps).each_with_index.map { |part, b| "bar #{b + 1}  #{part.map { |t| t.ljust(w) }.join(' ').rstrip}" }
            root = Event.note_name(scale.note(ref))
            text = "#{header('degrees')}, #{scale}, 1 = #{root}\n#{bars.join("\n")}"
            View.new(kind: :degrees, text: text, rows: {})
          end

          private

          def header(kind)
            step = "1/#{@div}"
            "#{kind} in steps of #{step}#{@exact ? '' : ' (about: some notes are between steps)'}, #{Duration.format(@length)} long"
          end

          # [[label, cells]] per note value, highest first; +roll+ fills in
          # every semitone between.
          def value_rows(roll:)
            events = @rows[0][:events]
            by = events.group_by { |e| row_key(e.value) }
            keys = by.keys
            numbers = keys.grep(Numeric)
            if roll && !numbers.empty?
              lo, hi = numbers.minmax
              keys = (keys - numbers) + (lo.floor..hi.ceil).to_a.reverse.select { |n| n.is_a?(Integer) } +
                     numbers.reject { |n| n.is_a?(Integer) || (n == n.round) }
              keys = keys.uniq
            end
            keys = keys.sort_by { |k| k.is_a?(Numeric) ? [0, -k] : [1, k.to_s] }
            keys.map { |k| [label(k), cells(by[k] || [], @steps)] }
          end

          def row_key(v)
            v.is_a?(Integer) || v.is_a?(Float) ? (v == v.round ? v.round : v) : v.to_s
          end

          def label(k)
            k.is_a?(Integer) && Event.note_value?(k) ? Event.note_name(k) : (k.is_a?(Numeric) ? MB::M.sigfigs(k, 6).to_s : k.to_s)
          end

          def number_of(v)
            case v
            when MB::Sound::Note then v.number
            when Numeric then v
            end
          end

          def degree_token(scale, n, ref)
            deg, offset = scale.degree(n)
            d = deg - ref
            octave, idx = d.divmod(scale.size)
            name = (idx + 1).to_s
            name = offset == offset.round ? "#{'#' * offset.round}#{name}" : "#{name}+#{MB::M.sigfigs(offset, 3)}" unless offset == 0
            octave >= 0 ? name + "'" * octave : name + ',' * -octave
          end

          def step_of(t)
            (t.to_r * @div).round
          end

          # Grid characters for +events+ over +steps+ steps.
          def cells(events, steps)
            c = Array.new(steps, '.')
            events.sort_by(&:start).each do |e|
              i = step_of(e.start)
              next if i >= steps
              last = [MB::M.max(step_of(e.end_time), i + 1), steps].min
              ((i + 1)...last).each { |j| c[j] = '-' if c[j] == '.' }
              c[i] = hit_char(e)
            end
            c
          end

          def hit_char(e)
            return '?' if e.probability && e.probability < 1
            accent = e.accented || e.velocity >= Clip::ACCENT_VELOCITY
            return accent ? 'F' : 'f' if e.flam
            return 'X' if accent
            return 'x' if (e.velocity - Clip::DEFAULT_VELOCITY).abs < 1e-9
            MB::M.clamp((e.velocity * 9).round, 1, 9).to_s
          end

          # +cells+ as a String with | at bar lines.
          def with_bars(cells)
            cells.each_slice(@bar_steps).map(&:join).join('|')
          end

          # The rows laid out with labels, wrapped at bar lines to the width.
          def layout(head, lines, ruler:)
            lw = lines.map { |n, _| n.length }.max || 0
            bar_w = @bar_steps + 1
            per_line = MB::M.max((@width - lw - 2) / bar_w, 1)
            total_bars = (@steps.to_f / @bar_steps).ceil
            out = [head]
            (0...total_bars).each_slice(per_line).with_index do |bars, chunk|
              out << '' if chunk > 0
              if ruler
                marks = bars.map { |b| "#{b + 1}".ljust(@bar_steps) }.join(' ')
                out << "#{' ' * lw}  #{marks}".rstrip
              end
              lines.each do |name, cells|
                parts = bars.filter_map { |b| part = cells[b * @bar_steps, @bar_steps]; part.join unless part.nil? || part.empty? }
                out << "#{name.ljust(lw)}  #{parts.join('|')}"
              end
            end
            out.join("\n")
          end
        end
      end

      class Clip
        # A text view of this clip: :grid (rows of grid characters per
        # note), :roll (a piano roll), or :degrees (scale degrees in the
        # session key, or +scale:+), for reading music in the console.
        # Returns a Sequence::View (printed by Pry; #to_s for the text).
        #
        #     seq(A3, C4, E4, G4).n8.show            # grid
        #     riff.show(:roll)
        #     riff.show(:degrees, scale: scale(:minor, :a))
        def show(kind = :grid, step: nil, cycle: 0, scale: nil, width: View::WIDTH)
          View.of(self, kind, step: step, cycle: cycle, scale: scale, width: width)
        end
      end

      class Kit
        # A text view of the kit's rows in grid characters (:grid; :roll
        # adds a bar ruler); `grid(16, **beat.show.rows)` builds the rows
        # again.  See Clip#show and Sequence::View.
        #
        #     grid(16, kick: 'x...x...', hat: 'x.x.X.x.').show
        def show(kind = :grid, step: nil, cycle: 0, width: View::WIDTH)
          View.of(self, kind, step: step, cycle: cycle, width: width)
        end
      end
    end
  end
end

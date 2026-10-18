module MB
  module Sound
    module Help
      # The one-screen sheet (`help`): a command palette grouped by the way a set is
      # played.  Each line is a Ruby block that is never run here: its source
      # is what the sheet shows, and its first call names the method (the
      # guard spec checks every name exists, and runs the lines it can).
      class Sheet
        include Page
        include Text

        Line = Struct.new(:hint, :block) do
          def source = Text.block_body(block)

          # Every method the line calls (the guard spec checks they exist).
          def call_names
            names = []
            walk = ->(n) {
              return if n.nil?
              names << n.name if n.is_a?(Prism::CallNode)
              n.compact_child_nodes.each { |c| walk.(c) }
            }
            walk.(Prism.parse(source).value)
            names.uniq
          end
        end

        SHEET = {}

        # Sheet builder: `group :start do line('hint') { code } end`.
        class Builder
          def initialize(lines) = @lines = lines
          def line(hint = nil, &block) = @lines << Line.new(hint, block)
        end

        def self.group(name, &block)
          raise ArgumentError, "unknown group #{name} (#{GROUPS.keys.join(', ')})" unless GROUPS.key?(name)
          Builder.new(SHEET[name] ||= []).instance_eval(&block)
        end

        def initialize(index)
          @index = index
        end

        def to_s
          w = width
          cols = w >= 150 ? 3 : (w >= 100 ? 2 : 1)
          colw = (w - (cols - 1) * 2) / cols
          panels = GROUPS.map { |g, title| panel(title, SHEET[g] || [], colw) }
          # Fill columns in workflow order, breaking near an even height.
          total = panels.sum(&:length)
          columns = [[]]
          panels.each do |p|
            if columns.length < cols && !columns.last.empty? && columns.last.sum(&:length) + p.length / 2 > total.fdiv(cols)
              columns << []
            end
            columns.last << p
          end
          heights = columns.map { |col| col.sum(&:length) }
          lines = (0...heights.max).map { |i|
            columns.map.with_index { |col, ci|
              flat = col.flatten
              pad(flat[i] || '', colw)
            }.join('  ').rstrip
          }
          head = "#{c(:title, 'mb-sound')} #{c(:dim, '- the one-screen sheet; help :start etc. open a section')}"
          learn = "#{c(:head, 'Learn:')} #{c(:key, 'lesson')} #{LESSONS.keys.map { |l| c(:key, l.inspect) }.join(c(:dim, ', '))}  #{c(:dim, '(guided)')}"
          foot = Doc.new(width: w).commands([['More help', FOOTER]]).to_s
          all = [head, learn, ''] + lines + [foot]
          # Taller than the terminal (one column below 100): the top has
          # scrolled away, so the last line says so (ux-fix-1 item 16)
          total_lines = all.sum { |l| l.count("\n") + 1 }
          if total_lines + 1 > (MB::U.height rescue 24)
            sections = GROUPS.keys.first(3).map { |g| "help #{g.inspect}" }.join(', ')
            note = "(#{total_lines} lines: scroll up for the top, or open one section: #{sections}, ...)"
            all << '' << c(:dim, wrap(note, width: w))
          end
          all.join("\n")
        end

        # The sheet's footer: one command per line (ux-1 item 23; the
        # maintainer: "just a blur of words").
        FOOTER = [
          ['help :knobs', 'a topic (help.topics lists them)'],
          ['help :perform', 'a section of this sheet, in detail'],
          ['help :turn', 'a command or node method'],
          ['help /reson/', 'search names, topics, and docs'],
          ['help node', 'explain a graph'],
          ['now', "what's playing and what you can do"],
          ['lesson', 'guided lessons'],
          ['help.tip', 'a random example to play'],
          ['help.level', 'a comfortable listening level'],
          ['pry-help', "Pry's own help"],
        ].freeze

        private

        def panel(title, lines, colw)
          group = GROUPS.key(title)
          hint = " help :#{group} "
          rows = ["#{c(:head, title)}#{c(:dim, hint)}#{c(:dim, '─' * [colw - visible_length(title) - hint.length, 0].max)}"]
          lines.each do |l|
            src = l.source.gsub(/\s*\n\s*/, '; ')
            text = code(src)
            room = colw - 1 - visible_length(src)
            if l.hint && room >= l.hint.length + 2
              rows << " #{text}#{' ' * (room - l.hint.length)}#{c(:dim, l.hint)}"
            else
              rows << ' ' + text
              rows << "#{' ' * (colw - l.hint.length)}#{c(:dim, l.hint)}" if l.hint
            end
          end
          rows << ''
          rows
        end
      end
    end
  end
end

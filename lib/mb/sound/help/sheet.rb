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
          head = "#{c(:title, 'mb-sound')} #{c(:dim, '- the one-screen sheet')}"
          foot = pack([
            "#{code('help :knobs')} topic", "#{code('help :turn')} method", "#{code('help /reson/')} search",
            "#{code('help node')} explain a graph", "#{code('help.topics')}", "#{code('now')} what's playing",
            "#{code('lesson')} lessons", "#{code('help.tip')}", "#{code('help.level')} example level",
            c(:dim, "Pry's own help: pry-help"),
          ], w)
          ([head] + lines + [''] + foot).join("\n")
        end

        private

        # Joins +items+ with two spaces into lines no wider than +w+.
        def pack(items, w)
          items.each_with_object([+'']) { |item, lines|
            if !lines.last.empty? && visible_length(lines.last) + 2 + visible_length(item) > w
              lines << item.dup
            else
              lines.last << (lines.last.empty? ? '' : '  ') << item
            end
          }
        end

        def panel(title, lines, colw)
          rows = ["#{c(:head, title)} #{c(:dim, '─' * [colw - visible_length(title) - 1, 0].max)}"]
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

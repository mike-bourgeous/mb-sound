module MB
  module Sound
    module Help
      # The one formatter for help pages (ux-1 item 22; maintainer: "`help
      # :ui` (just as an example) is a solid wall of text; need some gaps
      # and formatting"): a page is built from blocks (a title, headings,
      # paragraphs, rows of command and description, code, dim notes) and
      # rendered with a blank line between blocks, at most Text.width
      # columns (100 at most), headings bold, commands in the key color,
      # descriptions plain, code indented and highlighted.  A paragraph
      # that would wrap to more than PARAGRAPH_LINES lines is split at a
      # sentence near its middle, and rows come in groups of at most
      # ROW_GROUP, so no page runs more than about 8 lines without a gap
      # (the help spec checks every page).  Pages print plain under
      # NO_COLOR or when the output isn't a terminal (Help.for_output).
      #
      #     d = Doc.new
      #     d.title 'Knobs', 'help :knobs'
      #     d.para 'Knobs are named values ...'
      #     d.heading 'Commands'
      #     d.rows [['turn', 'Moves a knob']]
      #     d.code_block "knob :cut, 800"
      #     d.to_s
      class Doc
        include Text

        # Wrapped lines a paragraph may take before it is split.
        PARAGRAPH_LINES = 6

        # Rows in a group (a blank line between groups).
        ROW_GROUP = 8

        def initialize(width: Text.width)
          @width = width
          @blocks = []
        end

        attr_reader :width

        # The page's title (bold) and a dim hint after it (how to get here).
        def title(text, hint = nil)
          @blocks << [["#{c(:title, text)}#{hint ? "  #{c(:dim, hint)}" : ''}"], nil]
          self
        end

        # A section heading (bold, a blank line before it).
        def heading(text)
          @blocks << [[c(:head, text)], :heading]
          self
        end

        # Prose with doc markup (+name+ and `code`), wrapped; blank lines
        # in +text+ separate paragraphs; long ones are split.
        def para(text, indent: 0, dim: false)
          text.to_s.split(/\n\s*\n/).each do |p|
            p = p.gsub(/\s+/, ' ').strip
            next if p.empty?
            split_long(p, indent).each do |lines|
              lines = lines.map { |l| c(:dim, MB::U.remove_ansi(l)) } if dim
              @blocks << [lines, nil]
            end
          end
          self
        end

        # Rows of [label, description]: labels in the key color (or as
        # given if already colored), aligned; descriptions with doc markup,
        # cut to the width (+dim+: descriptions dimmer than the commands,
        # as the welcome screen and the sheet's footer list them).
        def rows(pairs, indent: 2, max_label: 30, wrap: false, dim: false)
          return self if pairs.empty?
          left = [pairs.map { |l, _| visible_length(label_text(l)) }.max.to_i, max_label].min
          room = @width - indent - left - 2
          entries = pairs.map do |label, text|
            l = label_text(label)
            t = text.to_s
            if wrap
              # Long descriptions continue under themselves (+wrap+)
              parts = Text.wrap(MB::U.remove_ansi(t), width: room).lines.map(&:chomp)
              ["#{' ' * indent}#{pad(l, left)}  #{doc(parts.first.to_s)}".rstrip] +
                parts.drop(1).map { |more| "#{' ' * (indent + left + 2)}#{c(:dim, more)}" }
            else
              t = "#{t[0, [room - 3, 0].max]}..." if visible_length(t) > room
              ["#{' ' * indent}#{pad(l, left)}  #{dim ? c(:dim, t) : doc(t)}".rstrip]
            end
          end
          # Even groups of at most ROW_GROUP lines (10 rows: 5 and 5, not
          # 8 and 2), never splitting a wrapped row
          total = entries.sum(&:length)
          size = (total.to_f / (total.to_f / ROW_GROUP).ceil).ceil
          group = []
          entries.each do |e|
            if !group.empty? && group.length + e.length > size
              @blocks << [group, nil]
              group = []
            end
            group.concat(e)
          end
          @blocks << [group, nil] unless group.empty?
          self
        end

        # Groups of commands under headings ([heading, [[command,
        # description], ...]], ...): one command per line in the command
        # color, descriptions dim and aligned in one column across every
        # group.  The welcome screen and the sheet's footer both list
        # commands this way (ux-1 r3 item 1), so they can't drift apart.
        def commands(groups, indent: 2)
          left = groups.flat_map { |_, pairs| pairs.map { |cmd, _| cmd.length } }.max.to_i
          groups.each do |head, pairs|
            heading(head) if head
            rows(pairs.map { |cmd, what| [Text.code(cmd).then { |t| Text.pad(t, left) }, what] }, indent: indent, max_label: left, dim: true)
          end
          self
        end

        # Code lines (a String or Array), indented and highlighted.
        def code_block(text, indent: 4)
          lines = text.is_a?(Array) ? text : text.to_s.lines.map(&:chomp)
          @blocks << [lines.map { |l| "#{' ' * indent}#{Text.code(l)}" }, nil]
          self
        end

        # Lines as given (already formatted), as one block.
        def lines(list)
          list = Array(list)
          @blocks << [list, nil] unless list.empty?
          self
        end

        # A dim note, wrapped.
        def note(text) = para(text, dim: true)

        def to_s
          out = []
          @blocks.each do |block, kind|
            # A heading sits right above its first block
            out << '' unless out.empty? || (out.last == :heading_pending)
            out.pop if out.last == :heading_pending
            if kind == :heading
              out.concat(block)
              out << :heading_pending
            else
              out.concat(block)
            end
          end
          out.reject { |l| l == :heading_pending }.join("\n")
        end

        private

        def label_text(l)
          s = l.to_s
          s.include?("\e[") ? s : c(:key, s)
        end

        # Wraps with code spans held whole, then colors the markup.
        def wrap_held(p, indent)
          held = p.gsub(/`[^`\n]+`/) { |code| code.tr(' ', " ") }
          Text.wrap(held, indent: indent, width: @width).lines.map { |l| doc(l.chomp.tr("\u00A0", " ")) }
        end

        # Wraps paragraph +p+ (source text with markup); if it takes more
        # than PARAGRAPH_LINES lines, splits it at the sentence end nearest
        # its middle and wraps each half.  Returns the blocks of lines.
        def split_long(p, indent)
          lines = wrap_held(p, indent)
          return [lines] if lines.length <= PARAGRAPH_LINES
          ends = p.enum_for(:scan, /[.!?]\)?\s+(?=[A-Z`(+])/).map { Regexp.last_match.end(0) }
          ends.reject! { |e| p[0...e].count('`').odd? } # (not inside a code span)
          return [lines] if ends.empty?
          at = ends.min_by { |e| (e - p.length / 2).abs }
          split_long(p[0...at].strip, indent) + split_long(p[at..].strip, indent)
        end
      end

      # +text+ as it should print to +io+: plain under NO_COLOR, TERM=dumb,
      # or when +io+ isn't a terminal (see ColorPolicy).
      def self.for_output(text, io = $stdout)
        ColorPolicy.color?(io) ? text : MB::U.remove_ansi(text)
      end
    end
  end
end

require 'prism'

module MB
  module Sound
    module Help
      # Small text helpers shared by the help designs (colors, code
      # highlighting, wrapping, block source).
      module Text
        module_function

        COLORS = {
          title: "\e[1;33m", head: "\e[1;36m", code: "\e[0m", dim: "\e[2m", key: "\e[1;32m",
          warn: "\e[1;31m", ok: "\e[32m", bar: "\e[36m", name: "\e[1;35m", reset: "\e[0m",
        }.freeze

        def c(kind, text) = "#{COLORS.fetch(kind)}#{text}#{COLORS[:reset]}"

        def code(text) = MB::U.syntax(text.to_s).chomp

        # Columns pages use: the terminal's, from 60 to 100 (longer lines
        # read badly).
        def width = [[MB::U.width, 40].max, 100].min

        def wrap(text, indent: 0, width: self.width)
          MB::U.wrap(text.to_s.gsub(/\s+/, ' ').strip, width: width - indent).lines.map { |l| (' ' * indent) + l.rstrip }.join("\n")
        end

        def visible_length(s) = MB::U.remove_ansi(s.to_s).length

        def pad(s, n) = s + (' ' * [n - visible_length(s), 0].max)

        # Doc comment markup to terminal text: +name+ and `code` get colors.
        def doc(text)
          text.to_s
            .gsub(/\+([\w:.?!]+)\+/) { c(:key, $1) }
            .gsub(/`([^`\n]+)`/) { code($1) }
        end

        # The source text of a block's body, found with Prism from the file
        # and line where the block was written (real Ruby, not a string).
        def block_body(block)
          file, line = block.source_location
          @trees ||= {}
          tree = (@trees[file] ||= Prism.parse_file(file).value)
          found = nil
          walk = ->(node) {
            return if found || node.nil?
            if node.is_a?(Prism::BlockNode) && node.location.start_line == line
              found = node
              return
            end
            node.compact_child_nodes.each { |n| walk.(n) }
          }
          walk.(tree)
          return '' unless found&.body

          body = found.body.slice
          first_col = found.body.location.start_column
          lines = body.lines
          lines = [lines.first] + lines.drop(1).map { |l| l.sub(/^ {0,#{first_col}}/, '') }
          lines.join.rstrip
        end
      end
    end
  end
end

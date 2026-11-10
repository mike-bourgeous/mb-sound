module MB
  module Sound
    module Help
      # The user guide (docs/guide/*.md, shipped with mb-sound): chapters
      # for musicians who code, read in an editor, on the web, or in the
      # console with `guide` (the chapter list) and `guide :drums` (a
      # chapter as a help page).  The guide spec
      # (spec/lib/mb/sound/help/guide_spec.rb) runs every Ruby example of
      # every chapter in order, as typed into one console, and checks its
      # level like the help topics' examples.
      #
      # A chapter is a Markdown file named NN-name.md: a "# Title" line,
      # a one-paragraph summary, then sections.  An HTML comment right
      # before a fenced block says how the spec runs it:
      #
      #     <!-- check: bars=4 -->      plays 4 bars after it (default 2)
      #     <!-- check: quiet -->       runs it, no level check (prints, stops)
      #     <!-- check: script -->      a whole song file: run as a program
      #                                 with -o (a render), its file checked
      #     <!-- check: program -->     a whole file run as a program that
      #                                 plays (silently) and ends by itself
      #     <!-- check: skip why -->    shown only (needs a keyboard, ...)
      #
      # Only ```ruby blocks run; ```sh and ```text blocks are shown only.
      module Guide
        # One fenced code block of a chapter: its language, code, the line
        # its code starts on, and the check comment's words.
        Example = Struct.new(:language, :code, :line, :check, keyword_init: true) do
          def ruby? = language == 'ruby'
          def run? = ruby? && !check.key?(:skip)
          def script? = check.key?(:script)
          def program? = check.key?(:program)
          def sound? = !check.key?(:quiet) && !script? && !program?
          def bars = Integer(check.fetch(:bars, 2))
        end

        # One chapter file.
        class Chapter
          attr_reader :path, :number, :name, :title, :summary

          def initialize(path)
            @path = path
            base = File.basename(path, '.md')
            @number = base[/\A\d+/].to_i
            @name = base.sub(/\A\d+-/, '').tr('-', '_').to_sym
            @title = text[/^# (.+)$/, 1].to_s.strip.sub(/\A\d+\.\s*/, '')
            @summary = text.split(/\n\s*\n/).map(&:strip).find { |p| !p.empty? && !p.start_with?('#', '<!--') }.to_s.gsub(/\s+/, ' ')
          end

          def text = @text ||= File.read(@path)

          # The fenced code blocks, in order.
          def examples
            @examples ||= begin
              list = []
              check = nil
              lines = text.lines
              i = 0
              while i < lines.length
                l = lines[i]
                if (m = l.match(/\A<!--\s*check:\s*(.*?)\s*-->/))
                  check = Guide.parse_check(m[1])
                elsif (m = l.match(/\A```(\w*)\s*\z/))
                  start = i + 1
                  body = []
                  i += 1
                  while i < lines.length && !lines[i].start_with?('```')
                    body << lines[i]
                    i += 1
                  end
                  list << Example.new(language: m[1], code: body.join, line: start + 1, check: check || {})
                  check = nil
                elsif !l.strip.empty?
                  check = nil
                end
                i += 1
              end
              list
            end
          end
        end

        # The guide's folder (docs/guide in mb-sound).
        def self.dir = File.expand_path('../../../../docs/guide', __dir__)

        # The chapters, in order.
        def self.chapters
          Dir[File.join(dir, '[0-9]*.md')].sort.map { |p| Chapter.new(p) }
        end

        # The chapter named, numbered, or starting with +which+ (a Symbol,
        # String, or Integer); raises ArgumentError listing the chapters.
        def self.chapter(which)
          list = chapters
          found =
            if which.is_a?(Integer)
              list.find { |c| c.number == which }
            else
              w = which.to_s.downcase.tr('-', '_')
              list.find { |c| c.name.to_s == w } || list.select { |c| c.name.to_s.start_with?(w) }.then { |m| m.length == 1 ? m[0] : nil } ||
                list.select { |c| c.name.to_s.include?(w) }.then { |m| m.length == 1 ? m[0] : nil }
            end
          return found if found

          names = list.map { |c| c.name.inspect }
          near = DidYouMean::SpellChecker.new(dictionary: list.map { |c| c.name.to_s }).correct(which.to_s)
          hint = near.empty? ? '' : " (did you mean #{near.map { |n| ":#{n}" }.join(', ')}?)"
          raise ArgumentError, "No guide chapter #{which.inspect}#{hint}; chapters: #{names.join(' ')}"
        end

        # "bars=4 quiet skip needs a keyboard" to { bars: '4', quiet: true, skip: 'needs a keyboard' }.
        def self.parse_check(words)
          out = {}
          rest = words.split
          while (w = rest.shift)
            k, v = w.split('=', 2)
            if k == 'skip'
              out[:skip] = rest.join(' ')
              break
            end
            out[k.to_sym] = v || true
          end
          out
        end
      end

      # What `guide` returns without a chapter: the chapters, one line each.
      class GuidePage
        include Page
        include Text

        def title = 'guide'

        def to_s
          d = Doc.new
          d.title('The mb-sound guide', 'guide :name (or a number) reads a chapter')
          d.para('Chapters for musicians who code, from a first sound to a live set and a finished render.  Read them here, or as Markdown files in an editor:')
          d.lines(["    #{Guide.dir}"])
          d.rows(Guide.chapters.map { |c| ["#{c.number}  #{c.name.inspect}", c.title] }, max_label: 24)
          d.note('help shows the one-screen sheet of commands; help :topic has details and examples to try; lesson runs guided lessons.')
          d.to_s
        end
      end

      # One chapter of the guide as a help page (`guide :drums`): Markdown
      # shown as text (headings, paragraphs, lists, code), the check
      # comments left out.
      class GuideChapterPage
        include Page
        include Text

        attr_reader :chapter

        def initialize(chapter) = @chapter = chapter

        def title = "guide #{@chapter.name}"

        def to_s
          d = Doc.new
          blocks(@chapter.text).each do |kind, value|
            case kind
            when :title then d.title(value, "guide :#{@chapter.name}")
            when :heading then d.heading(value)
            when :para then d.para(inline(value))
            when :list then d.lines(value.flat_map { |item| list_item(inline(item), d.width) })
            when :code then d.code_block(value)
            end
          end
          d.note("Next: guide #{next_chapter.name.inspect} (#{next_chapter.title})") if next_chapter
          d.to_s
        end

        private

        def next_chapter
          list = Guide.chapters
          list[list.index { |c| c.name == @chapter.name }.to_i + 1]
        end

        # The Markdown as [kind, value] blocks.
        def blocks(text)
          out = []
          lines = text.gsub(/<!--.*?-->\n?/m, '').lines.map(&:chomp)
          para = []
          list = nil
          flush = -> {
            out << [:para, para.join(' ')] unless para.empty?
            out << [:list, list] if list
            para = []
            list = nil
          }
          i = 0
          while i < lines.length
            l = lines[i]
            if l.start_with?('```')
              flush.()
              code = []
              i += 1
              while i < lines.length && !lines[i].start_with?('```')
                code << lines[i]
                i += 1
              end
              out << [:code, code]
            elsif (m = l.match(/\A(#+)\s+(.*)/))
              flush.()
              out << [m[1].length == 1 ? :title : :heading, m[2].strip]
            elsif (m = l.match(/\A\s*[-*]\s+(.*)/))
              out << [:para, para.join(' ')] unless para.empty?
              para = []
              (list ||= []) << m[1]
            elsif l.strip.empty?
              flush.()
            elsif list
              list[-1] = "#{list[-1]} #{l.strip}"
            else
              para << l.strip
            end
            i += 1
          end
          flush.()
          out
        end

        # Links and emphasis as plain text: a link to another chapter reads
        # `guide :name`, others show their address.
        def inline(text)
          text
            .gsub(/\[([^\]]+)\]\((\d+-[\w-]+)\.md(#[\w-]*)?\)/) { "#{$1} (`guide :#{$2.sub(/\A\d+-/, '').tr('-', '_')}`)" }
            .gsub(/\[([^\]]+)\]\(([^)]+)\)/) { "#{$1} (#{$2})" }
            .gsub(/\*\*([^*]+)\*\*/, '\1')
        end

        # A list item wrapped with a hanging indent.
        def list_item(text, width)
          held = text.gsub(/`[^`\n]+`/) { |code| code.tr(' ', " ") }
          lines = Text.wrap(held, indent: 4, width: width).lines.map(&:chomp)
          lines[0] = "  - #{lines[0].lstrip}"
          lines.map { |l| doc(l.tr(" ", ' ')) }
        end
      end
    end
  end
end

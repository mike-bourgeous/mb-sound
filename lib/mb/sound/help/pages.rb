module MB
  module Sound
    module Help
      # Shared printing for help pages: Pry shows the page's text instead of
      # an object dump, and pages stay values (`t = help :knobs; t.try`).
      module Page
        def inspect = to_s
        def pretty_print(q) = q.text(to_s)
      end

      # What `help` returns: the one-screen sheet (Sheet) when printed, and
      # the way into the rest: topic names as methods (`help.knobs`, so a
      # typo gets did_you_mean), `help.topics`, `help.tip`, `help.level`.
      # `help :knobs` is a topic page, `help :turn` a method page, `help
      # /reson/` a search, `help node` explains a graph (see Help.page_for).
      class Desk
        include Page

        def initialize(index)
          @index = index
          TOPICS.each_key do |name|
            define_singleton_method(name) { Help.topic_page(name) }
          end
        end

        # The topics by group, one line each.
        def topics = TopicList.new

        # A random runnable example from any topic (the welcome screen shows
        # one): its code and how to play it; `help.tip.try` plays it.
        def tip(random: Random.new)
          topic = TOPICS.values.reject { |t| t.examples.empty? }.sample(random: random)
          Tip.new(topic, random.rand(topic.examples.length))
        end

        # The listening level for examples (see Help::Level): with a number,
        # sets it (dBFS at the output); without, runs the level check when
        # the console is interactive (keys move the level), else shows it.
        def level(db = nil, input: $stdin, out: $stdout)
          if db
            Level.save(db)
          elsif input.tty?
            Level::Calibration.new(input: input, out: out).run
          end
          LevelPage.new
        end

        # The lessons (see #lesson in the console).
        def lessons = LessonList.new

        def to_s = Sheet.new(@index).to_s
      end

      # One example from a topic (Desk#tip).
      Tip = Struct.new(:topic, :i) do
        include Page

        def example = topic.examples[i]

        def try(**opts) = Try.run(example, **opts)

        def to_s
          [
            "#{Text.c(:title, 'tip')} #{Text.c(:dim, "#{topic.title}: #{example.title}")}",
            example.source.lines.map { |l| '  ' + Text.code(l.chomp) }.join("\n"),
            Text.c(:dim, "  play it: help(:#{topic.name}).try#{i.zero? ? '' : "(#{i + 1})"}   more: help :#{topic.name}"),
          ].join("\n")
        end
      end

      # The listening level (Desk#level).
      class LevelPage
        include Page
        include Text

        def db = Level.db

        def to_s
          if Level.saved?
            "#{c(:title, 'level')} examples play at #{c(:key, "#{Level.db.round(1)} dBFS")} peak, " \
              "#{format('%+.1f', Level.db - Level::REFERENCE_DB)} dB from the reference\n" \
              "#{c(:dim, '  help.level checks it again; help.level -20 sets it')}"
          else
            "#{c(:title, 'level')} no level check yet: examples play at the #{Level::REFERENCE_DB.round} dBFS reference\n" \
              "#{c(:dim, '  help.level runs the check (keys move the level); help.level -20 sets it')}"
          end
        end
      end

      # The topics by group (`help.topics`).
      class TopicList
        include Page
        include Text

        def to_s
          out = ["#{c(:title, 'topics')}  #{c(:dim, 'help :name, or help.name')}"]
          GROUPS.each do |g, title|
            list = TOPICS.values.select { |t| t.group == g }
            next if list.empty?
            out << c(:head, title)
            list.each do |t|
              ex = t.examples.empty? ? '' : c(:dim, " (#{t.examples.length} to try)")
              out << "  #{pad(c(:key, t.name.inspect), 14)} #{t.title}#{ex}"
            end
          end
          out.join("\n")
        end
      end

      # One topic (`help :knobs`), generated from the topic table (names and
      # examples) and the doc comments (one line per name).
      class TopicPage
        include Page
        include Text

        attr_reader :topic

        def initialize(topic, index)
          @topic = topic
          @index = index
        end

        def examples = @topic.examples

        # Runs example +n+ (1-based) through the background Session at the
        # listening level (see Help::Try): shows the code, runs it as if
        # typed, and stops the players it started after the example's bars.
        def try(n = 1, **opts)
          raise ArgumentError, "#{@topic.name} has no examples" if @topic.examples.empty?
          ex = (n.between?(1, @topic.examples.length) && @topic.examples[n - 1]) or
            raise ArgumentError, "#{@topic.name} has #{@topic.examples.length} examples (1..#{@topic.examples.length})"
          Try.run(ex, **opts)
        end

        def to_s
          w = width
          out = []
          out << "#{c(:title, @topic.title)}  #{c(:dim, "help :#{@topic.name}")}"
          out << wrap(doc_plain(@topic.about), width: w).then { |s| doc(s) }
          out << ''
          names = @topic.commands.map { |n| [n, :console] } + @topic.dsl.map { |n| [n, :dsl] }
          rows = names.map { |n, kind|
            e = (kind == :console ? @index.console_methods : @index.dsl_methods).find { |x| x.name == n && !x.alias? } ||
              @index.find(n)
            next [c(:warn, n.to_s), c(:warn, '(no such method: stale help entry)')] unless e

            aliases = aliases_of(e)
            label = (kind == :dsl ? ".#{n}" : n.to_s) + (aliases.empty? ? '' : c(:dim, " (#{aliases.join(', ')})"))
            [c(:key, label), e.summary]
          }
          left = [rows.map { |l, _| visible_length(l) }.max.to_i, 34].min
          rows.each do |label, text|
            room = w - left - 4
            text = text.length > room ? text[0, room - 3] + '...' : text
            out << "  #{pad(label, left)}  #{doc(text)}"
          end
          unless @topic.examples.empty?
            out << ''
            @topic.examples.each_with_index do |ex, i|
              out << "#{c(:head, "try #{i + 1}")} #{ex.title}  #{c(:dim, "help(:#{@topic.name}).try(#{i + 1})")}"
              out << ex.source.lines.map { |l| "    #{code(l.chomp)}" }.join("\n")
            end
          end
          more = []
          more << "see #{@topic.see.map { |s| "help :#{s}" }.join(', ')}" unless @topic.see.empty?
          more << "notes: #{@topic.notes.map { |n| "design/notes/#{n}.md" }.join(', ')}" unless @topic.notes.empty?
          unless more.empty?
            out << ''
            out << wrap(more.join('; '), width: w).lines.map { |l| c(:dim, l.chomp) }.join("\n")
          end
          out.join("\n")
        end

        private

        def doc_plain(s) = s

        def aliases_of(e)
          (e.owner.public_instance_methods(false) - [e.name]).select { |m|
            e.owner.instance_method(m).original_name == e.name
          }.sort
        end
      end

      # One method (`help :turn`) (console command and/or node method), with
      # its signature, aliases, full doc comment, and the topics listing it.
      class MethodPage
        include Page
        include Text

        def initialize(entries, index)
          @entries = entries
          @index = index
        end

        def to_s
          out = []
          @entries.each do |e|
            real = e.alias? ? @index.find_all(e.original).find { |x| x.owner == e.owner } || e : e
            where = real.surface == 'console' ? 'console' : "#{real.surface == 'GraphNode DSL' ? 'node' : real.surface} method"
            out << "#{c(:title, real.signature)}  #{c(:dim, "#{where}, #{real.owner.name.sub('MB::Sound::', '')}")}"
            out << c(:dim, "#{e.name} is an alias of #{e.original}") if e.alias?
            text = real.comment.strip
            text = '(no doc comment)' if text.empty?
            out << rewrap(text).lines.map { |l| '  ' + doc(l.chomp) }.join("\n")
            file, line = real.location
            out << c(:dim, "  #{file.sub(%r{.*/lib/}, 'lib/')}:#{line}") if file
            out << ''
          end
          topics = TOPICS.values.select { |t| @entries.any? { |e| t.commands.include?(e.name) || t.dsl.include?(e.name) || (e.original && (t.commands + t.dsl).include?(e.original)) } }
          out << c(:dim, "topics: #{topics.map { |t| "help :#{t.name}" }.join(', ')}") unless topics.empty?
          out.join("\n").rstrip
        end
      end

      # Rewraps doc comment paragraphs to the terminal, keeping indented
      # code and list items as written.
      module Rewrap
        def rewrap(text)
          blocks = []
          text.each_line do |l|
            if l.strip.empty? then blocks << :blank
            elsif l =~ /^( {2,}|[-*] )/ || blocks.last.is_a?(Array) && blocks.last.first == :keep && l =~ /^ /
              blocks << [:keep, l.chomp]
            elsif blocks.last.is_a?(String) then blocks.last << ' ' << l.strip
            else blocks << l.strip.dup
            end
          end
          blocks.map { |b|
            case b
            when :blank then ''
            when Array then b.last
            else Text.wrap(b, indent: 0, width: Text.width - 2)
            end
          }.join("\n")
        end
      end
      MethodPage.include(Rewrap)

      # Search results (`help /reson/`) for a Regexp over names and doc comments.
      class SearchPage
        include Page
        include Text

        def initialize(pattern, index)
          @pattern = pattern
          @index = index
        end

        def hits
          (@index.console_methods + @index.dsl_methods).reject(&:alias?).select { |e|
            e.name.to_s.match?(@pattern) || e.comment.match?(@pattern)
          }.uniq { |e| [e.owner, e.name] }
        end

        def to_s
          h = hits
          by_name = h.select { |e| e.name.to_s.match?(@pattern) }
          by_doc = h - by_name
          out = ["#{c(:title, "help #{@pattern.inspect}")}  #{c(:dim, "#{h.length} matches")}"]
          [['names', by_name], ['mentioned in docs', by_doc]].each do |label, list|
            next if list.empty?
            out << c(:head, label)
            list.first(24).each do |e|
              where = e.surface == 'console' ? '' : (e.surface == 'GraphNode DSL' ? 'node.' : "#{e.surface.split('::').last}#")
              out << "  #{pad(c(:key, where + e.name.to_s), 26)} #{e.summary[0, width - 30]}"
            end
            out << c(:dim, "  ... #{list.length - 24} more") if list.length > 24
          end
          out.join("\n")
        end
      end
    end
  end
end

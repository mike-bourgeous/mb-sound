module MB
  module Sound
    module Help
      # Shared printing for help pages: Pry shows the page's text instead of
      # an object dump, and pages stay values (`t = help :knobs; t.try`).
      #
      # Every page's #to_s is plain text when $stdout may not be colored
      # (a pipe, a log, NO_COLOR, TERM=dumb; see ColorPolicy), so `puts
      # help(:turn)` and `now.to_s` read cleanly in captured output.
      module Page
        # The page's name for the tiled screen's page pane title ("HELP ·
        # knobs"), or nil (the sheet: plain "HELP"; see UI::Tiles#page).
        def title = nil

        # Prepended to each class that includes Page.
        module PlainOutput
          def to_s = ColorPolicy.for_output(super)
        end

        def self.included(base)
          base.prepend(PlainOutput)
        end

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
          GROUPS.each_key do |name|
            define_singleton_method(name) { SectionPage.new(name, @index) } unless TOPICS.key?(name)
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

        # The listening level (see Help::Level), which sets the monitor
        # trim for live playback: with a level, sets it (the level check
        # tone's peak, `help.level -20.db`; a bare negative number is read
        # as dB with a warning in the console, see Decibels.db_of); without, runs the level check when the console
        # is interactive (keys move the level), else shows it.
        def level(db = nil, input: $stdin, out: $stdout)
          if db
            Level.save(Decibels.db_of(db, 'level'))
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

        def title = 'level'

        def db = Level.db

        def to_s
          trim = format('%+.1f dB', 20 * Math.log10([Session.monitor_gain, 1e-9].max))
          if Level.saved?
            "#{c(:title, 'level')} #{c(:key, "#{Level.db.round(1)} dBFS")} (the level check tone's peak): monitor trim #{trim} for live playback\n" \
              "#{c(:dim, '  renders and recordings are unchanged; help.level checks it again, help.level -20.db sets it')}"
          else
            "#{c(:title, 'level')} no level check yet (monitor trim #{trim}; the tone's reference is #{Level::REFERENCE_DB.round} dBFS)\n" \
              "#{c(:dim, '  help.level runs the check (keys move the level); help.level -20.db sets it')}"
          end
        end
      end

      # The topics by group (`help.topics`).
      class TopicList
        include Page
        include Text

        def title = 'topics'

        def to_s
          d = Doc.new
          d.title('topics', 'help :name, or help.name; help :start (a section) for more on each group')
          GROUPS.each do |g, title|
            list = TOPICS.values.select { |t| t.group == g }
            next if list.empty?
            d.heading("#{title}  #{c(:dim, "help :#{g}")}")
            d.rows(list.map { |t| [t.name.inspect, "#{t.title}#{t.examples.empty? ? '' : c(:dim, " (#{t.examples.length} to try)")}"] })
          end
          d.to_s
        end
      end

      # One topic (`help :knobs`), generated from the topic table (names and
      # examples) and the doc comments (one line per name).
      class TopicPage
        include Page
        include Text

        def title = @topic.name.to_s

        attr_reader :topic

        def initialize(topic, index)
          @topic = topic
          @index = index
        end

        def examples = @topic.examples

        # Runs example +n+ (1-based) through the background Session (see
        # Help::Try): shows the code, runs it as if typed, and stops the
        # players it started after the example's bars.
        def try(n = 1, **opts)
          raise ArgumentError, "#{@topic.name} has no examples" if @topic.examples.empty?
          ex = (n.between?(1, @topic.examples.length) && @topic.examples[n - 1]) or
            raise ArgumentError, "#{@topic.name} has #{@topic.examples.length} examples (1..#{@topic.examples.length})"
          Try.run(ex, **opts)
        end

        def to_s
          d = Doc.new
          d.title(@topic.title, "help :#{@topic.name}")
          d.para(@topic.about)
          names = @topic.commands.map { |n| [n, :console] } + @topic.dsl.map { |n| [n, :dsl] }
          rows = names.map { |n, kind|
            e = (kind == :console ? @index.console_methods : @index.dsl_methods).find { |x| x.name == n && !x.alias? } ||
              @index.find(n)
            next [c(:warn, n.to_s), c(:warn, '(no such method: stale help entry)')] unless e

            aliases = aliases_of(e)
            label = c(:key, kind == :dsl ? ".#{n}" : n.to_s) + (aliases.empty? ? '' : c(:dim, " (#{aliases.join(', ')})"))
            [label, e.summary]
          }
          console, dsl = rows.partition.with_index { |_, i| names[i][1] == :console }
          d.heading('Commands').rows(console) unless console.empty?
          d.heading('Node and value methods').rows(dsl) unless dsl.empty?
          extra_sections(d)
          # (its aliases' too: help note is the pitch topic, and ui.note's
          # entry shows there)
          names = [@topic.name, *TOPIC_ALIASES.select { |_, t| t == @topic.name }.keys]
          Help.ui_section(d, names.flat_map { |n| UI::HelpIndex.named(n) }.uniq)
          unless @topic.examples.empty?
            d.heading('Examples')
            @topic.examples.each_with_index do |ex, i|
              d.lines(["  #{c(:key, "try #{i + 1}")}  #{ex.title}  #{c(:dim, "help(:#{@topic.name}).try(#{i + 1})")}"])
              d.code_block(ex.source)
            end
          end
          more = []
          more << "See also: #{@topic.see.map { |s| "help :#{s}" }.join(', ')}." unless @topic.see.empty?
          more << "Design notes: #{@topic.notes.map { |n| "design/notes/#{n}.md" }.join(', ')}." unless @topic.notes.empty?
          d.note(more.join(' ')) unless more.empty?
          d.to_s
        end

        # More sections between the commands and the examples (subclasses
        # and topics with generated tables add them).
        def extra_sections(d)
          @topic.sections.each { |s| s.call(d) } if @topic.respond_to?(:sections)
        end

        private

        def aliases_of(e)
          (e.owner.public_instance_methods(false) - [e.name]).select { |m|
            e.owner.instance_method(m).original_name == e.name
          }.sort
        end
      end

      # A section of the sheet in detail (`help :perform`, ux-1 item 24;
      # maintainer: "way more detail"): what the section is for, its sheet
      # lines, every topic in it (its title, first sentence, main commands,
      # first example), the lessons and demo scripts that use it, and
      # commands from its sheet lines that no topic of it lists.
      class SectionPage
        include Page

        def title = @group.to_s
        include Text

        attr_reader :group

        def initialize(group, index)
          @group = group
          @index = index
        end

        def topics = TOPICS.values.select { |t| t.group == @group }

        def to_s
          d = Doc.new
          d.title(GROUPS.fetch(@group), "help :#{@group}  (a section of the sheet: help)")
          d.para(SECTIONS[@group]) if SECTIONS[@group]
          lines = Sheet::SHEET[@group] || []
          unless lines.empty?
            d.heading('On the sheet')
            d.rows(lines.map { |l| [code(l.source.gsub(/\s*\n\s*/, '; ')), l.hint.to_s] }, max_label: 60)
          end
          topics.each do |t|
            d.heading("#{t.title}  #{c(:dim, "help :#{t.name}")}")
            first = t.about.split(/(?<=[.!?])\s+(?=[A-Z`(])/).first.to_s
            d.para(first, indent: 2)
            main = t.commands.first(6).map { |n| c(:key, n.to_s) } + t.dsl.first(6).map { |n| c(:key, ".#{n}") }
            d.lines(["  #{main.join(c(:dim, ', '))}"]) unless main.empty?
            ex = t.examples.first
            if ex
              d.lines(["  #{c(:dim, "try: #{ex.title}  help(:#{t.name}).try")}"])
              d.code_block(ex.source)
            end
          end
          learn = lessons
          demos = demo_scripts
          unless learn.empty? && demos.empty?
            d.heading('Learn and listen')
            d.rows(learn.map { |name, title| ["lesson #{name.inspect}", title] } + demos.map { |path| [path, 'a demo script'] }, max_label: 40)
          end
          rest = leftovers
          d.heading('Also on the sheet').rows(rest.map { |n, summary| [n.to_s, summary] }) unless rest.empty?
          Help.ui_section(d, UI::HelpIndex.named(@group))
          d.to_s
        end

        # Lessons whose steps call a command of this section's topics:
        # [[name, title], ...].
        def lessons
          names = topics.flat_map(&:names)
          LESSONS.each_value.select { |l| l.steps.any? { |st| st.code && (Lesson.call_names(st.source) & names).any? } }.map { |l| [l.name, l.title] }
        end

        # Demo scripts the section's topics mention (bin/...rb).
        def demo_scripts
          topics.flat_map { |t| t.about.scan(%r{bin/[\w/]+\.rb}) }.uniq
        end

        # Sheet commands of this section no topic of it lists:
        # [[name, summary], ...].
        def leftovers
          listed = topics.flat_map(&:names)
          calls = (Sheet::SHEET[@group] || []).flat_map(&:call_names).uniq - listed
          calls.filter_map do |n|
            e = @index.console_methods.find { |x| x.name == n }
            [n, e.summary] if e
          end
        end
      end

      # One method (`help :turn`) (console command and/or node method), with
      # its signature, aliases, full doc comment, and the topics listing it.
      class MethodPage
        include Page

        def title = @entries.map { |e| e.respond_to?(:name) ? e.name.to_s : e.to_s }.uniq.first(2).join(', ').then { |t| t.empty? ? nil : t }
        include Text

        def initialize(entries, index)
          @entries = entries
          @index = index
        end

        # Other public names of +entry+'s method in its owner.
        def method_aliases(entry)
          owner = entry.owner
          own = ->(name) {
            m = owner.instance_method(name)
            m = m.super_method while m && m.owner != owner # (past the recorders prepended to the DSL)
            m&.original_name
          }
          target = own.(entry.name)
          (owner.public_instance_methods(false) - [entry.name]).select { |m| own.(m) == target }.sort
        rescue StandardError
          []
        end

        def to_s
          d = Doc.new
          @entries.each do |e|
            real = e.alias? ? @index.find_all(e.original).find { |x| x.owner == e.owner } || e : e
            where = real.surface == 'console' ? 'console' : "#{real.surface == 'GraphNode DSL' ? 'node' : real.surface} method"
            # The official name heads the page with its aliases (ux-fix-1
            # item 15: `help :saw` headed `ramp` with no word of saw)
            aliases = method_aliases(real)
            d.title("#{real.signature}#{"  (alias #{aliases.join(', ')})" unless aliases.empty?}", "#{where}, #{real.owner.name.sub('MB::Sound::', '')}")
            d.note("#{e.name} is an alias of #{e.original}; graphs print it back as #{e.original} (ruby, to_ruby).") if e.alias?
            text = real.comment.strip
            text = '(no doc comment)' if text.empty?
            comment_blocks(text).each do |kind, block|
              if kind == :keep
                # Long lists in groups of at most 8 lines, broken at items
                group = []
                block.each do |l|
                  if group.length >= 6 && l =~ /^\s*[-*] / || group.length >= 8
                    d.lines(group.map { |g| "  #{doc(g)}" })
                    group = []
                  end
                  group << l
                end
                d.lines(group.map { |g| "  #{doc(g)}" })
              else
                d.para(block, indent: 2)
              end
            end
            file, line = real.location
            d.note("#{file.sub(%r{.*/lib/}, 'lib/')}:#{line}") if file
          end
          names = @entries.flat_map { |e| [e.name, e.original].compact }.uniq
          Help.ui_section(d, names.flat_map { |n| UI::HelpIndex.named(n) }.uniq)
          topics = TOPICS.values.select { |t| names.any? { |n| (t.commands + t.dsl).include?(n) } }
          d.note("Topics: #{topics.map { |t| "help :#{t.name}" }.join(', ')}.") unless topics.empty?
          learn = Help.lessons_using(names)
          d.lines(["#{c(:head, 'Learn it in:')} #{learn.map { |l, step, n| "#{c(:key, "lesson :#{l}")} #{c(:dim, "(step #{step} of #{n})")}" }.join(', ')}"]) unless learn.empty?
          d.to_s
        end

        private

        # The doc comment as [:para, text] and [:keep, lines] blocks: prose
        # paragraphs (rewrapped by the page) and indented code or list
        # lines kept as written.
        def comment_blocks(text)
          blocks = []
          text.each_line do |l|
            l = l.chomp
            if l.strip.empty?
              blocks << [:blank]
            elsif l =~ /^( {2,}|[-*] )/ || (blocks.last&.first == :keep && l =~ /^ /)
              blocks.last&.first == :keep ? blocks.last[1] << l : blocks << [:keep, [l]]
            elsif blocks.last&.first == :para
              blocks.last[1] << ' ' << l.strip
            else
              blocks << [:para, l.strip.dup]
            end
          end
          blocks.reject { |b| b.first == :blank }
        end
      end

      # Search results (`help /reson/`) for a Regexp over names and doc comments.
      class SearchPage
        include Page

        def title = @pattern.inspect
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

        # Topics whose name, title, or about text matches.
        def topics
          TOPICS.values.select { |t|
            t.name.to_s.match?(@pattern) || t.title.match?(@pattern) || t.about.match?(@pattern)
          }
        end

        # Terminal UI panes, layouts, looks, keys, and ui methods that match
        # (UI::HelpIndex, ux-1 r3 item 35).
        # (Exact names first, then names that match, then descriptions.)
        def ui_hits
          UI::HelpIndex.search(@pattern).sort_by.with_index do |e, i|
            whole = e.name.match(@pattern)
            [whole && whole[0] == e.name ? 0 : whole ? 1 : 2, i]
          end
        end

        def to_s
          h = hits
          ts = topics
          ui = ui_hits
          by_name = h.select { |e| e.name.to_s.match?(@pattern) }
          by_doc = h - by_name
          d = Doc.new
          d.title("help #{@pattern.inspect}", "#{h.length + ts.length + ui.length} matches")
          if h.empty? && ts.empty? && ui.empty?
            Help.nothing_found(d, @pattern)
            return d.to_s
          end
          d.heading('Topics').rows(ts.map { |t| [":#{t.name}", t.title] }) unless ts.empty?
          Help.ui_section(d, ui)
          [['Names', by_name], ['Mentioned in docs', by_doc]].each do |label, list|
            next if list.empty?
            rows = list.first(24).map do |e|
              where = e.surface == 'console' ? '' : (e.surface == 'GraphNode DSL' ? 'node.' : "#{e.surface.split('::').last}#")
              [where + e.name.to_s, e.summary]
            end
            d.heading(label).rows(rows)
            d.note("... #{list.length - 24} more") if list.length > 24
          end
          d.to_s
        end
      end
    end
  end
end

module MB
  module Sound
    module Help
      # Rows for UI::HelpIndex entries under a "Terminal UI" heading (ux-1
      # r3 item 35): panes, layouts, looks, keys, and ui methods, with how
      # to get each.
      def self.ui_section(doc, entries)
        return doc if entries.empty?
        rows = entries.first(24).map { |e| [e.label, "#{e.what}#{e.kind == :key || e.kind == :ui_method ? '' : "  (#{e.how})"}"] }
        doc.heading('Terminal UI').rows(rows)
        doc.note("... #{entries.length - 24} more") if entries.length > 24
        doc
      end

      # What a search page says when nothing matched: near names (topics,
      # commands, node methods, UI panes, layouts, and methods), and how to
      # search with a regular expression.
      def self.nothing_found(doc, pattern)
        word = pattern.source.gsub(/\\(.)/, '\1').gsub(/[^\w:.?!]/, '')
        dict = (TOPICS.keys.map(&:to_s) + TOPIC_ALIASES.keys.map(&:to_s) + (index.console_methods + index.dsl_methods).map { |e| e.name.to_s } + UI::HelpIndex.names).uniq
        near = word.empty? ? [] : DidYouMean::SpellChecker.new(dictionary: dict).correct(word).first(5)
        doc.para("Nothing matches #{pattern.inspect}.")
        doc.rows(near.map { |n| ["help #{n}", 'did you mean?'] }) unless near.empty?
        doc.note('help /regex/ searches names and docs with a regular expression (help /reson|filter/); help.topics lists the topics.')
        doc
      end
    end
  end
end

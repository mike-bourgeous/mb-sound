require 'mb/sound' unless defined?(MB::Sound::Session)

require_relative 'help/text'
require_relative 'help/doc'
require_relative 'help/doc_index'
require_relative 'help/topic'
require_relative 'help/pages'
require_relative 'help/level'
require_relative 'help/try'
require_relative 'help/sheet'
require_relative 'help/now'
require_relative 'help/graph_page'
require_relative 'help/rack_page'
require_relative 'help/entry_page'
require_relative 'help/lessons'
require_relative 'help/guide'
require_relative 'help/coverage'
require_relative 'help/welcome'
require_relative 'help/help_methods'

module MB
  module Sound
    # Console help for bin/sound.rb (design/notes/help.md): the one-screen
    # sheet (`help`), topics and method pages generated from doc comments
    # (`help :knobs`, `help :turn`, `help /reson/`, `help node`), runnable
    # examples (`help(:knobs).try`), the listening level check
    # (`help.level`, a monitor trim), `now`, and lessons.  Loaded by bin/sound.rb, not by
    # `require 'mb/sound'`.
    #
    # The hand-written part is Ruby in content/ (topics, the sheet,
    # lessons); everything else is generated from the code, and
    # spec/lib/mb/sound/help_spec.rb checks names, plays examples, runs
    # lessons, and fails for a console command no topic covers (see
    # Help::Coverage).
    module Help
      # Where help keeps per-user state (the listening level, lesson
      # progress): $MB_SOUND_HELP_DIR, else the user data directory
      # (~/Library/Application Support/mb-sound/help on macOS,
      # $XDG_DATA_HOME/mb-sound/help or ~/.local/share/mb-sound/help
      # elsewhere), next to presets and takes.
      def self.data_dir
        Internal.help_data_dir # (also the CUE preferences; see Session::Cue::Prefs)
      end

      # The doc comment index (built on first use; reading every comment
      # for a search takes about a third of a second the first time).
      def self.index = @index ||= DocIndex.new

      def self.topic_page(name) = TopicPage.new(TOPICS.fetch(name), index)

      # `.name`: a node or value method as topic pages list it (`.unison`).
      DOT_METHOD = /\A\.([a-z_]\w*[?!=]?)\z/

      # The method page for +text+ written `.name` (ux-friction-1 round 2:
      # the maintainer's `help .unison` and `help '.unison'` from the
      # :unison topic showed the topic again or searched), or nil: the
      # documented methods of that name other than console commands, or
      # all of them when none is a node or value method.
      def self.dot_method_page(text)
        m = text.strip.match(DOT_METHOD) or return nil
        entries = index.find_all(m[1].to_sym)
        return nil if entries.empty?

        methods = entries.reject { |e| e.surface == 'console' }
        MethodPage.new(methods.empty? ? entries : methods, index)
      end

      # `Owner#method`, `Owner.method`, and `A::B#method` (fixes-15: `help
      # Clip#ghost_chords` read the # as a Ruby comment and searched).
      OWNER_METHOD = /\A((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)([#.])([a-z_]\w*[?!=]?)\z/

      # The page for +text+ naming a method of a class or module the way
      # Ruby's docs do (OWNER_METHOD: # for an instance method, . for a
      # module's or class's own), or nil for other text: the method's page
      # (its owner's doc index entry, or one made from the method), else a
      # MissPage with the names it might be (spellings among the owner's
      # methods, other owners of the name in the index).  +binding+
      # resolves the name as the console would (`Clip` is
      # Sequence::Clip there only through the index's owners).
      def self.owner_method_page(text, binding = nil)
        m = text.to_s.strip.match(OWNER_METHOD) or return nil
        const, sep, name = m[1], m[2], m[3].to_sym
        mod = owner_named(const, name, binding)
        entry = mod && owner_entry(mod, sep, name)
        return MethodPage.new(see_through(entry, binding), index) if entry

        # A path that names no class, whose last part does name one
        # defining the method (ux-friction-3: the maintainer's
        # `MB::Sound::Instrument#sampler` and `MB::Sound::MIDI::Instrument#sampler`
        # for Sampler::Instrument#sampler): that one's page, saying so
        if mod.nil? && const.include?('::') && (last = owner_named(const.split('::').last, name, nil)) &&
           (entry = owner_entry(last, sep, name))
          short = last.name.to_s.sub('MB::Sound::', '')
          lead = Doc.new.note("No class or module is named #{const}; #{short}#{sep}#{name} is (help #{short}#{sep}#{name}):").to_s
          return LeadPage.new(lead, MethodPage.new(see_through(entry, binding), index))
        end

        others = index.find_all(name).reject { |e| e.owner.equal?(mod) }.map { |e| ["#{e.surface == 'console' ? '' : "#{e.surface}#"}#{name}", e] }
        known = mod ? (sep == '#' ? mod.public_instance_methods : mod.public_methods) : []
        spelled = DidYouMean::SpellChecker.new(dictionary: known.map(&:to_s)).correct(name.to_s).first(3)
        MissPage.new(text.to_s.strip, mod && mod.name.to_s.sub('MB::Sound::', ''), spelled.map { |s| "#{const}#{sep}#{s}" }, others)
      end

      # The class or module +const+ names (through +binding+, then MB::Sound
      # and Object, then the class or module whose name ends with it,
      # preferring one defining +name+), or nil.
      def self.owner_named(const, name, binding)
        found = begin
          binding&.eval(const)
        rescue NameError, SyntaxError
          nil
        end
        [MB::Sound, Object].each do |base|
          break if found

          found = base.const_get(const.delete_prefix('::'))
        rescue NameError
          nil
        end
        return found if found.is_a?(Module)

        tail = "::#{const.delete_prefix('::')}"
        list = ObjectSpace.each_object(Module).select { |c| (n = c.name) && n.start_with?('MB::') && n.end_with?(tail) }
        documented = (index.console_methods + index.dsl_methods).to_set(&:owner)
        list.min_by { |c| [c.method_defined?(name) || c.respond_to?(name) ? 0 : 1, documented.include?(c) ? 0 : 1, c.name.length, c.name] }
      end

      # The method page entries for +entry+: itself, then the method its
      # doc comment points to when that is all it says ("See
      # Instrument#sampler.": SF2::Font#sampler, ux-friction-3).
      def self.see_through(entry, binding = nil)
        m = entry.comment.to_s.strip.match(/\ASee ((?:[A-Z]\w*::)*[A-Z]\w*)([#.])([a-z_]\w*[?!=]?)\.?\z/) or return [entry]
        mod = owner_named(m[1], m[3].to_sym, binding)
        target = mod && owner_entry(mod, m[2], m[3].to_sym)
        target && !target.owner.equal?(entry.owner) ? [entry, target] : [entry]
      rescue StandardError
        [entry]
      end

      # A doc index entry for method +name+ of +mod+ (+sep+ '#': an
      # instance method, '.': its own), or nil if it has none (public).
      def self.owner_entry(mod, sep, name)
        if sep == '#'
          return nil unless mod.public_method_defined?(name)

          um = DocIndex.unwrap(mod.instance_method(name))
          owner = um.owner
          index.find_all(name).find { |e| e.owner.equal?(owner) } ||
            DocIndex::Entry.new(name: name, owner: owner, surface: owner.name.to_s.sub('MB::Sound::', ''),
                                original: (um.original_name == name ? nil : um.original_name), unbound: um)
        else
          return nil unless mod.respond_to?(name)

          um = mod.method(name).unbind
          DocIndex::Entry.new(name: name, owner: mod, surface: mod.name.to_s.sub('MB::Sound::', ''),
                              original: (um.original_name == name ? nil : um.original_name), unbound: um)
        end
      end

      # What `help x` returns for each kind of argument.
      def self.page_for(subject)
        case subject
        when nil then Desk.new(index)
        when Regexp then SearchPage.new(subject, index)
        when Symbol, String
          page = owner_method_page(subject.to_s) and return page
          page = dot_method_page(subject.to_s) and return page
          name = subject.to_sym
          return topic_page(name) if TOPICS.key?(name)
          return topic_page(TOPIC_ALIASES[name]) if TOPIC_ALIASES.key?(name)
          return SectionPage.new(name, index) if GROUPS.key?(name)
          entries = index.find_all(name)
          return MethodPage.new(entries, index) unless entries.empty?
          SearchPage.new(/#{Regexp.escape(subject.to_s)}/i, index)
        when Method, UnboundMethod
          MethodPage.new(index.find_all(subject.name), index)
        when Pitch then topic_page(:pitch) # (`help 440.hz`, `help C4`: the values, not a graph)
        when GraphNode, GraphNode::Channels then GraphPage.new(subject, index)
        when Rack then RackPage.new(subject, index)
        when Library::Entry then EntryPage.new(subject, index)
        else
          if subject.respond_to?(:to_ruby)
            GraphPage.new(subject, index)
          else
            MethodPage.new(index.find_all(subject.class.name.split('::').last.downcase), index)
          end
        end
      end

      # Shows +page+ (a Page or text) at the console, wherever it reads
      # best (ux-fix-1, maintainer: "Help pages load in less pager and/or
      # as ui overlay when ui is up"): in the tiled screen's page pane
      # while `ui :tiles` (or any tiled layout) is up (UI::Tiles#page:
      # scrollable, q closes); else in a terminal through Pry's pager
      # ($PAGER, default `less -R -F -X`, which prints pages that fit
      # directly), plain text when color is off (ColorPolicy); into pipes
      # and non-terminals, the whole plain text.  A screen that can't page
      # (the band of `ui :vis`) gets the text printed in the console's
      # scroll region above it, never the pager (fixes-15: less drew over
      # the band and left Pry's input line under its border).  +pry+ is
      # the Pry instance (nil outside the console: plain output).
      def self.show(page, output = $stdout, pry = nil)
        text = Help.for_output(page.to_s, output)
        screen = defined?(UI) && UI.respond_to?(:screen) ? UI.screen : nil
        if screen.respond_to?(:page)
          title = page.respond_to?(:title) && page.method(:title).arity.zero? ? page.title : nil
          params = screen.method(:page).parameters.map(&:last)
          if params.include?(:links)
            # (rows naming other pages: Up/Down pick one, Enter reads it,
            # Backspace comes back; ux-friction-3)
            plain = MB::U.remove_ansi(text)
            where = pry&.current_binding
            screen.page(plain, title: title, help: true, links: page_links(plain), follow: ->(subject) { page_text(subject, where) })
          elsif params.include?(:help)
            screen.page(MB::U.remove_ansi(text), title: title, help: true)
          else
            screen.page(MB::U.remove_ansi(text), title: title)
          end
        elsif screen.nil? && pry && ColorPolicy.animate?(output) && Pry.config.pager
          Pry::Pager.new(pry).page(text.end_with?("\n") ? text : "#{text}\n")
        else
          output.puts(text)
        end
        nil
      end

      # Wraps Pry's printer so help pages print as their text, without
      # Pry's "=> " and inspect quoting, through Help.show.
      #
      # Other results print as Pry prints them, cut at Help.result_lines
      # lines with a dim line saying how to see the rest (followups-1; the
      # maintainer, 2026-11-21: "default pry output should not be to inspect
      # the full ruby object": a probe's result once printed thousands of
      # lines of instance variables over his screen).  `_` still holds the
      # whole value.  Only Pry's own printer is cut; another one set in
      # Pry.config.print before this prints as it would.
      class PagePrinter < Proc
        def self.new(fallback)
          super() { |output, value, pry|
            if value.is_a?(Page)
              Help.show(value, output, pry)
            elsif Help.result_lines.to_i > 0 && fallback == Pry::ColorPrinter.method(:default)
              Help.print_result(output, value, pry)
            else
              fallback.call(output, value, pry)
            end
          }
        end
      end

      # The most lines a console result prints (PagePrinter; nil or 0: no
      # limit).  MB_SOUND_RESULT_LINES sets it at start.
      RESULT_LINES = 30
      @result_lines = ENV.key?('MB_SOUND_RESULT_LINES') ? ENV['MB_SOUND_RESULT_LINES'].to_i : RESULT_LINES
      class << self
        attr_accessor :result_lines
      end

      # Collects a result's printed text up to +max+ lines, then stops the
      # printer (Pry's StopPaging, which Pry's printer lets through), so a
      # huge value's inspect is never built past what shows.
      class ResultText
        attr_reader :text

        def initialize(max)
          @max = max
          @text = +''
          @lines = 0
          @cut = false
        end

        def cut? = @cut

        def write(*strs)
          strs.each do |str|
            str.to_s.each_line do |l|
              if @lines >= @max
                @cut = true
                raise Pry::Pager::StopPaging
              end
              @text << l
              @lines += 1 if l.end_with?("\n")
            end
          end
          nil
        end

        def <<(str)
          write(str)
          self
        end

        def print(*strs) = write(*strs)
      end

      # Prints +value+ as Pry's printer would ("=> " and pp, in color when
      # Pry's is on), cut at .result_lines lines (see PagePrinter).
      def self.print_result(output, value, pry)
        max = result_lines.to_i
        buf = ResultText.new(max)
        begin
          Pry::ColorPrinter.pp(value, buf, pry.output.width - 1)
        rescue Pry::Pager::StopPaging
          nil
        end
        text = buf.text
        output.print(pry.config.output_prefix)
        if buf.cut?
          text = "#{text.chomp}\e[0m\n" if pry.config.color
          output.write(text.end_with?("\n") ? text : "#{text}\n")
          output.puts("\e[2m... cut at #{max} lines: `pp _; nil` prints all of it (MB::Sound::Help.result_lines = nil: no cut)\e[0m")
        else
          output.write(text)
        end
        nil
      end

      # pry-byebug's stepping commands (only useful inside binding.pry, and
      # `finish` typed at the console once ran pry-byebug's step-out, which
      # emptied Pry's binding stack and ended the process at the next
      # prompt; maintainer, 2026-10-18): always moved to pry-<name>.
      BYEBUG_COMMANDS = %w[backtrace next step continue finish up down frame break].freeze

      # Pry commands moved to pry-<name> even where no console method has
      # their name today (Pry's play, reset, and hist edit and replay
      # input, which surprises at a live console).
      PRY_RENAMES = (%w[help play reset hist] + BYEBUG_COMMANDS).freeze

      # Moves Pry commands out of the way of console commands: every name in
      # PRY_RENAMES, and every other Pry command a console command's name
      # (from the help index, aliases included) would run instead, becomes
      # pry-<name> (`pry-help`, `pry-finish`).  Returns the moved names.
      def self.rename_pry_collisions!(cmds)
        names = PRY_RENAMES + index.console_methods.map { |m| m.name.to_s }
        names.uniq.filter_map { |n|
          c = cmds.find_command(n)
          next unless c && c.match.is_a?(String) && c.match == n && !c.description.to_s.start_with?('mb-sound')
          cmds.rename_command("pry-#{n}", n)
          n
        }
      end

      # Pry's show-doc (and ?) for what Pry can't find but mb-sound's help
      # can (ux-friction-3: the maintainer's `show-doc Instrument#sampler`,
      # `show-doc MB::Sound::Instrument#sampler`, and `show-doc
      # MB::Sound::MIDI::Instrument#sampler` each said "Couldn't locate a
      # definition"): the help page instead, under a line saying so; a
      # name help knows only as words gets a pointer to `help .name`.
      # Everything Pry finds, and errors for names help doesn't know,
      # stay Pry's.  Prepended to Pry::Command::ShowDoc by .install_pry!.
      module ShowDocHelp
        def process
          super
        rescue Pry::CommandError => e
          raise unless e.message.start_with?("Couldn't locate a definition", 'No docs found')

          text = obj_name.to_s.strip
          page = Help.library_page_for(text, target)
          if page
            output.puts "show-doc: #{e.message.sub(/\AError: /, '')}; mb-sound's help has it (help #{text}):"
            return Help.show(page, output, pry_instance)
          end
          name = text[/[#.]?([a-z_]\w*[?!=]?)\z/, 1]
          raise unless name && !Help.index.find_all(name.to_sym).empty?

          raise Pry::CommandError, "#{e.message} (mb-sound's help: help .#{name})"
        end
      end

      # The help page show-doc falls back to for +text+ (see ShowDocHelp):
      # a method page for `Owner#name` (partial class names too), `.name`,
      # or `receiver.name`, never a search or a miss; else nil.
      def self.library_page_for(text, binding = nil)
        page = owner_method_page(text, binding) || dot_method_page(text) || receiver_method_page(text, binding)
        inner = page.is_a?(LeadPage) ? page.page : page
        inner.is_a?(MethodPage) ? page : nil
      end

      # Headings whose rows name other pages (and "<name> is also", the
      # chooser).
      LINKED_HEADINGS = ['Commands', 'Node and value methods', 'Topics', 'Names', 'Mentioned in docs', 'Terminal UI', 'Did you mean'].freeze

      # The rows of help page text +text+ (plain, as the page pane shows
      # it) that name another page, as [[line index, what to give `help`],
      # ...]: rows under LINKED_HEADINGS and the chooser's "x is also"
      # (ux-friction-3: the page pane follows them; UI::Panes::Page).  A
      # bare command named like a topic opens the command
      # (`DrumMethods#tr808`-style), since `help sampler` is the topic.
      def self.page_links(text)
        links = []
        linked = false
        text.to_s.each_line.with_index do |line, i|
          line = line.chomp
          if line.match?(/\A\S/)
            linked = LINKED_HEADINGS.include?(line.strip) || line.match?(/\A[a-z_]\w*[?!]? is also\z/)
            next
          end
          next unless linked

          if (m = line.match(/\A  help (\S+)(?:\s{2,}|\z)/))
            links << [i, m[1]]
          elsif (m = line.match(/\A  ([:.]?[A-Za-z_][\w:#.]*[?!=]?)(?: \([^)]*\))?(?:\s{2,}|\z)/))
            links << [i, link_subject(m[1])]
          end
        end
        links.reject { |_, s| s.nil? }
      end

      # What `help` takes for a page row's name (see .page_links).
      def self.link_subject(name)
        return name if name.start_with?(':', '.') || name.include?('#') || name.include?('.')
        return nil if name.match?(/\A(?:try|lesson)\z/)

        sym = name.to_sym
        if TOPICS.key?(sym) || TOPIC_ALIASES.key?(sym)
          cmd = index.find_all(sym).find { |e| e.surface == 'console' }
          return cmd ? "#{cmd.owner.name.to_s.sub('MB::Sound::', '')}##{name}" : ":#{name}"
        end
        name.match?(/\A[A-Z]/) ? name : ":#{name}"
      end

      # The page pane's text, title, and links for `help` +subject+ (a
      # row followed with Enter; see .page_links): [plain text, "HELP ·
      # title", links].
      def self.page_text(subject, binding = nil)
        page = page_for_text(subject, binding)
        text = MB::U.remove_ansi(page.to_s)
        title = page.respond_to?(:title) && page.method(:title).arity.zero? ? page.title : nil
        [text, ['HELP', title].compact.reject { |t| t.to_s.empty? }.join(' · '), page_links(text)]
      end

      # Sets up Pry for the console (bin/sound.rb): Pry commands named like
      # console commands move to pry-<name> (see .rename_pry_collisions!),
      # pages print as text, and lessons check each line.
      def self.install_pry!
        cmds = Pry.config.commands
        rename_pry_collisions!(cmds)
        Pry.config.print = PagePrinter.new(Pry.config.print) unless Pry.config.print.is_a?(PagePrinter)
        install_commands(cmds)
        Pry::Command::ShowDoc.prepend(ShowDocHelp) if defined?(Pry::Command::ShowDoc) && !(Pry::Command::ShowDoc < ShowDocHelp)
        Pry.config.hooks.delete_hook(:after_eval, :mb_sound_lesson) if Pry.config.hooks.hook_exists?(:after_eval, :mb_sound_lesson)
        Pry.config.hooks.add_hook(:after_eval, :mb_sound_lesson) do |_result, pry|
          if (r = LessonRunner.active) && (msg = r.after_line)
            pry.output.puts msg
          end
        end
      end
    end

    module Help
      # Ruby node types `help x` evaluates (a value to explain): literals
      # and names, never calls with arguments (`help play foo` is text,
      # not a play).
      EVAL_NODES = [Prism::SymbolNode, Prism::RegularExpressionNode, Prism::StringNode, Prism::LocalVariableReadNode,
                    Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::InterpolatedSymbolNode].freeze

      # The page for `help <text>` typed at the console (the Pry command,
      # ux-1 item 28; maintainer: "could it be a Pry command instead of
      # pure Ruby so it doesn't have to take valid Ruby syntax?"): nothing
      # is the sheet; a Ruby literal or a name defined in +binding+
      # (`:turn`, `/reson/`, `g`) is what `help(x)` shows; anything else is
      # words: a topic, section, alias, or command name, else the topic
      # whose name, title, and text best match the words (`help mix an
      # effect in`), else a search.
      def self.page_for_text(text, binding = nil)
        page = words_page(text, binding)
        hint = INTENTS[text.to_s.strip.downcase.squeeze(' ')]
        hint ? LeadPage.new(Doc.new.note(hint).to_s, page) : page
      end

      # Words people type for a task whose command has another name, and
      # a line pointing at it above whatever page the words find
      # (ux-friction-3: the maintainer tried `clear`, `reset`,
      # `session.clear`, `clear :form`, and `Session.clear` before asking
      # how to empty the set).
      START_OVER = 'Starting over? clear_set empties the set: it stops everything and takes out the tracks, scenes, flow, ' \
                   'knobs, buses, and racks (tempo, key, and master gain stay; undo puts it back; help :clear_set).'
      INTENTS = ['clear', 'reset', 'start over', 'new', 'empty', 'new set', 'clear all', 'clear everything', 'reset set',
                 'clear set', 'clear session', 'wipe', 'empty set'].to_h { |w| [w, START_OVER] }.freeze

      # The page for words (see .page_for_text, which adds INTENTS).
      def self.words_page(text, binding = nil)
        text = text.to_s.strip
        return page_for(nil) if text.empty?
        page = owner_method_page(text, binding) and return page
        page = dot_method_page(text) and return page
        page = receiver_method_page(text, binding) and return page

        tree = Prism.parse(text)
        if tree.success? && (stmts = tree.value.statements.body).length == 1
          node = stmts[0]
          node = :local if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil? && node.block.nil? &&
                           binding&.local_variable_defined?(node.name)
          node = :library if binding && library_chain?(node, binding)
          if node == :local || node == :library || EVAL_NODES.any? { |k| node.is_a?(k) }
            value = begin
              binding ? binding.eval(text) : nil
            rescue NameError
              nil
            end
            value = Prism.parse(text).value.statements.body[0].unescaped.to_sym if value.nil? && stmts[0].is_a?(Prism::SymbolNode)
            # (a Regexp literal without a binding: as typed, not as words)
            value = Regexp.new(stmts[0].unescaped, stmts[0].ignore_case? ? Regexp::IGNORECASE : 0) if value.nil? && stmts[0].is_a?(Prism::RegularExpressionNode)
            return page_for(value) unless value.nil?
          end
        end

        words = text.downcase.scan(/[a-z0-9_!?]+/)
        if words.length == 1
          w = words[0].to_sym
          if TOPICS.key?(w) || TOPIC_ALIASES.key?(w) || GROUPS.key?(w) || !index.find_all(w).empty? || !UI::HelpIndex.named(w).empty?
            lead = also_named(w)
            return lead ? LeadPage.new(lead, page_for(w)) : page_for(w)
          end
        end
        best = words_topic(words)
        return topic_page(best) if best
        # (one-letter words match nearly everything: Kez's `help L.inst.x`
        # searched for "l" and listed 937 matches)
        kept = words.reject { |x| STOP_WORDS.include?(x) || x.length < 2 }
        kept = words if kept.empty? # (`help on`: a UI method named like a stop word)
        SearchPage.new(Regexp.union(kept.map { |x| /#{Regexp.escape(x)}/i }), index, words: kept)
      end

      # `help kit.sampler` (ux-friction-3: the maintainer's `help sampler`
      # showed the Sampler topic, and Pry's show-doc found nothing for
      # `Instrument#sampler`): a method called on a console variable is
      # the page of that method of the variable's class (the variable is
      # read, never anything called); on any other expression
      # (`sf2('kit.sf2').sampler`), which help doesn't run, the pages of
      # every documented method of that name, saying so.  Nil for other
      # text, library chains (`L.inst.x`, see #library_chain?), and names
      # with no documented method.
      def self.receiver_method_page(text, binding)
        tree = Prism.parse(text)
        return nil unless tree.success? && (stmts = tree.value.statements.body).length == 1

        node = stmts[0]
        return nil unless node.is_a?(Prism::CallNode) && node.receiver && node.arguments.nil? && node.block.nil? &&
                          node.name.to_s.match?(/\A[a-z_]\w*[?!]?\z/) && node.call_operator == '.'
        return nil if binding && library_chain?(node, binding)

        name = node.name
        recv = node.receiver
        local = recv.is_a?(Prism::LocalVariableReadNode) ||
                (recv.is_a?(Prism::CallNode) && recv.receiver.nil? && recv.arguments.nil? && recv.block.nil? &&
                 binding&.local_variable_defined?(recv.name))
        literal = LITERAL_NODES.any? { |k| recv.is_a?(k) }
        if (local && binding) || literal
          # (a literal is its value: `help 440.hz`, `help 2.bars.lfo`'s
          # first step; nothing is called)
          value = literal ? recv_literal(recv) : binding.local_variable_get(recv.name)
          mod, sep = value.is_a?(Module) ? [value, '.'] : [value.class, '#']
          entry = owner_entry(mod, sep, name)
          return MethodPage.new(see_through(entry, binding), index) if entry
          return nil if literal

          what = "#{recv.name} (#{value.is_a?(Module) ? value.name : "a #{mod.name.to_s.sub('MB::Sound::', '')}"})"
          others = dot_method_page(".#{name}") or
            return MissPage.new(text, mod.name.to_s.sub('MB::Sound::', ''), [], [])
          return LeadPage.new(Doc.new.note("#{what} has no method #{name}; every documented .#{name}:").to_s, others)
        end
        return nil if recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode) # (Owner.name: OWNER_METHOD's)

        page = dot_method_page(".#{name}") or return nil
        owners = page_owners(name)
        LeadPage.new(Doc.new.note("help doesn't run #{recv.slice[0, 40]}; every documented .#{name}#{owners.empty? ? '' : " (#{owners.join(', ')})"}:").to_s, page)
      end

      # Receivers #receiver_method_page reads as values.
      LITERAL_NODES = [Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::SymbolNode, Prism::StringNode].freeze

      # The value of literal node +node+ (one of LITERAL_NODES).
      def self.recv_literal(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::StringNode then node.unescaped
        else node.value
        end
      end

      # The short names of the classes and modules whose documented
      # method +name+ isn't a console command.
      def self.page_owners(name)
        index.find_all(name).reject { |e| e.surface == 'console' }.map { |e| e.owner.name.to_s.sub('MB::Sound::', '') }.uniq
      end

      # The chooser over a topic's page when its name +w+ is also a
      # console command or a method (ux-friction-3: `help sampler` showed
      # the Sampler topic, with the command's and the instrument's own
      # pages a guess away), or nil: one row per other meaning, written
      # as the help line that opens it.
      def self.also_named(w)
        return nil unless TOPICS.key?(w) || TOPIC_ALIASES.key?(w)

        entries = index.find_all(w).reject(&:alias?)
        rows = []
        if (cmd = entries.find { |e| e.surface == 'console' })
          rows << ["help #{cmd.owner.name.to_s.sub('MB::Sound::', '')}##{w}", "the command: #{cmd.summary}"]
        end
        owners = page_owners(w)
        rows << ["help .#{w}", "the method on #{owners.join(', ')}"] unless owners.empty?
        return nil if rows.empty?

        Doc.new.heading("#{w} is also").rows(rows, max_label: 36).to_s
      end

      # True for a chain of argument-free calls on a library root
      # (`L.inst.house_bass`, `L.fx`; guide chapters 5 and 10 write `help
      # L.inst.house_bass`): library heads are lookups, so `help` may
      # evaluate them.  Other call chains stay words (`help play foo` never
      # plays).
      def self.library_chain?(node, binding)
        n = node
        while n.is_a?(Prism::CallNode)
          return false unless n.arguments.nil? && n.block.nil? && n.receiver && n.name.to_s.match?(/\A[a-z_]\w*[?!]?\z/)
          n = n.receiver
        end
        return false unless n.is_a?(Prism::ConstantReadNode) || n.is_a?(Prism::ConstantPathNode)
        return false if n.equal?(node)

        root = binding.eval(n.slice)
        root.is_a?(Library::Heads::Root)
      rescue NameError
        false
      end

      # Words `help` ignores when matching text.
      STOP_WORDS = %w[a an the in into to of on how do i and or with for it my is what].freeze

      # The topic that best matches +words+ (names and aliases count most,
      # then titles, then the text), or nil if none clearly does.
      def self.words_topic(words)
        words = words.reject { |w| STOP_WORDS.include?(w) }
        return nil if words.empty?
        scores = TOPICS.values.to_h do |t|
          aliases = TOPIC_ALIASES.select { |_, v| v == t.name }.keys.map(&:to_s)
          score = words.sum do |w|
            stem = w.sub(/(ing|s)\z/, '')
            next 4 if t.name.to_s == w || aliases.include?(w)
            next 2 if t.title.downcase.include?(stem)
            t.about.downcase.include?(stem) ? 1 : 0
          end
          [t.name, score]
        end
        top, second = scores.values.sort.reverse
        return nil if top.to_i < 3 || top == second
        scores.key(top)
      end

      # The console's `help` and `lesson` commands (Pry commands, so
      # what follows them needn't be Ruby: `help mix an effect in`,
      # `lesson set`).  `help(:knobs).try`, `help.topics`, and
      # `lesson.next` are still Ruby (a command only takes a line starting
      # with its name and a space).
      def self.install_commands(cmds)
        cmds.create_command('help') do
          description 'mb-sound help: help, help flow, help mix an effect in, help :turn, help /reson/ (pry-help: Pry\'s)'
          command_options keep_retval: false

          def process
            page = MB::Sound::Help.page_for_text(arg_string, target)
            MB::Sound::Help.show(page, output, pry_instance)
          end
        end
        cmds.create_command('lesson') do
          description 'mb-sound lessons: lesson, lesson set, lesson :knobs (lesson.next and friends are Ruby)'
          command_options keep_retval: false

          def process
            args = arg_string.strip
            page =
              if args.empty?
                MB::Sound.lesson
              elsif args.match?(/\A[a-z_]\w*\z/)
                MB::Sound.lesson(args.to_sym) # lesson set
              else
                target.eval("MB::Sound.lesson(#{args})") # lesson :set, restart: true
              end
            output.puts MB::Sound::Help.for_output(page.to_s, output) if page
          end
        end
      end
    end

    extend HelpMethods
  end
end

require_relative 'help/content/topics'
require_relative 'help/content/textures'
require_relative 'help/content/clocks'
require_relative 'help/content/sheet'
require_relative 'help/content/lessons'

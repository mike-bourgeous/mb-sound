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
require_relative 'help/lessons'
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
        env = ENV['MB_SOUND_HELP_DIR']
        return File.expand_path(env) unless env.to_s.empty?
        if RbConfig::CONFIG['host_os'] =~ /darwin/
          File.join(Dir.home, 'Library', 'Application Support', 'mb-sound', 'help')
        else
          base = ENV['XDG_DATA_HOME'].to_s.empty? ? File.join(Dir.home, '.local', 'share') : ENV['XDG_DATA_HOME']
          File.join(base, 'mb-sound', 'help')
        end
      end

      # The doc comment index (built on first use; reading every comment
      # for a search takes about a third of a second the first time).
      def self.index = @index ||= DocIndex.new

      def self.topic_page(name) = TopicPage.new(TOPICS.fetch(name), index)

      # What `help x` returns for each kind of argument.
      def self.page_for(subject)
        case subject
        when nil then Desk.new(index)
        when Regexp then SearchPage.new(subject, index)
        when Symbol, String
          name = subject.to_sym
          return topic_page(name) if TOPICS.key?(name)
          return topic_page(TOPIC_ALIASES[name]) if TOPIC_ALIASES.key?(name)
          return SectionPage.new(name, index) if GROUPS.key?(name)
          entries = index.find_all(name)
          return MethodPage.new(entries, index) unless entries.empty?
          SearchPage.new(/#{Regexp.escape(subject.to_s)}/i, index)
        when Method, UnboundMethod
          MethodPage.new(index.find_all(subject.name), index)
        when GraphNode, GraphNode::Channels then GraphPage.new(subject, index)
        when Rack then RackPage.new(subject, index)
        else
          if subject.respond_to?(:to_ruby)
            GraphPage.new(subject, index)
          else
            MethodPage.new(index.find_all(subject.class.name.split('::').last.downcase), index)
          end
        end
      end

      # Wraps Pry's printer so help pages print as their text, without
      # Pry's "=> " and inspect quoting.
      class PagePrinter < Proc
        def self.new(fallback)
          super() { |output, value, pry|
            value.is_a?(Page) ? output.puts(Help.for_output(value.to_s, output)) : fallback.call(output, value, pry)
          }
        end
      end

      # Sets up Pry for the console (bin/sound.rb): Pry's help command moves
      # to pry-help, pages print as text, and lessons check each line.
      def self.install_pry!
        cmds = Pry.config.commands
        cmds.rename_command('pry-help', 'help') if cmds.valid_command?('help') && !cmds.valid_command?('pry-help')
        Pry.config.print = PagePrinter.new(Pry.config.print) unless Pry.config.print.is_a?(PagePrinter)
        install_commands(cmds)
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
        text = text.to_s.strip
        return page_for(nil) if text.empty?

        tree = Prism.parse(text)
        if tree.success? && (stmts = tree.value.statements.body).length == 1
          node = stmts[0]
          node = :local if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil? && node.block.nil? &&
                           binding&.local_variable_defined?(node.name)
          if node == :local || EVAL_NODES.any? { |k| node.is_a?(k) }
            value = begin
              binding ? binding.eval(text) : nil
            rescue NameError
              nil
            end
            value = Prism.parse(text).value.statements.body[0].unescaped.to_sym if value.nil? && stmts[0].is_a?(Prism::SymbolNode)
            return page_for(value) unless value.nil?
          end
        end

        words = text.downcase.scan(/[a-z0-9_!?]+/)
        if words.length == 1
          w = words[0].to_sym
          return page_for(w) if TOPICS.key?(w) || TOPIC_ALIASES.key?(w) || GROUPS.key?(w) || !index.find_all(w).empty?
        end
        best = words_topic(words)
        return topic_page(best) if best
        SearchPage.new(Regexp.union(words.reject { |x| STOP_WORDS.include?(x) }.map { |x| /#{Regexp.escape(x)}/i }), index)
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
            output.puts MB::Sound::Help.for_output(page.to_s, output)
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
require_relative 'help/content/sheet'
require_relative 'help/content/lessons'

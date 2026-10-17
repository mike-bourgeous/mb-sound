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
        Pry.config.hooks.delete_hook(:after_eval, :mb_sound_lesson) if Pry.config.hooks.hook_exists?(:after_eval, :mb_sound_lesson)
        Pry.config.hooks.add_hook(:after_eval, :mb_sound_lesson) do |_result, pry|
          if (r = LessonRunner.active) && (msg = r.after_line)
            pry.output.puts msg
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

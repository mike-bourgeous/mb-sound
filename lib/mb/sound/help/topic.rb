module MB
  module Sound
    module Help
      # A help topic (`help :knobs`): hand-picked names grouped the way a set
      # is played (+group+), with the text for each name read from the code's
      # doc comments (DocIndex), and runnable examples written as Ruby blocks
      # (their source is shown with Prism, `help(:knobs).try` runs them, and
      # the guard spec plays them and checks their level).
      class Topic
        # A runnable example.  +bars+ is how long `try` lets the players it
        # started run; +sound+ is false for examples that print instead of
        # playing (plots, Ruby), which the level check skips.
        Example = Struct.new(:title, :block, :bars, :sound, keyword_init: true) do
          def source = Text.block_body(block)
        end

        attr_reader :name, :title, :group, :about, :commands, :dsl, :notes, :examples, :see, :sections

        def initialize(name, title, group)
          @name, @title, @group = name, title, group
          @about = +''
          @commands = []
          @dsl = []
          @notes = []
          @examples = []
          @see = []
          @sections = []
        end

        # Every method name the topic lists (console commands and DSL).
        def names = @commands + @dsl

        # The topic builder (methods exist only for real settings, so a typo
        # is a NoMethodError with a did_you_mean suggestion).
        class Builder
          def initialize(topic) = @topic = topic

          # What the topic is for, in paragraphs.
          # (blank lines separate paragraphs, which the page keeps)
          def about(text) = @topic.about.replace(text.split(/\n\s*\n/).map { |p| p.gsub(/\s+/, ' ').strip }.join("\n\n"))

          # Console commands (MB::Sound methods) in the order to show them.
          def commands(*names) = @topic.commands.concat(names.flatten)

          # Node and value methods (the recorded DSL surface).
          def dsl(*names) = @topic.dsl.concat(names.flatten)

          # Design notes (design/notes/<name>.md) to read for details.
          def note(*names) = @topic.notes.concat(names)

          # A generated section of the page: the block gets the page's
          # Help::Doc after the commands (tables built from the code, like
          # help :ui's layouts and keys).
          def section(&block) = @topic.sections << block

          # Related topics.
          def see(*names) = @topic.see.concat(names)

          # A runnable example: the block is what you would type, shown as
          # source and run by TopicPage#try (players it starts stop after
          # +bars+).  Examples that make sound play near the level
          # calibration's reference (see Help::Level); +sound: false+ for
          # ones that print instead.
          def example(title, bars: 2, sound: true, &block)
            @topic.examples << Example.new(title: title, block: block, bars: bars, sound: sound)
          end
        end

        def build(&block)
          Builder.new(self).instance_eval(&block)
          self
        end
      end

      # The topics, keyed by name, in definition order.
      TOPICS = {}

      # Other names that lead to a topic (`help :wet` is the blend topic).
      TOPIC_ALIASES = {}

      # The workflow groups of the sheet and the topic list, in order.
      GROUPS = {
        start: 'Start and stop',
        sound: 'Make sounds',
        time: 'Time and patterns',
        arrange: 'Arrange a set',
        perform: 'Perform',
        keep: 'Record and keep',
        look: 'Look and listen',
      }.freeze

      # Defines a topic (see Topic::Builder); content/topics.rb has them all.
      def self.topic(name, title, group:, &block)
        raise ArgumentError, "unknown group #{group} (#{GROUPS.keys.join(', ')})" unless GROUPS.key?(group)
        TOPICS[name] = Topic.new(name, title, group).build(&block)
      end
    end
  end
end

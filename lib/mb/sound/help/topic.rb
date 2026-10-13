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

        attr_reader :name, :title, :group, :about, :commands, :dsl, :notes, :examples, :see

        def initialize(name, title, group)
          @name, @title, @group = name, title, group
          @about = +''
          @commands = []
          @dsl = []
          @notes = []
          @examples = []
          @see = []
        end

        # Every method name the topic lists (console commands and DSL).
        def names = @commands + @dsl

        # The topic builder (methods exist only for real settings, so a typo
        # is a NoMethodError with a did_you_mean suggestion).
        class Builder
          def initialize(topic) = @topic = topic

          # One or two sentences on what the topic is for.
          def about(text) = @topic.about.replace(text.gsub(/\s+/, ' ').strip)

          # Console commands (MB::Sound methods) in the order to show them.
          def commands(*names) = @topic.commands.concat(names.flatten)

          # Node and value methods (the recorded DSL surface).
          def dsl(*names) = @topic.dsl.concat(names.flatten)

          # Design notes (design/notes/<name>.md) to read for details.
          def note(*names) = @topic.notes.concat(names)

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

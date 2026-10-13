module MB
  module Sound
    module Help
      # `help node` explains a graph: the Ruby that
      # builds it (Recipe), the node types in it with their doc lines, how
      # the plan layer runs it, and the topics that cover its methods.
      class GraphPage
        include Page
        include Text

        def initialize(node, index)
          @node = node
          @index = index
        end

        def to_s
          out = []
          nodes = (@node.respond_to?(:graph) ? @node.graph(include_tees: false) : [@node]).uniq
          out << "#{c(:title, @node.class.name.sub('MB::Sound::', ''))}  #{c(:dim, "#{nodes.length} nodes, #{(@node.channel_count rescue 1)} channel(s)")}"
          src = (@node.to_ruby rescue nil)
          if src
            out << c(:head, 'as Ruby') + c(:dim, '  (ruby node)')
            out << src.lines.map { |l| '  ' + code(l.chomp) }.join("\n")
          end
          out << c(:head, 'node types')
          nodes.select { |n| n.respond_to?(:sample) }.group_by(&:class).each do |klass, list|
            name = klass.name.to_s.sub('MB::Sound::', '')
            text = "#{list.length > 1 ? "x#{list.length} " : ''}#{class_summary(klass)}"
            room = width - 31
            text = text[0, room].sub(/\s+\S*\z/, '') + '...' if text.length > room
            out << "  #{pad(c(:key, name), 28)} #{text}"
          end
          plan = (Plan.explain(@node).to_s rescue nil)
          if plan && !plan.empty?
            out << c(:head, 'plan') + c(:dim, '  (Plan.explain)')
            lines = plan.lines.map(&:chomp).reject(&:empty?)
            lines.first(4).each { |l| out << "  #{c(:dim, l[0, width - 4])}" }
            out << "  #{c(:dim, "... #{lines.length - 4} more lines")}" if lines.length > 4
          end
          if src
            called = calls_in(src) - %i[hz at until]
            topics = TOPICS.values.select { |t| (t.dsl + t.commands).intersect?(called) }
            out << c(:dim, "topics: #{topics.map { |t| "help :#{t.name}" }.join(', ')}") unless topics.empty?
          end
          out.join("\n")
        end

        private

        def calls_in(src)
          names = []
          walk = ->(n) {
            return if n.nil?
            names << n.name if n.is_a?(Prism::CallNode)
            n.compact_child_nodes.each { |c| walk.(c) }
          }
          walk.(Prism.parse(src).value)
          names.uniq
        end

        # The first sentence of the comment above the class definition.
        def class_summary(klass)
          short = klass.name.to_s.split('::').last
          files = [(Object.const_source_location(klass.name) rescue nil)&.first]
          files += klass.instance_methods(false).first(20).map { |m| klass.instance_method(m).source_location&.first }
          files.compact.uniq.each do |file|
            next unless File.exist?(file)
            lines = File.readlines(file)
            i = lines.index { |l| l =~ /^\s*class #{short}\b/ } or next
            com = []
            j = i - 1
            while j >= 0 && lines[j] =~ /^\s*#/
              com.unshift(lines[j].sub(/^\s*# ?/, '').chomp)
              j -= 1
            end
            next if com.empty?
            return com.join(' ').split(/(?<=[a-z0-9)])(?<!e\.g)\.\s/).first.to_s.gsub(/\s+/, ' ').strip
          end
          ''
        end
      end
    end
  end
end

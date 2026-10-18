module MB
  module Sound
    module GraphNode
      # A one-line #inspect for graph nodes (ux-fix-1, 2026-10-18): the
      # node's type and the Ruby that builds it (see Recipe::ToRuby), capped
      # at INSPECT_LIMIT characters, e.g.
      #
      #     C4.saw.delay(1.n8, feedback: 0.4)
      #     # => #<SampleWrapper C4.saw.delay(1.n8, feedback: 0.4)>
      #
      # Ruby's default #inspect printed every instance variable, sample
      # buffers included: 2,000,000 characters for one delay, which Pry
      # opened in a pager.  #inspect_full is the old dump, for debugging.
      #
      # Included in GraphNode and Channels, and in Notes and clips' Synths
      # through GraphNode.  Classes with their own #inspect keep it.
      module Inspect
        # The longest #inspect, in characters.
        INSPECT_LIMIT = 200

        # Returns a one-line description: `#<Type code>`.  Never raises;
        # nodes that can't print themselves as Ruby show `#<Type/name>` or
        # `#<Type/id=...>`.
        def inspect
          type = self.class.name.to_s.rpartition('::').last
          code = Inspect.code_of(self)
          if code.nil? || code.empty?
            name = respond_to?(:graph_node_name) && graph_node_name
            return "#<#{type}/#{name || "id=#{__id__}"}>"
          end

          Inspect.cap("#<#{type} #{code}>")
        end

        # Ruby's default #inspect, with every instance variable (sample
        # buffers, filter state, sources...).  Very long for most nodes.
        def inspect_full
          Kernel.instance_method(:inspect).bind_call(self)
        end

        # Pry and pp print the one-line form too.
        def pretty_print(q)
          q.text(inspect)
        end

        # The Ruby that builds +node+ on one line, or nil.  Nested calls
        # (to_ruby printing a value that inspects a node) return nil.
        def self.code_of(node)
          return nil unless node.respond_to?(:to_ruby)
          return nil if Thread.current[:mb_sound_inspecting]

          begin
            Thread.current[:mb_sound_inspecting] = true
            one_line(node.to_ruby)
          ensure
            Thread.current[:mb_sound_inspecting] = nil
          end
        rescue StandardError, ScriptError
          nil
        end

        # Joins the lines of to_ruby's output: statements with "; ", block
        # bodies with spaces.
        def self.one_line(text)
          lines = text.to_s.lines.map(&:strip).reject(&:empty?)
          out = +''
          lines.each do |l|
            if out.empty? || out.end_with?('{', '|', 'do', '(', '[', ',') || l.start_with?('}', ')', ']', '.', 'end')
              out << (out.empty? || l.start_with?('.', ')', ']') ? '' : ' ') << l
            else
              out << '; ' << l
            end
          end
          out
        end

        # Cuts +text+ to INSPECT_LIMIT characters, ending with "...>".
        def self.cap(text)
          return text if text.length <= INSPECT_LIMIT

          "#{text[0, INSPECT_LIMIT - 4]}...>"
        end
      end
    end
  end
end

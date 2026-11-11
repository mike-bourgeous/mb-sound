require 'prism'

module MB
  module Sound
    module GraphIO
      # Inline comments of graph and rack documents as metadata (metadata-2;
      # the maintainer, 2026-11-11: "What about inline code comments in
      # hand-written Ruby documents?  Can they be approximately round-tripped
      # through metadata?").  The loader asks Prism to attach each comment
      # to a node (Prism::ParseResult#attach_comments!) and gives it to the
      # object that node builds:
      #
      #     # the pad                    <- leading: the statement's object (pad)
      #     pad = 220.hz.saw # bright    <- trailing a chain link: the saw
      #       .lp4(
      #         800, # the cutoff        <- in an argument list: lp4's
      #         resonance: 0.3           #    meta[:arg_notes] = { 0 => "the cutoff" }
      #       ) # darker                 <- trailing the statement: pad
      #
      # Comments land in `meta[:notes]` (and argument comments in
      # `meta[:arg_notes]`, keyed by position or keyword), given quietly
      # (not recorded as calls), and are remembered here so the writer
      # (Recipe::RubyWriter) prints them back as comments: a statement's
      # notes as leading lines, a chain link's as a trailing comment before
      # the next link, an argument's after it; notes it can't place as a
      # comment (an argument or operand that is a node) print as
      # `.note("...")`.
      #
      # Approximate (design/notes/metadata.md): blank lines and alignment;
      # a comment trailing a statement comes back leading it; a comment
      # heading several statements goes to the first; `=begin` blocks and
      # comments on objects that carry no metadata (numbers, Symbols,
      # Samples) are dropped; comments in set documents are left alone
      # (their writer's own comments would come back as notes).
      #
      # Comments are text from a file: they only ever become notes, shown
      # quoted (Meta.quote), never code or settings.
      module Comments
        # Writer comment lines that never become notes (the writers print
        # them again).
        SKIP = [/\A#\s*(FIXME|WARNING)\(graph-io\)/, /\A#\s*inputs:/, /\A#\s*mb-sound (graph|rack) document/, /\A#\s*MB::Sound::GraphIO\.load/].freeze

        # Comment notes and argument notes by object (weakly held).
        NOTES = ObjectSpace::WeakKeyMap.new
        ARGS = ObjectSpace::WeakKeyMap.new
        LOCK = Mutex.new

        module_function

        # The comments of +result+ (a Prism::ParseResult) that the body
        # statements +body+ hold, as [notes, args]: notes { node => [text]
        # } for nodes that build objects (calls and local writes), args {
        # call node => { key => text } } for comments inside a call's
        # argument list (key: the argument's index, or its keyword).  nil
        # when the body has no comments.
        def collect(result, body)
          return nil if body.empty?
          # (only the writers' own comments: nothing to attach)
          return nil if result.comments.all? { |c| SKIP.any? { |re| c.location.slice.match?(re) } }
          result.attach_comments!
          notes = {}.compare_by_identity
          args = {}.compare_by_identity
          stack = body.map { |st| [st, nil, nil] }
          until stack.empty?
            node, call, key = stack.pop
            texts = texts(node)
            case node
            when Prism::CallNode, Prism::LocalVariableWriteNode
              (notes[node] ||= []).concat(texts) unless texts.empty?
            when Prism::ArgumentsNode
              # (a comment after the last argument, before the parenthesis)
              unless texts.empty? || call.nil?
                last = node.arguments.last
                k = last.is_a?(Prism::KeywordHashNode) ? keyword(last.elements.last) : node.arguments.length - 1
                add_arg(args, call, k, texts)
              end
            else
              add_arg(args, call, key, texts) unless texts.empty? || call.nil?
            end

            if node.is_a?(Prism::CallNode)
              stack << [node.receiver, nil, nil] if node.receiver
              stack << [node.block, nil, nil] if node.block
              if node.arguments
                stack << [node.arguments, node, nil]
                node.arguments.arguments.each_with_index do |a, i|
                  if a.is_a?(Prism::KeywordHashNode)
                    a.elements.each { |el| stack << [el, node, keyword(el)] }
                  else
                    stack << [a, node, i]
                  end
                end
              end
            elsif node.is_a?(Prism::ArgumentsNode)
              next
            else
              node.compact_child_nodes.each { |c| stack << [c, c.is_a?(Prism::CallNode) || c.is_a?(Prism::LocalVariableWriteNode) ? nil : call, key] }
            end
          end
          notes.empty? && args.empty? ? nil : [notes, args]
        end

        # (the note texts of the comments attached to +node+)
        def texts(node)
          loc = node.location
          (loc.leading_comments + loc.trailing_comments).filter_map do |c|
            next unless c.is_a?(Prism::InlineComment)
            s = c.location.slice
            next if SKIP.any? { |re| s.match?(re) }
            t = s.delete_prefix('#').delete_prefix(' ').rstrip
            t.empty? ? nil : t.dup.force_encoding(Encoding::UTF_8).scrub('?')
          end
        end

        def keyword(el)
          el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) ? el.key.unescaped.to_sym : nil
        end

        def add_arg(args, call, key, texts)
          return if key.nil?
          h = (args[call] ||= {})
          h[key] = [h[key], *texts].compact.join(' ')
        end

        # True if +obj+ takes notes in place (graph nodes, bundles, clips).
        def carrier?(obj)
          !obj.frozen? && (obj.is_a?(GraphNode) || obj.is_a?(GraphNode::Channels) || obj.is_a?(Sequence::Named))
        end

        # Gives +obj+ the comment +texts+ as notes (not recorded) and
        # remembers them for the writer.
        def note(obj, texts)
          return unless carrier?(obj)
          GraphNode::Recipe.quietly { obj.note(*texts) }
          LOCK.synchronize { NOTES[obj] = [*NOTES[obj], *texts].freeze }
        end

        # Gives +obj+ argument comments +h+ ({ key => text }) as
        # `meta[:arg_notes]` (not recorded) and remembers them.
        def args(obj, h)
          return unless carrier?(obj)
          merged = (obj.meta[:arg_notes].is_a?(Hash) ? obj.meta[:arg_notes] : {}).merge(h)
          GraphNode::Recipe.quietly { obj.with_meta(arg_notes: merged) }
          LOCK.synchronize { ARGS[obj] = merged.freeze }
        end

        # The comment notes of +obj+ the writer prints as comments: those it
        # still carries (a later with_meta(nil) forgets them).
        def notes_of(obj)
          list = NOTES[obj] or return nil
          have = obj.meta.notes
          list = list.select { |t| have.include?(t) }
          list.empty? ? nil : list
        end

        # The argument comments of +obj+ the writer prints ({ key => text }),
        # or nil.
        def args_of(obj)
          h = ARGS[obj] or return nil
          now = obj.meta[:arg_notes]
          now.is_a?(Hash) ? h.select { |k, v| now[k] == v } : nil
        end
      end
    end
  end
end

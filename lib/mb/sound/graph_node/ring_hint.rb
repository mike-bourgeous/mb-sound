module MB
  module Sound
    module GraphNode
      # Finds sums that ring forever: since sums ring until every input has
      # ended (GraphNode#ring), `drone + hit` plays on after the hit while
      # the drone never ends.  PlaybackMethods#bg prints .message once per
      # process for such a graph, and a render stopped at
      # MAX_RENDER_SECONDS adds it to its warning.
      #
      # A static check at build time (no per-sample cost), deliberately
      # conservative: oscillators (Tones whose inputs never end), constants,
      # and knobs never end; a ringing sum never ends if one of its
      # non-constant inputs never ends; products and sums that end with
      # their first input never end only if no input ends; other nodes
      # never end only if they have main inputs (Traversable#port_role) and
      # none of them ends; sequences (#and_then) never end if one part
      # doesn't.  Everything else (files, clips, envelopes, notes,
      # TimeLimit, Ringdown) counts as ending.
      module RingHint
        # Nodes that never end by themselves.
        STEADY = [Constant, Knob, Knob::Reader].freeze

        class << self
          # Whether bg prints the hint (once per process; spec_helper turns
          # it off before each example, so whichever example plays such a
          # graph first doesn't print it).
          attr_accessor :enabled

          # Returns the hint for +nodes+ (graph nodes or bundles), or nil if
          # no ringing sum in them keeps a graph that would otherwise end
          # playing forever.
          def message(nodes)
            sum = find(nodes) or return nil
            "Note: #{describe(sum)} rings until all of its inputs end, and one never ends, " \
              "so it plays until stopped (Ctrl-C stops play); `(a + b).ring(:first)` ends a sum with its first input"
          end

          # Prints .message for +nodes+ once per process (see .enabled).
          # Returns the message printed, or nil.
          def notice(nodes)
            return nil unless @enabled
            msg = message(nodes) or return nil
            @enabled = false
            warn msg
            msg
          end

          # Returns the first ringing Mixer in +nodes+ with an input that
          # never ends and a non-constant input that does, inside a graph
          # that never ends, or nil.
          def find(nodes)
            memo = {}.compare_by_identity
            Array(nodes.respond_to?(:outputs) ? nodes.outputs : nodes).each do |root|
              next unless root.respond_to?(:sample) && root.respond_to?(:graph)
              root = GraphNode.climb_tee_tree(root)
              next unless endless?(root, memo)

              root.graph(include_tees: false).each do |n|
                next unless n.is_a?(Mixer) && !n.stop_early?
                ins = inputs(n).reject { |s| steady?(s) }
                return n if ins.any? { |s| endless?(s, memo) } && ins.any? { |s| !endless?(s, memo) }
              end
            end
            nil
          end

          # True if +node+ never ends (see the module description).
          def endless?(node, memo = {}.compare_by_identity)
            node = GraphNode.climb_tee_tree(node)
            return memo[node] if memo.key?(node)
            memo[node] = false # loops end the walk

            memo[node] =
              case node
              when *STEADY
                true
              when TimeLimit, Ringdown
                false # (cut at a time, or after the signal falls silent)
              when MB::Sound::Tone
                inputs(node, main: false).all? { |s| endless?(s, memo) }
              when Mixer
                ins = inputs(node)
                if node.stop_early?
                  ins.all? { |s| endless?(s, memo) }
                else
                  live = ins.reject { |s| steady?(s) }
                  live.empty? || live.any? { |s| endless?(s, memo) }
                end
              when NodeSequence
                inputs(node).any? { |s| endless?(s, memo) } # plays them in turn
              when Multiplier
                inputs(node).all? { |s| endless?(s, memo) }
              else
                ins = inputs(node)
                !ins.empty? && ins.all? { |s| endless?(s, memo) }
              end
          end

          private

          def steady?(node)
            STEADY.any? { |c| node.is_a?(c) }
          end

          # The graph-node inputs of +node+ (main inputs only unless +main+
          # is false), with tees climbed.
          def inputs(node, main: true)
            return [] unless node.respond_to?(:sources)
            node.sources.filter_map { |name, s|
              next unless s.respond_to?(:sample)
              next if main && node.respond_to?(:port_role) && node.port_role(name) != :main
              GraphNode.climb_tee_tree(s)
            }
          end

          def describe(sum)
            code = (sum.to_ruby rescue nil).to_s.lines.last.to_s.strip
            code = "#{code[0, 57]}..." if code.length > 60
            code.empty? ? 'a sum' : "the sum `#{code}`"
          end
        end

        @enabled = true
      end
    end
  end
end

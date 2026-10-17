module MB
  module Sound
    module UI
      # Text drawings of trees (the buses pane's routing; meant to be shared
      # with the planned rack pane: one renderer for graphs of routing and
      # racks): the root, then each child on its own line under a ├─ / └─
      # branch, deeper levels indented under │ rails.
      #
      #     TreeText.lines(:master, children: ->(n) { kids[n] || [] })
      #     # => [['', :master], ['├─ ', :drums], ['│  └─ ', :kick], ['└─ ', :bass]]
      module TreeText
        BRANCHES = {
          unicode: { mid: '├─ ', last: '└─ ', rail: '│  ', none: '   ' }.freeze,
          ascii: { mid: '+- ', last: '`- ', rail: '|  ', none: '   ' }.freeze,
        }.freeze

        module_function

        # [prefix, node] pairs, depth first, for the tree under +root+
        # (+children+ a Proc from a node to its children).  Nodes already
        # drawn aren't followed again (a loop or a shared node shows once).
        def lines(root, children:, glyphs: :unicode, max: 500)
          g = BRANCHES[glyphs == :ascii ? :ascii : :unicode]
          out = [['', root]]
          seen = { root => true }
          walk = lambda do |node, lead|
            kids = children.call(node).to_a
            kids.each_with_index do |k, i|
              break if out.length >= max
              last = i == kids.length - 1
              out << ["#{lead}#{last ? g[:last] : g[:mid]}", k]
              next if seen[k]
              seen[k] = true
              walk.(k, lead + (last ? g[:none] : g[:rail]))
            end
          end
          walk.(root, '')
          out
        end
      end
    end
  end
end

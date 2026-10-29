module MB
  module Sound
    module Library
      # Find-as-you-type over the library heads (omnibus15; maintainer,
      # 2026-10-28: "Better yet... find-as-you-type"): for a console word
      # like "L.inst.ree" or "L.reese", the entries whose names, name words,
      # tags, or families hold the typed letters anywhere, ranked (a whole
      # name, then a name starting with them, a name word, inside a name, a
      # tag or family), each with the full chain that reaches it
      # ("L.inst.dnb_reese").  One object shared by the console popup
      # (UI::LibraryPopup) and, later, the library picker pane.
      #
      #     f = Library::Finder.new
      #     f.candidates('L.inst.ree').map(&:chain)   # => ["L.inst.dnb_reese", "L.inst.jungle_reese", ...]
      #     f.candidates('x = 1')                     # => nil (not a head chain)
      class Finder
        # One match: +chain+ the text that reaches it (to put on the line),
        # +entry+ (nil for a head word), +label+ a line for a list.
        Candidate = Data.define(:chain, :entry, :label)

        # A head chain being typed: the root, the words so far, and the
        # word being typed (maybe empty).
        PATTERN = /\A((?:MB::Sound::|::)?L)((?:\.[a-z_][a-z0-9_]*)*)\.([a-z_][a-z0-9_]*)?\z/

        def initialize(index = nil)
          @index = index
        end

        def index = @index || Library.index

        # The Candidates for +text+ (best first, at most +limit+), or nil
        # when +text+ isn't a head chain (or names one entry exactly: there
        # is nothing left to find).
        def candidates(text, limit: 12)
          m = PATTERN.match(text.to_s) or return nil
          root = m[1]
          chain = m[2].split('.').reject(&:empty?).map(&:to_sym)
          typed = m[3].to_s.downcase
          pool, path = walk(root, chain)
          return nil unless pool

          heads = chain.empty? ? head_candidates(root, typed) : []
          scored = pool.filter_map { |e| (s = score(e, typed)) && [s, e] }
          scored.sort_by! { |s, e| [-s, e.name.to_s, e.family.to_s] }
          # (names shared under a head or in the pool need their family)
          names = chain.empty? ? pool.group_by { |e| [e.kind, e.name] } : pool.group_by(&:name)
          width = scored.first(limit).map { |_, e| e.name.length }.max.to_i
          found = scored.first(limit).map { |_, e|
            Candidate.new(chain: chain_for(root, path, e, names, chain.empty?), entry: e, label: label_for(e, width))
          }
          list = (heads + found).uniq(&:chain).first(limit)
          return nil if list.empty? || (list.length == 1 && list.first.chain == text.to_s)
          list
        end

        private

        # The entries left after the words of +chain+ under +root+ and the
        # chain's text, or nil when a word doesn't narrow (or reaches an
        # Entry: its methods are Pry's to complete).
        def walk(root, chain)
          return [index.entries, root] if chain.empty?
          head, *rest = chain
          return nil unless HEADS.key?(head) || head == :all

          node = head == :all ? Heads::Query.new(nil, path: "#{root}.all") : Heads::Query.new(HEADS[head], path: "#{root}.#{head}")
          rest.each do |w|
            node = node.word(w)
            return nil unless node.is_a?(Heads::Query)
          end
          [node.entries, "#{root}.#{chain.join('.')}"]
        rescue KeyError
          nil
        end

        # Heads starting with +typed+ at the root ("L.in" -> L.inst).
        def head_candidates(root, typed)
          [*HEADS.keys, :all].select { |h| h.to_s.start_with?(typed) && !typed.empty? }.map { |h|
            Candidate.new(chain: "#{root}.#{h}", entry: nil, label: "#{h}  (#{HEADS[h] || 'everything'})")
          }
        end

        # How well +e+ matches +typed+ (nil: not at all).
        def score(e, typed)
          return 1 if typed.empty?
          name = e.name.to_s
          return 100 if name == typed
          return 80 if name.start_with?(typed)
          return 60 if e.name_words.any? { |w| w.to_s.start_with?(typed) }
          return 40 if name.include?(typed)
          words = e.words.map(&:to_s)
          return 30 if words.any? { |w| w.start_with?(typed) }
          return 20 if words.any? { |w| w.include?(typed) }
          nil
        end

        # The chain reaching +e+: from the root its head path; under a
        # head the chain so far plus its name (with its family when two
        # entries left share the name).
        def chain_for(root, path, e, names, at_root)
          if at_root
            # (as Entry#head_path, without its index walk per entry)
            head = HEADS.key(e.kind)
            fam = names[[e.kind, e.name]].length > 1 && e.family != :preset ? ".#{e.family}" : ''
            return head ? "#{root}.#{head}#{fam}.#{e.name}" : "#{root}.all#{fam}.#{e.name}"
          end
          names[e.name].length > 1 ? "#{path}.#{e.family}.#{e.name}" : "#{path}.#{e.name}"
        end

        def label_for(e, width)
          what = e.family == :preset ? e.kind : e.family
          tags = e.tags.empty? ? '' : "  #{e.tags.first(3).join(' ')}"
          "#{e.name.to_s.ljust(width)}  #{what}#{tags}"
        end
      end
    end
  end
end

module MB
  module Sound
    module Help
      # `help L.inst.house_bass` explains a library entry the way a
      # musician picks one: what it is (its description and tags), its
      # settings with their ranges, and the lines that play or use it for
      # its kind (an instrument on notes or a track, an effect after a
      # sound, a generator on a track).  Before this page, an entry fell
      # through to the graph page (its node types and plan).
      class EntryPage
        include Page
        include Text

        def initialize(entry, index)
          @entry = entry
          @index = index
        end

        def title = @entry.head_path

        def to_s
          e = @entry
          d = Doc.new
          d.title(e.head_path, "#{e.kind}#{e.tags.empty? ? '' : " [#{e.tags.join(', ')}]"}, #{e.shelf}")
          d.para(e.about) if e.about
          params = (e.params rescue {}) || {}
          unless params.empty?
            d.heading('Settings  (name, default, range)')
            d.rows(params.map { |n, p| [n.to_s, setting(p)] }, max_label: 16, wrap: true)
          end
          uses = uses_for(e)
          unless uses.empty?
            d.heading('Use it')
            d.code_block(uses)
          end
          d.note("find '#{e.name_words.join(' ')}' finds others like it; help :library has more.")
          d.to_s
        end

        private

        def setting(p)
          span = case p.range
                 when Range then Param.literal(p.range)
                 when Array then "one of #{p.range.map(&:inspect).join(', ')}"
                 end
          span = "#{span} #{p.unit}" if span && p.unit
          [Param.literal(p.default), span && "(#{span})", p.description].compact.join('  ')
        end

        # Lines that use the entry, by kind.
        def uses_for(e)
          path = e.head_path
          first = (e.params rescue {}).to_h.keys.find { |k| k != :seed }
          case e.kind
          when :instrument
            [
              "audition #{path}                      # a demo phrase (audition off stops it)",
              "bg :part, #{path}.(seq(A1, C2, E2, G2).n8.loop).at(-14.db)",
              "track :part, seq(A1, C2, E2, G2).n8.loop, #{path}#{first ? "   # its settings are knobs: turn :\"part/#{first}\", ..." : ''}",
            ]
          when :effect
            [
              "play #{path}                          # on a short demo mix",
              "bg :part, 110.hz.saw.at(-20.db).then(&#{path})   # after a sound (on a track: fx :name, #{path})",
            ]
          when :generator
            ["play #{path}", "track :part, #{path}#{first ? "   # knobs: turn :\"part/#{first}\", ..." : ''}", "#{path}(seed: 3)                   # another take of it"]
          when :kit
            ["bg :drums, #{path}.(grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.').loop).at(-14.db)"]
          when :flow
            ["flow #{path}   # plays over scenes named like its sections (help :long_form)"]
          else
            (code = (e.to_ruby rescue nil)) ? [code] : []
          end
        end
      end
    end
  end
end

require 'prism'

module MB
  module Sound
    class Take
      # Reads a take as the knob turns it made (hand-tune-1, 2026-11-03;
      # research-voice-match-3's hand-tune loop, step 3: "a reader that turns
      # a saved take's turn lines into (knob, from, to, time) rows"), so an
      # agent can see what the maintainer changed while tuning by ear, in
      # what order, and render his start and end states.
      #
      # A saved take (Take#save's script) or the live take (Take#turns,
      # through the same text: Take#to_ruby) is walked with Prism, never
      # evaluated, as the library's loaders are: the Replay's start state
      # (tempo), then each `r.line`'s code, whose `turn`/`move`, `level`,
      # `ab`, `undo`, `knob`, `fit_patch`, `track`, and `design` calls it
      # reads.  Values are read from literals: numbers, Rationals, `.hz`,
      # `.khz`, `.ms`, `.seconds`, `.db` (a level's gain), keyframe Hashes
      # (`turn :cut, 0 => 400, 1.n8 => 3000`: a gesture, its keys kept, its
      # last value the row's +to+), and ranged defaults (`(lo..hi).at(v)`).
      # A value it can't read gives a row with +to+ nil and the line's code.
      #
      # Where knobs start (each row's +from+): +start:+ ({ knob => value }),
      # then `knob :x, v` lines, then the params of a fit patch the take
      # made and gave a track (`kick = fit_patch :kick_fit, code, tune:
      # (30.0..110.0).at(51.3)` and `design :kick, kick`: :"kick/tune"
      # starts at 51.3), then +patch:+ ({ track => a graph document's
      # path or a FitPatch::Patch }: its params' values), then +defaults:+
      # (the live take passes the session's knob defaults).  An `undo` puts
      # back the knobs of the last line it hasn't undone (a row of kind
      # :undo; undo undoes the last command, which for a tuning session is
      # that line).
      class Reader
        # One change of a knob: +knob+ (its name), +from+ and +to+ (values
        # in the knob's units; nil where unknown), +pos+ (the timeline
        # position it landed, in whole notes), +seconds+ (that position in
        # seconds at the take's tempo), +line+ (the take line's index, from
        # 0), +kind+ (:turn, :gesture (a held key's keyframes), :ramp (over:),
        # :level, :undo), +steps+ (a gesture's keys [[seconds, value], ...]
        # or its raw steps [[frames, value], ...] when the take kept them),
        # +code+ (the line).
        Turn = Data.define(:knob, :from, :to, :pos, :seconds, :line, :kind, :steps, :code) do
          def to_s
            f = from.nil? ? '?' : Reader.number(from)
            t = to.nil? ? '?' : Reader.number(to)
            "#{format('%8.3f', seconds.to_f)} s  #{knob.inspect}  #{f} -> #{t}  (#{kind})"
          end
        end

        # A flip of an A/B (`ab`): +track+ (nil: the last pair), +pos+,
        # +seconds+, +line+, +code+.  Which one was heard after it
        # alternates from the patch (each pair starts on the patch).
        Flip = Data.define(:track, :pos, :seconds, :line, :code, :hearing)

        # What the reader found: +rows+ (Turns in take order), +flips+,
        # +start+ and +finish+ ({ knob => value } before the first and after
        # the last row, for the knobs the rows turned), +tracks+ ({ track =>
        # document path } of fit patches and +patch:+ entries), +bpm+,
        # +lines+ (the take's line codes).
        Result = Data.define(:rows, :flips, :start, :finish, :tracks, :bpm, :lines) do
          # The knobs whose value at the end differs from the start.
          def changed = finish.select { |k, v| !v.nil? && start[k] != v }.keys

          # The rows of +knob+.
          def of(knob) = rows.select { |r| r.knob == knob }

          # { knob => rows } in the order each knob was first turned (the
          # first ones are what he heard first).
          def by_knob = rows.group_by(&:knob)

          # The rows that turned +knob+ back toward where it was before the
          # turn ahead of them (a knob swept and returned to is one he was
          # unsure of): [[row, previous row], ...].
          def reversals
            rows.group_by(&:knob).flat_map { |_, list|
              list.each_cons(2).select { |a, b|
                a.from && a.to && b.to && b.from && ((a.to - a.from) * (b.to - b.from)).negative?
              }.map { |a, b| [b, a] }
            }
          end

          # The params of +track+'s document at the start (+which+ :start)
          # or the end (:finish): { param => value }, the document's values
          # for params no row turned.
          def values(track, which = :finish)
            path = tracks[track] or raise ArgumentError, "no graph document known for track #{track.inspect} (Take.read(..., patch: { #{track}: path }))"
            doc = GraphIO.parse(path)
            state = which == :start ? start : finish
            doc.declarations.to_h { |p, decl|
              k = Session::Name.param(track, p)
              [p, state.key?(k) && !state[k].nil? ? state[k] : decl.default]
            }
          end

          # One note of +track+'s patch at the start and at the end of the
          # take ({ start: [SFloat, ...], finish: [...] }, HandTune.render:
          # offline, the same values the same samples), +note+ held +hold+
          # seconds in +seconds+.  With +dir+, also writes start.wav and
          # finish.wav there (Returns the Hash with :paths).
          def renders(track, note: 60, velocity: 0.8, hold: nil, seconds: 1.0, dir: nil)
            path = tracks[track] or raise ArgumentError, "no graph document known for track #{track.inspect} (Take.read(..., patch: { #{track}: path }))"
            out = %i[start finish].to_h { |w| [w, HandTune.render(path, values(track, w), note: note, velocity: velocity, hold: hold, seconds: seconds)] }
            if dir
              FileUtils.mkdir_p(dir)
              out[:paths] = %i[start finish].to_h { |w|
                f = File.join(dir, "#{track}_#{w}.wav")
                MB::Sound.write(f, out[w], sample_rate: HandTune::RATE, overwrite: true)
                [w, f]
              }
            end
            out
          end

          # The rows as a table, one per line.
          def to_s
            head = "take: #{rows.length} turn#{'s' unless rows.length == 1} of #{rows.map(&:knob).uniq.length} knobs, #{flips.length} A/B flip#{'s' unless flips.length == 1}"
            ch = changed.map { |k| "#{k} #{Reader.number(start[k])} -> #{Reader.number(finish[k])}" }
            [head, *rows.map { |r| "  #{r}" }, ("changed: #{ch.join('; ')}" unless ch.empty?)].compact.join("\n")
          end

          def inspect = "#<#{to_s.lines.first.strip}>"
        end

        # Raised for a text that isn't a take script.
        class Error < ArgumentError; end

        # Units of value calls: method => factor (seconds and Hz).
        UNITS = { hz: 1.0, khz: 1000.0, ms: 0.001, s: 1.0, sec: 1.0, seconds: 1.0, second: 1.0 }.freeze

        # Note lengths in whole notes (`1.n8`).
        NOTE_LENGTHS = { n1: 1r, n2: 1/2r, n4: 1/4r, n8: 1/8r, n16: 1/16r, n32: 1/32r, n64: 1/64r, n3: 1/3r, n6: 1/6r, n12: 1/12r, n24: 1/24r, n48: 1/48r }.freeze

        # Calls that turn a knob.
        TURNS = %i[turn move].freeze

        class << self
          # Reads +source+ (a path to a saved take, its text, or a Take):
          # see the class description.  Returns a Result.
          def read(source, start: {}, patch: {}, defaults: {})
            text = case source
                   when Take then source.to_ruby
                   when String then source.include?("\n") || !File.file?(source) ? source : File.read(source)
                   else raise Error, "Take.read takes a take's path, its text, or a Take (got #{source.class})"
                   end
            new(text, start: start, patch: patch, defaults: defaults).result
          end

          # +v+ printed short (6 significant figures).
          def number(v)
            return v.inspect unless v.is_a?(Numeric)
            x = v.to_f
            x == x.round && x.abs < 1e9 ? x.round.to_s : format('%.6g', x)
          end
        end

        def initialize(text, start: {}, patch: {}, defaults: {})
          @text = text
          @start = start.transform_keys(&:to_sym)
          @defaults = defaults.transform_keys(&:to_sym)
          @patch = patch.to_h { |t, p| [t.to_sym, p.respond_to?(:path) ? p.path : p.to_s] }
          @fits = {}    # (local name or fit name => [path, { param => value }])
          @tracks = {}  # (track => document path)
          @known = {}   # (knob => value at the take's start, as found)
          @state = {}   # (knob => value now)
          @rows = []
          @flips = []
          @lines = []
          @undone = []
          @hearing = Hash.new(:patch)
          @bpm = 120.0
        end

        # The Result (see Result).
        def result
          tree = Prism.parse(@text)
          raise Error, "not Ruby: #{tree.errors.first&.message}" unless tree.success?
          replay = find_replay(tree.value) or raise Error, "not a take script (no MB::Sound::Take::Replay.new(...) do |r| ... end)"
          read_start(replay)
          @gestures = read_gestures(replay)
          @patch.each { |t, path| add_track(t, path) }
          body = replay.block&.body&.body || []
          body.each { |st| read_statement(st) }
          start = {}
          @rows.each { |r| start[r.knob] = r.from unless start.key?(r.knob) }
          finish = @rows.to_h { |r| [r.knob, @state[r.knob]] }
          Result.new(rows: @rows.freeze, flips: @flips.freeze, start: start.freeze, finish: finish.freeze, tracks: @tracks.dup.freeze, bpm: @bpm,
                     lines: @lines.freeze)
        end

        private

        # The `MB::Sound::Take::Replay.new(...) do |r| ... end` call.
        def find_replay(root)
          stack = [root]
          until stack.empty?
            n = stack.shift
            return n if n.is_a?(Prism::CallNode) && n.name == :new && n.receiver&.slice.to_s.end_with?('Replay') && n.block
            stack.concat(n.compact_child_nodes)
          end
          nil
        end

        def read_start(call)
          kw = keywords(call)
          bpm = kw[:bpm] && value(kw[:bpm])
          @bpm = bpm.to_f if bpm.is_a?(Numeric) && bpm > 0
        end

        # The raw gesture steps: { [knob, pos] => steps }.
        def read_gestures(call)
          out = {}
          (call.block.body&.body || []).each do |st|
            next unless st.is_a?(Prism::CallNode) && st.name == :gestures && st.receiver&.slice == 'r'
            rows = st.arguments&.arguments&.first
            next unless rows.is_a?(Prism::ArrayNode)
            rows.elements.each do |row|
              next unless row.is_a?(Prism::ArrayNode) && row.elements.length >= 4
              name, _epoch, pos, steps = row.elements.map { |e| value(e) }
              out[[name, pos]] = steps if name.is_a?(Symbol)
            end
          end
          out
        end

        # One `r.line pos, lands, <<~'RUBY'` statement.
        def read_statement(st)
          return unless st.is_a?(Prism::CallNode) && st.name == :line && st.receiver&.slice == 'r'
          args = st.arguments&.arguments || []
          issued = value(args[0])
          lands = value(args[1])
          code = string_of(args[2])
          return unless code
          index = @lines.length
          @lines << code
          tree = Prism.parse(code)
          return unless tree.success?
          landings = Array(lands).map { |l| l.is_a?(Array) ? l[0] : l }.select { |l| l.is_a?(Numeric) }
          @line_ctx = { index: index, issued: issued.is_a?(Numeric) ? issued : 0r, landings: landings, code: code.strip, rows: [] }
          tree.value.statements.body.each { |s| read_code(s) }
          @undone << @line_ctx[:rows] unless @line_ctx[:rows].empty?
        end

        # The text of a string literal +node+ (a squiggly heredoc of several
        # lines is an InterpolatedStringNode of plain parts), or nil.
        def string_of(node)
          return node.unescaped if node.respond_to?(:unescaped)
          return nil unless node.is_a?(Prism::InterpolatedStringNode) && node.parts.all? { |x| x.is_a?(Prism::StringNode) }
          node.parts.map(&:unescaped).join
        end

        # A console statement of a line (assignments, calls; `;` statements).
        def read_code(node)
          case node
          when Prism::LocalVariableWriteNode
            if node.value.is_a?(Prism::CallNode) && node.value.name == :fit_patch
              fit = read_fit(node.value)
              @fits[node.name] = fit if fit
            end
          when Prism::CallNode
            return read_call(node) if node.receiver.nil?
          when Prism::StatementsNode, Prism::ParenthesesNode, Prism::BeginNode
            node.compact_child_nodes.each { |c| read_code(c) }
          end
        end

        def read_call(node)
          args = positional(node)
          case node.name
          when *TURNS then read_turn(node, args)
          when :level then read_level(node, args)
          when :knob then read_knob(args, keywords(node))
          when :fit_patch then (f = read_fit(node)) && (@fits[f[2]] = f)
          when :track, :design then read_track(args)
          when :tune then read_tune(node, args)
          when :ab then read_ab(node, args)
          when :undo then read_undo(node)
          end
        end

        # `fit_patch :name, code, param: (lo..hi).at(v), path: ...`:
        # [path, { param => value }, name].
        def read_fit(node)
          args = positional(node)
          name = value(args[0])
          return nil unless name.is_a?(Symbol)
          kw = keywords(node)
          path = kw[:path] ? value(kw.delete(:path)) : nil
          kw.delete(:description)
          params = kw.to_h { |k, v|
            v = v.elements.first if v.is_a?(Prism::ArrayNode)
            [k, value(v)]
          }.transform_values { |v| v.respond_to?(:default) ? v.default : v }
          path = File.expand_path(path.to_s) if path
          path ||= File.join(FitPatch.dir, "#{name}#{GraphIO::EXTENSION}")
          [path, params, name]
        end

        # `tune :kick, code, ref:, play:, as:, param: (lo..hi).at(v), ...`
        # (HandTuneMethods#tune): the fit patch :kick_fit (or as:) on track
        # :kick, its knobs starting at the params' values.
        def read_tune(node, args)
          track = value(args[0])
          return unless track.is_a?(Symbol)
          kw = keywords(node)
          as = kw[:as] ? value(kw[:as]) : nil
          %i[ref play as].each { |k| kw.delete(k) }
          params = kw.to_h { |k, v|
            v = v.elements.first if v.is_a?(Prism::ArrayNode)
            v = value(v)
            [k, v.respond_to?(:default) ? v.default : v]
          }
          name = as.is_a?(Symbol) ? as : :"#{track}_fit"
          @tracks[track] = File.join(FitPatch.dir, "#{name}#{GraphIO::EXTENSION}")
          params.each { |p, v| seed(Session::Name.param(track, p), v) }
        end

        # `track :kick, fit` / `design :kick, fit, clip`: links the track
        # to a fit patch made in the take (a local or `fit_patch(...)`).
        def read_track(args)
          track = value(args[0])
          return unless track.is_a?(Symbol)
          args.drop(1).each do |a|
            fit = case a
                  when Prism::LocalVariableReadNode then @fits[a.name]
                  when Prism::CallNode
                    # (a line parsed alone reads an earlier line's local as a call)
                    if a.name == :fit_patch then read_fit(a)
                    elsif a.receiver.nil? && a.arguments.nil? then @fits[a.name]
                    end
                  end
            next unless fit
            @tracks[track] = fit[0]
            fit[1].each { |p, v| seed(Session::Name.param(track, p), v) }
          end
        end

        # Adds +track+'s document +path+ (the +patch:+ option): its params'
        # values as where its knobs start.
        def add_track(track, path)
          @tracks[track] = path
          GraphIO.parse(path).declarations.each { |p, decl| seed(Session::Name.param(track, p), decl.default) }
        rescue StandardError
          nil
        end

        # Records where +knob+ starts unless something said so before.
        def seed(knob, v)
          return if v.nil? || @known.key?(knob)
          @known[knob] = v
        end

        def read_knob(args, kw)
          name = value(args[0])
          return unless name.is_a?(Symbol)
          v = args[1] ? value(args[1]) : nil
          v = v.default if v.respond_to?(:default)
          @state[name] = v if v.is_a?(Numeric)
          seed(name, v) if v.is_a?(Numeric)
        end

        def read_turn(node, args)
          name = value(args[0])
          return unless name.is_a?(Symbol)
          kw = keywords(node)
          keys = keyframes(node)
          kind = :turn
          steps = nil
          if keys
            kind = :gesture
            steps = keys
            to = keys.last&.last
          else
            to = args[1] ? value(args[1]) : nil
            to = nil unless to.is_a?(Numeric)
            kind = :ramp if kw.key?(:over)
            kind = :follow if kw.key?(:follow)
          end
          raw = @gestures[[name, landing]] if kind == :gesture
          steps = raw if raw
          add_row(name, to, kind, steps)
        end

        def read_level(_node, args)
          name = value(args[0])
          return unless name.is_a?(Symbol) && args[1]
          v = value(args[1])
          v = v.to_f if v.is_a?(Numeric)
          add_row(Session::Name.level(name), v.is_a?(Numeric) ? v : nil, :level, nil)
        end

        def read_ab(_node, args)
          track = value(args[0])
          return if args[1] # (a setup or :off)
          return if track == :off
          key = track || @last_ab
          @hearing[key] = @hearing[key] == :patch ? :ref : :patch
          @last_ab = key
          @flips << Flip.new(track: track, pos: landing, seconds: seconds_at(landing), line: @line_ctx[:index], code: @line_ctx[:code], hearing: @hearing[key])
        end

        def read_undo(_node)
          rows = @undone.pop or return
          rows.reverse_each do |r|
            add_row(r.knob, r.from, :undo, nil)
          end
          @line_ctx[:rows] = [] # (an undo isn't undone by the next undo: redo! is)
        end

        def add_row(knob, to, kind, steps)
          from = current(knob)
          @state[knob] = to unless to.nil?
          @state[knob] = nil if to.nil? && kind != :undo
          pos = landing
          row = Turn.new(knob: knob, from: from, to: to, pos: pos, seconds: seconds_at(pos), line: @line_ctx[:index], kind: kind, steps: steps,
                         code: @line_ctx[:code])
          @rows << row
          @line_ctx[:rows] << row
        end

        # Where +knob+ is now (see the class description), or nil.
        def current(knob)
          return @state[knob] if @state.key?(knob)
          return @start[knob] if @start.key?(knob)
          return @known[knob] if @known.key?(knob)
          return @defaults[knob] if @defaults.key?(knob)
          Session::Name[knob].level? ? 1.0 : nil # (a track's level is unity until set: Session::Faders)
        end

        # The landing position of the change being read: the line's next
        # landing, else its issue time.
        def landing
          l = @line_ctx[:landings]
          i = @line_ctx[:rows].length
          l[i] || l.last || @line_ctx[:issued]
        end

        def seconds_at(pos) = Sequence::TempoMap.seconds_at(pos.to_r, @bpm)

        # A `turn` call's keyframes: [[seconds, value], ...] from its
        # non-Symbol Hash keys, or nil.
        def keyframes(node)
          h = node.arguments&.arguments&.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
          return nil unless h
          keys = h.elements.filter_map { |e|
            next unless e.is_a?(Prism::AssocNode) && !e.key.is_a?(Prism::SymbolNode)
            t = time_of(e.key)
            v = value(e.value)
            [t, v.is_a?(Numeric) ? v : nil]
          }
          keys.empty? ? nil : keys
        end

        # A keyframe time in seconds (0, note lengths, bars, Lengths).
        def time_of(node)
          if node.is_a?(Prism::CallNode) && node.receiver && node.arguments.nil?
            n = value(node.receiver)
            if n.is_a?(Numeric)
              return seconds_at(n * NOTE_LENGTHS[node.name]) if NOTE_LENGTHS[node.name]
              return seconds_at(n) if %i[bar bars whole].include?(node.name)
              return n * 60 / @bpm if %i[beat beats].include?(node.name)
            end
          end
          v = value(node)
          v.is_a?(Numeric) ? seconds_at(v) : nil # (plain numbers are bars of 4/4)
        end

        def positional(node) = (node.arguments&.arguments || []).reject { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::BlockArgumentNode) }

        # { key => node } of a call's Symbol keywords.
        def keywords(node)
          h = (node.arguments&.arguments || []).find { |a| a.is_a?(Prism::KeywordHashNode) }
          return {} unless h
          h.elements.each_with_object({}) { |e, out|
            out[e.key.unescaped.to_sym] = e.value if e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode)
          }
        end

        # The value of literal +node+ (see the class description), or a
        # Param::Ranged for `(lo..hi).at(v)`, or nil.
        def value(node)
          case node
          when nil then nil
          when Prism::IntegerNode, Prism::FloatNode then node.value
          when Prism::RationalNode then node.value
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::StringNode then node.unescaped
          when Prism::NilNode then nil
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::ArrayNode then node.elements.map { |e| value(e) }
          when Prism::ParenthesesNode then value(node.body&.body&.last)
          when Prism::RangeNode
            lo = value(node.left)
            hi = value(node.right)
            lo.is_a?(Numeric) && hi.is_a?(Numeric) ? (node.exclude_end? ? lo...hi : lo..hi) : nil
          when Prism::CallNode then call_value(node)
          end
        rescue StandardError
          nil
        end

        def call_value(node)
          args = node.arguments&.arguments || []
          if node.receiver.nil?
            return nil
          end
          r = value(node.receiver)
          if args.empty?
            return -r if node.name == :-@ && r.is_a?(Numeric)
            return r * UNITS[node.name] if r.is_a?(Numeric) && UNITS[node.name]
            return 10.0**(r / 20.0) if r.is_a?(Numeric) && %i[db dB].include?(node.name)
            return r if r.is_a?(Numeric) && %i[to_f to_r].include?(node.name)
            return nil
          end
          if args.length == 1
            a = value(args[0])
            case node.name
            when :/ then return r.is_a?(Numeric) && a.is_a?(Numeric) && a != 0 ? (r.is_a?(Integer) && a.is_a?(Integer) ? Rational(r, a) : r / a) : nil
            when :* then return r.is_a?(Numeric) && a.is_a?(Numeric) ? r * a : nil
            when :+ then return r.is_a?(Numeric) && a.is_a?(Numeric) ? r + a : nil
            when :- then return r.is_a?(Numeric) && a.is_a?(Numeric) ? r - a : nil
            when :at then return r.is_a?(Range) && a.is_a?(Numeric) ? Param::Ranged.new(range: r, default: a) : nil
            end
          end
          nil
        end
      end

      # The turns of this take (see Take::Reader), knobs starting at the
      # session's knob defaults where nothing in the take says otherwise.
      #
      #     take.turns
      #     take.turns.changed
      #     take.turns.renders(:kick, note: 36, seconds: 0.5)
      def turns(start: {}, patch: {})
        defaults = session.knobs.to_h { |n, k| [n, k.spec.default] }
        live = session.arrangement.tracks.keys.filter_map { |t|
          path = Reference.document_path(session, t)
          path && [t, path]
        }.to_h
        Reader.read(self, start: start, patch: live.merge(patch), defaults: defaults)
      end

      # Reads the saved take at +path+ (or its text) as knob turns (see
      # Take::Reader).
      #
      #     MB::Sound::Take.read('tmp/takes/take_20261103_kick.rb').changed
      def self.read(path, start: {}, patch: {}, defaults: {})
        Reader.read(path, start: start, patch: patch, defaults: defaults)
      end
    end
  end
end

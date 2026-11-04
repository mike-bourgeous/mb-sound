require 'digest'
require 'fileutils'
require 'prism'

module MB
  module Sound
    # A fitted voice as a patch with named knobs (hand-tune-1, 2026-11-03;
    # the maintainer on the 909 kick fit: "I think I would need to hand
    # tune this and have you figure out what I did").  A fit prints its
    # voice as console Ruby with the fitted numbers as literals
    # (`kit(grid(16, kick: 'X...'), seed: 1) { voice(:kick) { |h| h.body(51.328155, decay: 0.468972, ...) } }`);
    # FitPatch turns that code and the fit's params (each a value inside
    # the fit's range) into a graph document whose `param` lines are those
    # numbers, the form the init voice has (presets/init.mbg.rb).  On a
    # track every param is a track knob (`:"kick/tune"`, bounded by the
    # fit's range; Arrangement::TrackKnobs), so `design :kick, fit` opens
    # it with every fitted value turnable, and a setting read once while
    # building (a softclip's threshold) is a build knob (each turn
    # rebuilds the track; GraphNode.build_value).
    #
    # The literals are found by walking the code with Prism (no eval): a
    # numeric literal names a param when the param's value printed to the
    # literal's precision is the literal (a Float literal for a Float
    # value, an Integer for an Integer), a keyword's literal preferring the
    # param named like the keyword.  A param found nowhere (a value the
    # printer derived, `d = 2 ** (drive * 2)` printed as `d = 2.460364`) is
    # listed in #missing; name the printed number instead (`d:
    # (1.0..8.0).at(2.460364)`) or leave it a literal (the inspector binds
    # literals too).  The voice's source (the first argument of the
    # outermost `synth`, `kit`, `tr909`, `tr808`, `sampler`, or `struck`
    # call, or its receiver: `CLIP`, `grid(...)`) becomes the document's
    # `midi` input, so a track's clip plays it.
    #
    # The document is checked by loading it (GraphIO.load, which walks it
    # without eval) and reading a block.  Fits of private samples stay
    # private: the documents go to FitPatch.dir (the main checkout's
    # tmp/fits/ when mb-sound runs from a checkout), never a shelf.
    #
    #     kick = fit_patch :kick_fit, "kit(grid(16, kick: 'X...'), seed: 1) { voice(:kick) { |h| ... } }",
    #       tune: (30.0..110.0).at(51.328155), decay: (0.1..2.0).at(0.468972), clip: (0.2..1.0).at(0.205115)
    #     design :kick, kick, seq(C2).n4.loop
    module FitPatch
      # Raised for code or params FitPatch can't turn into a document
      # (#document has the text when one was written).
      class Error < ArgumentError
        attr_reader :document

        def initialize(message, document: nil)
          super(message)
          @document = document
        end
      end

      # Calls whose first argument (or receiver) is the voice's source.
      VOICE_CALLS = %i[synth kit drum_kit tr909 tr808 sampler struck].freeze

      # Where a literal was replaced: the param +name+, its +line+ and
      # +column+ in the code (1-based), the literal's +text+.
      Site = Data.define(:name, :line, :column, :text)

      # A written fit patch: +name+, +path+ (the document, where it is
      # edited), +version+ (the immutable copy of this text the track plays;
      # see .version_path), +entry+ (a Library::Entry for `track`/`design`;
      # see #library_entry), +params+ ({ name => MB::Sound::Param }),
      # +sites+ (Sites), +missing+ (param names found nowhere in the code),
      # +skipped+ ({ param => why } for those found only where a param
      # can't go), +text+ (the document).
      Patch = Data.define(:name, :path, :version, :entry, :params, :sites, :missing, :skipped, :text) do
        # The Library::Entry `track :kick, fit` and `design :kick, fit` play
        # (Arrangement::InstrumentPatch takes anything answering it).
        def library_entry = entry

        # { param => value } at the fit (the knobs' starting values).
        def values = params.transform_values(&:default)

        def to_s
          knobs = params.keys.map { |k| k.to_s }.join(', ')
          left = missing - skipped.keys
          miss = left.empty? ? '' : "; not in the code: #{left.join(', ')} (name the number it printed instead, or bind it in the inspector)"
          miss += "; left as numbers: #{skipped.map { |k, why| "#{k} (#{why})" }.join('; ')}" unless skipped.empty?
          "fit patch #{name}: #{params.length} knob#{'s' unless params.length == 1} (#{knobs}) in #{path}#{miss}"
        end

        def inspect = "#<#{self}>"
      end

      module_function

      # The directory for fit documents: $MB_SOUND_FITS, else tmp/fits/ in
      # the main checkout when mb-sound runs from a git checkout (as
      # ui.note's notes: Internal.checkout_tmp_dir), else fits/ in the user
      # data directory.
      def dir
        env = ENV['MB_SOUND_FITS']
        return File.expand_path(env) unless env.to_s.empty?
        tmp = Internal.checkout_tmp_dir
        return File.join(tmp, 'fits') if tmp
        File.join(File.dirname(Internal.help_data_dir), 'fits')
      end

      # The params of +given+ ({ name => Param::Ranged, a [Param::Ranged,
      # description] pair, or a Param }) as { name => MB::Sound::Param }
      # (declared, so values outside their ranges raise).
      def declare(given)
        given.to_h { |name, spec|
          name = name.to_sym
          ranged, desc = spec.is_a?(Array) ? spec : [spec, nil]
          next [name, ranged] if ranged.is_a?(Param)
          unless ranged.is_a?(Param::Ranged)
            raise Error, "fit_patch #{name}: give the fit's range and value, (lo..hi).at(value) (got #{ranged.inspect})"
          end
          unless ranged.default.is_a?(Numeric)
            raise Error, "fit_patch #{name}: fits print plain numbers; give it as one (#{name}: (lo..hi).at(0.5)), not #{ranged.default.inspect}"
          end
          [name, Param.declare(name, ranged, description: desc)]
        }
      end

      # The document text for voice +code+ (console Ruby with the fit's
      # numbers as literals) with +params+ ({ name => MB::Sound::Param }:
      # see .declare) as `param` lines.  Returns [text, sites, missing,
      # skipped ({ param => why its literal stays a number })].  Literals
      # inside a Range, typed values (`4.07.db`, `12.cents`), and runtime
      # blocks (`then`) stay numbers: those places take no nodes.
      #
      # A param the code names (`h.body(tune, ...)`, as a document's body
      # does) is found there too (a Site whose text is the name).  With
      # +match:+ (param names), only those params' values name literals,
      # every other number staying one (HandTune.retune: a new block's
      # numbers become its new params).  +saved:+ is the header's time
      # (nil leaves it out: Take::Reader's rebuilt versions).
      def document(code, params, name:, description: nil, input: :midi, match: nil, saved: Time.now)
        code = unroll(unwrap(code.to_s), name)
        result = Prism.parse(code)
        raise Error, "fit_patch #{name}: the code doesn't parse: #{result.errors.first&.message}" unless result.success?
        bad = params.keys.select { |k| !k.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) || VOICE_CALLS.include?(k) || k == input }
        raise Error, "fit_patch #{name}: #{bad.map(&:inspect).join(', ')} can't name a param (lowercase words; not #{input} or a voice call)" unless bad.empty?
        calls = params.keys.select { |k| GraphIO::Registry.top_level.include?(k) }
        unless calls.empty?
          raise Error, "fit_patch #{name}: #{calls.map(&:inspect).join(', ')} can't name a param: #{calls.length == 1 ? 'it is a function' : 'they are functions'} " \
                       "documents call (#{calls.first}_level:)"
        end
        locals = local_names(result.value) & params.keys
        unless locals.empty?
          raise Error, "fit_patch #{name}: the code assigns #{locals.join(', ')} itself; give #{locals.length == 1 ? 'that param' : 'those params'} another name (#{locals.first}_value:)"
        end

        edits = []
        source = voice_source(result.value)
        raise Error, "fit_patch #{name}: no voice played from a clip in the code (#{VOICE_CALLS.first(4).join(', ')}, ... with the clip first)" unless source
        edits << [source.location.start_offset, source.location.end_offset, input.to_s] unless source.slice == input.to_s

        sites = []
        skipped = {}
        matching = match ? params.slice(*match.map(&:to_sym)) : params
        literals(result.value) do |node, key, why|
          hits = matching.select { |_, p| matches?(node, p.default) }.keys
          next if hits.empty?
          if why
            hits.each { |h| skipped[h] ||= "#{node.slice} is #{why}" }
            next
          end
          pick = hits.include?(key) ? key : closest(node, hits.to_h { |h| [h, params[h].default] })
          unless pick
            loc = node.location
            raise Error, "fit_patch #{name}: the literal #{node.slice} at #{loc.start_line}:#{loc.start_column + 1} matches #{hits.map(&:inspect).join(' and ')}: " \
                         'give the values with more digits, or one of them under another name'
          end
          loc = node.location
          edits << [loc.start_offset, loc.end_offset, pick.to_s]
          sites << Site.new(name: pick, line: loc.start_line, column: loc.start_column + 1, text: node.slice)
        end
        references(result.value, params.keys).each do |node|
          loc = node.location
          sites << Site.new(name: node.name, line: loc.start_line, column: loc.start_column + 1, text: node.slice)
        end
        sites.sort_by! { |x| [x.line, x.column] }
        missing = params.keys - sites.map(&:name).uniq

        body = code.b
        edits.sort_by { |s, _, _| -s }.each { |s, e, text| body[s...e] = text.b }
        body = body.force_encoding(code.encoding)

        meta = { name: name.to_s, kind: :synth, saved: saved&.utc&.strftime('%Y-%m-%dT%H:%M:%SZ'), mb_sound: GraphIO.library_version, from: 'fit_patch',
                 description: description || "A fitted voice with every fitted number a knob (fit_patch, hand-tune-1): #{params.keys.join(', ')}" }.compact
        lines = ['# mb-sound graph document: a Ruby subset that MB::Sound.preset and', '# MB::Sound::GraphIO.load read without running it (no eval).']
        lines << GraphIO.graph_line(meta.map { |k, v| "#{k}: #{RubyValue.to_ruby(v)}" })
        lines << GraphIO.inputs_line(input => :notes)
        params.each { |pname, p| lines << p.document_line(p.default) unless missing.include?(pname) }
        lines << '' << body.strip
        [lines.join("\n") + "\n", sites.freeze, missing.freeze, skipped.slice(*missing).freeze]
      end

      # Writes the document for +code+ and +params+ (see .document; params
      # as .declare takes them) to +path+ (default: .dir/NAME.mbg.rb,
      # replacing an older fit of that name) and its version (.write),
      # checks that it loads and plays a block, and returns a Patch.
      def save(name, code, params, path: nil, description: nil, match: nil)
        name = name.to_sym
        raise Error, "fit_patch takes a name for the patch (a Symbol like :kick_fit), got #{name.inspect}" unless name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
        params = declare(params)
        raise Error, "fit_patch #{name}: give the fitted numbers as knobs (tune: (30.0..110.0).at(51.3), ...)" if params.empty?
        text, sites, missing, skipped = document(code, params, name: name, description: description, match: match)
        check(name, text)
        path, version, entry = write(name, text, path: path)
        Patch.new(name: name, path: path, version: version, entry: entry, params: params.reject { |k, _| missing.include?(k) }.freeze, sites: sites,
                  missing: missing, skipped: skipped, text: text.freeze)
      end

      # A fit patch made from an existing graph document (hand-tune-3: the
      # tuner starts a hand-tune from a library instrument, the init
      # voice, or a fit's document, not only from a fit's printed code):
      # +source+ is a Library::Entry of a graph document (L.inst.init), a
      # document's path, or its text.  The document is the same but for its
      # header's name (+name+), `from: "fit_patch"`, and a description
      # saying what it was made from, so tune, retune, and refine take it
      # like any fit; it is written and checked as .save writes fits
      # (.dir/NAME.mbg.rb and its version).  Raises Error for a source that
      # isn't a graph document played from a `midi` notes input with
      # params.  Returns a Patch (no sites: its params were params
      # already).
      def adopt(name, source, path: nil)
        name = name.to_sym
        raise Error, "fit_patch takes a name for the patch (a Symbol like :kick_fit), got #{name.inspect}" unless name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
        text, params = adopted(name, source)
        check(name, text)
        path, version, entry = write(name, text, path: path)
        Patch.new(name: name, path: path, version: version, entry: entry, params: params, sites: [].freeze, missing: [].freeze,
                  skipped: {}.freeze, text: text.freeze)
      end

      # [document text, params] .adopt writes for fit +name+ from
      # +source+, without writing anything (Take::Reader rebuilds a take's
      # versions with it).
      def adopted(name, source)
        text, from = adopt_source(source)
        doc = begin
          GraphIO.parse(text)
        rescue GraphIO::LoadError => e
          raise Error, "tune: #{from} isn't a graph document (#{e.message.lines.first&.strip})"
        end
        raise Error, "tune: #{from} plays from no midi input (inputs #{doc.inputs.inspect}): an instrument's document does" unless Array(doc.inputs.is_a?(Hash) ? doc.inputs.keys : doc.inputs).include?(:midi)
        params = doc.declarations.select { |_, p| p.is_a?(Param) }
        raise Error, "tune: #{from} has no params to turn" if params.empty?
        mark = "Tuned from #{from} (tune, hand-tune-3)"
        about = doc.description.to_s.sub(/\ATuned from .*? \(tune, hand-tune-3\)(: )?/, '')
        text = rewrite_meta(text, name: name.to_s, from: 'fit_patch', description: about.empty? ? mark : "#{mark}: #{about}")
        [text, params.freeze]
      end

      # [text, what it is called] of an adopt source.
      def adopt_source(source)
        case source
        when Library::Entry
          loc = source.location
          unless source.settings.is_a?(Hash) && source.settings[:document] && loc && File.file?(loc)
            raise Error, "tune: #{source.name} isn't a graph document (Ruby code builds it): pass it as an instrument to tune its knobs by ear (no retune)"
          end
          [File.read(loc), (source.head_path rescue source.name.to_s)]
        when String, Pathname
          s = source.to_s
          s.include?("\n") ? [s, 'the document given'] : [File.read(File.expand_path(s)), File.basename(s)]
        else
          raise Error, "tune: give the voice's code, a graph document (a path), or a library instrument (L.inst.init), not #{source.class}"
        end
      rescue SystemCallError => e
        raise Error, "tune: #{e.message}"
      end

      # +text+ (a graph document) with its `graph` header's keywords in
      # +values+ ({ key => value }) replaced, or added after the others.
      def rewrite_meta(text, values)
        tree = Prism.parse(text)
        call = tree.value.statements.body.find { |st| st.is_a?(Prism::CallNode) && st.receiver.nil? && st.name == :graph }
        raise Error, 'tune: the document has no graph header' unless call && call.arguments
        hash = call.arguments.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
        edits = []
        left = values.dup
        hash&.elements&.each do |el|
          next unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          k = el.key.unescaped.to_sym
          next unless left.key?(k)
          edits << [el.value.location.start_offset, el.value.location.end_offset, RubyValue.to_ruby(left.delete(k))]
        end
        unless left.empty?
          at = (hash || call.arguments.arguments.last).location.end_offset
          edits << [at, at, left.map { |k, v| ", #{k}: #{RubyValue.to_ruby(v)}" }.join]
        end
        out = text.b
        edits.sort_by { |s, _, _| -s }.each { |s, e, t| out[s...e] = t.b }
        out.force_encoding(text.encoding)
      end

      # True when +x+ is something .adopt takes (an Entry, or a path of a
      # graph document) rather than a fit's printed code.
      def document_source?(x)
        return true if x.is_a?(Library::Entry) || x.is_a?(Pathname)
        x.is_a?(String) && !x.include?("\n") && x.end_with?(GraphIO::EXTENSION)
      end

      # The canonical path of fit +name+'s document (.dir/NAME.mbg.rb), or
      # +path+ expanded.
      def path_of(name, path = nil)
        path = File.expand_path(path || File.join(dir, "#{name}#{GraphIO::EXTENSION}"))
        path.end_with?('.rb') ? path : path + GraphIO::EXTENSION
      end

      # Writes document +text+ of fit +name+ to its path (.path_of: where
      # it is read and edited) and its version (.version_path), and returns
      # [path, version path, entry]: the Library::Entry a track plays,
      # whose document is the version (so an undo, or a rebuild after the
      # file was edited, plays the text that was loaded), with the path as
      # its lineage (InstrumentPatch.same_instrument?: a new version of the
      # same fit is the same instrument, so turned knobs carry).
      def write(name, text, path: nil)
        path = path_of(name, path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
        version = version_path(text, name)
        entry = Library.document_entry(version, Library.session_shelf)
        entry = entry.with(settings: entry.settings.merge(lineage: path))
        [path, version, entry]
      end

      # The immutable copy of document +text+ of fit +name+:
      # .dir/versions/NAME-<12 hex digits of its SHA-256>.mbg.rb, written
      # if it isn't there yet.  The same text, the same path (Take::Reader
      # renders a take's start and end from the versions its lines made).
      def version_path(text, name)
        digest = Digest::SHA256.hexdigest(text)[0, 12]
        path = File.join(dir, 'versions', "#{name}-#{digest}#{GraphIO::EXTENSION}")
        return path if File.file?(path) && File.read(path) == text
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
        path
      end

      # Notes the check plays at once (a kit voice answers only its own
      # notes: kick 36, snare 38, clap 39, hats 42/46; synths take any).
      CHECK_NOTES = [36, 38, 39, 42, 46, 60].freeze

      # Loads document +text+ with a clip of CHECK_NOTES and reads a block
      # of it; raises Error (with the text) if it doesn't load or play.
      def check(name, text)
        clip = MB::Sound.seq(CHECK_NOTES).n4
        g = MB::Sound.keeping_random_state { GraphIO.load(text, inputs: { midi: clip }) }
        g = g.first if g.is_a?(Array)
        g = g.to_a.first if g.respond_to?(:to_a) && !g.respond_to?(:sample)
        g.sample(800)
      rescue Error
        raise
      rescue StandardError, ScriptError => e
        raise Error.new("fit_patch #{name}: the document doesn't load or play: #{e.class}: #{e.message.lines.first&.strip}", document: text)
      end

      # Header calls of a graph document (not its body).
      HEADER_CALLS = %i[graph inputs param knob].freeze

      # The body of graph document +text+ (its code after the header's
      # graph, inputs, param, and knob lines), as `retune :kick, code` takes
      # it.
      def body_of(text)
        tree = Prism.parse(text)
        return '' unless tree.success?
        first = tree.value.statements.body.find { |st| !(st.is_a?(Prism::CallNode) && st.receiver.nil? && HEADER_CALLS.include?(st.name)) }
        first ? text.byteslice(first.location.start_offset..).strip : ''
      end

      # +code+ without a `play (...)` or `bg (...)` around it (fits print
      # console lines that play the voice).
      def unwrap(code)
        tree = Prism.parse(code)
        return code unless tree.success?
        body = tree.value.statements.body
        return code unless body.length == 1
        call = body[0]
        return code unless call.is_a?(Prism::CallNode) && %i[play bg].include?(call.name) && call.receiver.nil? && call.block.nil?
        args = call.arguments&.arguments || []
        return code unless args.length == 1
        a = args[0]
        a = a.body.body.first while a.is_a?(Prism::ParenthesesNode) && a.body&.body&.length == 1
        a.slice
      end

      # The most copies .unroll writes for one `n.times { }`.
      UNROLL_LIMIT = 32

      # +code+ with each `n.times { ... }` statement (n an Integer literal,
      # the block's value unused) written out n times, its block parameter
      # read as each index (fit-patch-2: a fit's phaser chains four
      # allpasses with `4.times { ap = ap.filter(...) }`; graph documents
      # have no loops, by design, so the document gets the chain the loop
      # built, which is also what the graph prints as).  Other `times`
      # calls stay, and the loader names them.
      def unroll(code, name = nil)
        UNROLL_LIMIT.times do
          tree = Prism.parse(code)
          return code unless tree.success?
          call = unrollable(tree.value)
          return code unless call
          count = call.receiver.value
          if count > UNROLL_LIMIT
            raise Error, "fit_patch #{name}: #{call.receiver.slice}.times writes out #{count} copies (at most #{UNROLL_LIMIT}): write the chain out"
          end
          body = call.block.body
          text = body ? code.byteslice(body.location.start_offset...body.location.end_offset) : 'nil'
          param = call.block.parameters&.parameters&.requireds&.first&.name
          sep = text.include?("\n") ? "\n" : '; '
          copies = Array.new(count) { |i| param ? replace_reads(text, body, param, i.to_s) : text }
          out = code.b
          out[call.location.start_offset...call.location.end_offset] = (count == 0 ? 'nil' : copies.join(sep)).b
          code = out.force_encoding(code.encoding)
        end
        code
      end

      # The first `n.times { }` statement of +root+ that .unroll writes
      # out (its innermost first), or nil.
      def unrollable(root)
        found = nil
        stack = [root]
        until stack.empty?
          n = stack.pop
          if n.is_a?(Prism::StatementsNode)
            n.body[0...-1].each do |st|
              next unless st.is_a?(Prism::CallNode) && st.name == :times && st.receiver.is_a?(Prism::IntegerNode) && st.arguments.nil? &&
                          st.block.is_a?(Prism::BlockNode) && unrollable_params?(st.block.parameters)
              inner = st.block.body && unrollable(st.block.body)
              return inner || st
            end
          end
          stack.concat(n.compact_child_nodes.reverse)
        end
        found
      end

      # True for no block parameters or one plain name.
      def unrollable_params?(params)
        return true if params.nil?
        return false unless params.is_a?(Prism::BlockParametersNode) && params.parameters && params.locals.empty?
        list = params.parameters
        list.requireds.length == 1 && list.requireds[0].is_a?(Prism::RequiredParameterNode) && list.optionals.empty? &&
          list.rest.nil? && list.posts.empty? && list.keywords.empty? && list.keyword_rest.nil? && list.block.nil?
      end

      # +text+ (the source of +body+) with each read of local +name+ at the
      # block's own depth replaced by +value+.
      def replace_reads(text, body, name, value)
        reads = []
        stack = [[body, 0]]
        until stack.empty?
          n, depth = stack.pop
          reads << n if n.is_a?(Prism::LocalVariableReadNode) && n.name == name && n.depth == depth
          d = n.is_a?(Prism::BlockNode) || n.is_a?(Prism::LambdaNode) ? depth + 1 : depth
          n.compact_child_nodes.each { |c| stack << [c, d] }
        end
        base = body.location.start_offset
        out = text.b
        reads.sort_by { |r| -r.location.start_offset }.each do |r|
          out[(r.location.start_offset - base)...(r.location.end_offset - base)] = value.b
        end
        out.force_encoding(text.encoding)
      end

      # The node giving the voice's source in +root+ (a Prism tree): the
      # first argument of the first VOICE_CALLS call met walking the tree
      # (calls made before inside blocks count too: a document's locals),
      # or the call's receiver when it has one (`CLIP.synth { }`).
      def voice_source(root)
        stack = [root]
        until stack.empty?
          n = stack.shift
          if n.is_a?(Prism::CallNode) && VOICE_CALLS.include?(n.name)
            return n.receiver if n.receiver
            first = n.arguments&.arguments&.first
            return first if first && !first.is_a?(Prism::KeywordHashNode)
          end
          stack.concat(n.compact_child_nodes)
        end
        nil
      end

      # The CallNodes of +root+'s tree that name one of +names+ as a bare
      # word (`tune`, read as a param by GraphIO's loader).
      def references(root, names, out = [])
        if root.is_a?(Prism::CallNode) && root.receiver.nil? && root.arguments.nil? && root.block.nil? && root.variable_call? && names.include?(root.name)
          out << root
        end
        root.compact_child_nodes.each { |c| references(c, names, out) }
        out
      end

      # The local variable names +node+'s tree assigns or takes as block
      # parameters.
      def local_names(node, out = [])
        case node
        when Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode, Prism::RequiredParameterNode, Prism::OptionalParameterNode
          out << node.name
        end
        node.compact_child_nodes.each { |c| local_names(c, out) }
        out.uniq
      end

      # Unit calls whose receiver is a typed value (`4.07.db`, `12.cents`):
      # a param there would be a node, which these don't take.
      UNIT_CALLS = %i[db dB cents hz khz ms s sec seconds second n1 n2 n4 n8 n16 n32 bars bar beats beat].freeze

      # True if a block given to a call named +name+ runs while the graph
      # plays (the documents' safe subset for runtime blocks: arithmetic on
      # the block's own arguments, no params): every literal block but the
      # build blocks the loader walks as document code (GraphIO::Registry::
      # BUILD_BLOCKS: synth, kit, voice, then, with_seed, ...).
      def runtime_block?(name)
        !GraphIO::Registry::BUILD_BLOCKS.include?(name)
      end

      # Yields each numeric literal of +node+'s tree with the keyword it is
      # the value of (a Symbol, or nil), why it can't be a param (nil, or
      # words: inside a Range, a typed value, inside a runtime block, at a
      # setting that takes only numbers), and its setting ([call,
      # argument]: the innermost call it is an argument or receiver of, as
      # GraphIO::NumberOnly names settings; nil outside calls).  With
      # +number_only: false+ the NumberOnly settings don't count as reasons
      # (the param sweep guard checks the list with that).
      def literals(node, key = nil, why = nil, setting = nil, number_only: true, &block)
        walk = ->(n, k, w, st) { literals(n, k, w, st, number_only: number_only, &block) }
        case node
        when Prism::FloatNode, Prism::IntegerNode
          only = number_only && why.nil? ? GraphIO::NumberOnly.reason(setting) : nil
          yield node, key, why || (only && "at a setting that takes only numbers (#{setting_name(setting)}: #{only})"), setting
        when Prism::AssocNode
          k = node.key.is_a?(Prism::SymbolNode) ? node.key.unescaped.to_sym : nil
          walk.(node.key, nil, why, setting)
          walk.(node.value, k, why, setting)
        when Prism::RangeNode
          node.compact_child_nodes.each { |c| walk.(c, nil, why || 'inside a Range (a setting, not a knob)', setting) }
        when Prism::CallNode
          if node.receiver && UNIT_CALLS.include?(node.name) && node.arguments.nil? &&
             (node.receiver.is_a?(Prism::FloatNode) || node.receiver.is_a?(Prism::IntegerNode))
            walk.(node.receiver, key, why || "a typed value (#{node.slice}): bind it in the inspector", setting)
          else
            label = call_label(node)
            walk.(node.receiver, nil, why, [label, :self]) if node.receiver
            (node.arguments&.arguments || []).each_with_index do |a, i|
              if a.is_a?(Prism::KeywordHashNode)
                a.elements.each do |el|
                  kw = el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) ? el.key.unescaped.to_sym : :**
                  walk.(el, nil, why, [label, kw])
                end
              else
                walk.(a, nil, why, [label, i])
              end
            end
            if node.block
              w = node.block.is_a?(Prism::BlockNode) && runtime_block?(node.name) ? "inside a #{node.name} block (runs while playing; params can't go there)" : nil
              walk.(node.block, nil, why || w, nil)
            end
          end
        else
          node.compact_child_nodes.each { |c| walk.(c, nil, why, setting) }
        end
      end

      # A call's name as GraphIO::NumberOnly names settings: the method
      # name, or `Const.name` for a call on a constant other than MB::Sound
      # (`Filter::Biquad.new`).
      def call_label(node)
        r = node.receiver
        if r.is_a?(Prism::ConstantReadNode) || r.is_a?(Prism::ConstantPathNode)
          c = r.slice.delete_prefix('::').delete_prefix('MB::Sound').delete_prefix('::')
          return "#{c}.#{node.name}" unless c.empty?
        end
        node.name.to_s
      end

      # +setting+ ([call, argument]) as words: `tween(0)`, `lowpass(quality:)`.
      def setting_name(setting)
        call, arg = setting
        a = case arg
            when Symbol then arg == :self ? 'receiver' : "#{arg}:"
            else arg.to_s
            end
        "#{call}(#{a})"
      end

      # The one of +hits+ ({ name => value }) whose value is closest to
      # literal +node+'s, or nil when two are as close.
      def closest(node, hits)
        lit = node.value.to_f
        best = hits.min_by(2) { |_, v| (v - lit).abs }
        return best[0][0] if best.length == 1
        (best[0][1] - lit).abs + 1e-12 < (best[1][1] - lit).abs ? best[0][0] : nil
      end

      # True if literal +node+ prints +value+ at its own precision: a
      # literal with 3 or more decimals or 4 or more significant digits
      # (2477.1) is any value rounding to it, a shorter one the value to 6
      # places.
      def matches?(node, value)
        case node
        when Prism::IntegerNode
          value.is_a?(Integer) && value == node.value
        when Prism::FloatNode
          return false unless value.is_a?(Float)
          text = node.slice.delete('_')
          lit = node.value
          if (m = text.match(/\A-?\d+\.(\d+)\z/))
            # (a printer rounds to a fixed number of places and drops
            # trailing zeros: a short literal is the value to 6 places, a
            # longer one any value rounding to it; 0.25 doesn't print 0.3)
            d = m[1].length
            sig = text.delete('-').sub(/\A0*\.?0*/, '').delete('.').length
            d >= 3 || sig >= 4 ? (value - lit).abs <= 0.5 * 10.0**-d * (1 + 1e-9) : (value.round(6) - lit).abs <= 1e-12
          else
            (value - lit).abs <= 1e-9 * [value.abs, lit.abs].max
          end
        else
          false
        end
      end
    end

    # The console's fit_patch (MB::Sound extends it; hand-tune-1).
    module FitPatchMethods
      # A fitted voice as a patch with named knobs (see FitPatch): +code+
      # is the voice as the fit printed it (console Ruby, numbers as
      # literals), each keyword a fitted number with the fit's range,
      # `(lo..hi).at(value)` (or `[(lo..hi).at(value), 'description']`).
      # Writes a graph document to FitPatch.dir (or +path+) and returns a
      # FitPatch::Patch, which `design` and `track` take like an
      # instrument: every param is a knob of the track (`:"kick/tune"`).
      #
      #     kick = fit_patch :kick_fit, code, tune: (30.0..110.0).at(51.33), decay: (0.1..2.0).at(0.469)
      #     design :kick, kick, seq(C2).n4.loop
      def fit_patch(name, code, path: nil, description: nil, **params)
        p = FitPatch.save(name, code, params, path: path, description: description)
        puts p.to_s
        p
      end
    end

    extend FitPatchMethods
  end
end

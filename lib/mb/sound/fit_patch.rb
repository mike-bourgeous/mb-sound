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

      # A written fit patch: +name+, +path+ (the document), +entry+ (a
      # Library::Entry for `track`/`design`; see #library_entry), +params+
      # ({ name => MB::Sound::Param }), +sites+ (Sites), +missing+ (param
      # names found nowhere in the code), +text+ (the document).
      Patch = Data.define(:name, :path, :entry, :params, :sites, :missing, :text) do
        # The Library::Entry `track :kick, fit` and `design :kick, fit` play
        # (Arrangement::InstrumentPatch takes anything answering it).
        def library_entry = entry

        # { param => value } at the fit (the knobs' starting values).
        def values = params.transform_values(&:default)

        def to_s
          knobs = params.keys.map { |k| k.to_s }.join(', ')
          miss = missing.empty? ? '' : "; not in the code: #{missing.join(', ')} (name the number it printed instead, or bind it in the inspector)"
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
      # see .declare) as `param` lines.  Returns [text, sites, missing].
      def document(code, params, name:, description: nil, input: :midi)
        code = code.to_s
        result = Prism.parse(code)
        raise Error, "fit_patch #{name}: the code doesn't parse: #{result.errors.first&.message}" unless result.success?
        bad = params.keys.select { |k| !k.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) || VOICE_CALLS.include?(k) || k == input }
        raise Error, "fit_patch #{name}: #{bad.map(&:inspect).join(', ')} can't name a param (lowercase words; not #{input} or a voice call)" unless bad.empty?
        locals = local_names(result.value) & params.keys
        unless locals.empty?
          raise Error, "fit_patch #{name}: the code assigns #{locals.join(', ')} itself; give #{locals.length == 1 ? 'that param' : 'those params'} another name (#{locals.first}_value:)"
        end

        edits = []
        source = voice_source(result.value)
        raise Error, "fit_patch #{name}: no voice played from a clip in the code (#{VOICE_CALLS.first(4).join(', ')}, ... with the clip first)" unless source
        edits << [source.location.start_offset, source.location.end_offset, input.to_s] unless source.slice == input.to_s

        sites = []
        literals(result.value) do |node, key|
          hits = params.select { |_, p| matches?(node, p.default) }.keys
          next if hits.empty?
          pick = hits.include?(key) ? key : (hits.length == 1 ? hits.first : nil)
          unless pick
            loc = node.location
            raise Error, "fit_patch #{name}: the literal #{node.slice} at #{loc.start_line}:#{loc.start_column + 1} matches #{hits.map(&:inspect).join(' and ')}: " \
                         'give the values with more digits, or one of them under another name'
          end
          loc = node.location
          edits << [loc.start_offset, loc.end_offset, pick.to_s]
          sites << Site.new(name: pick, line: loc.start_line, column: loc.start_column + 1, text: node.slice)
        end
        missing = params.keys - sites.map(&:name).uniq

        body = code.b
        edits.sort_by { |s, _, _| -s }.each { |s, e, text| body[s...e] = text.b }
        body = body.force_encoding(code.encoding)

        meta = { name: name.to_s, kind: :synth, saved: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'), mb_sound: GraphIO.library_version, from: 'fit_patch',
                 description: description || "A fitted voice with every fitted number a knob (fit_patch, hand-tune-1): #{params.keys.join(', ')}" }
        lines = ['# mb-sound graph document: a Ruby subset that MB::Sound.preset and', '# MB::Sound::GraphIO.load read without running it (no eval).']
        lines << GraphIO.graph_line(meta.map { |k, v| "#{k}: #{RubyValue.to_ruby(v)}" })
        lines << GraphIO.inputs_line(input => :notes)
        params.each { |pname, p| lines << p.document_line(p.default) unless missing.include?(pname) }
        lines << '' << body.strip
        [lines.join("\n") + "\n", sites.freeze, missing.freeze]
      end

      # Writes the document for +code+ and +params+ (see .document; params
      # as .declare takes them) to +path+ (default: .dir/NAME.mbg.rb,
      # replacing an older fit of that name), checks that it loads and
      # plays a block, and returns a Patch.
      def save(name, code, params, path: nil, description: nil)
        name = name.to_sym
        raise Error, "fit_patch takes a name for the patch (a Symbol like :kick_fit), got #{name.inspect}" unless name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
        params = declare(params)
        raise Error, "fit_patch #{name}: give the fitted numbers as knobs (tune: (30.0..110.0).at(51.3), ...)" if params.empty?
        text, sites, missing = document(code, params, name: name, description: description)
        check(name, text)
        path = File.expand_path(path || File.join(dir, "#{name}#{GraphIO::EXTENSION}"))
        path += GraphIO::EXTENSION unless path.end_with?('.rb')
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
        entry = Library.document_entry(path, Library.session_shelf)
        Patch.new(name: name, path: path, entry: entry, params: params.reject { |k, _| missing.include?(k) }.freeze, sites: sites, missing: missing, text: text.freeze)
      end

      # Loads document +text+ with a one-note clip and reads a block of it;
      # raises Error (with the text) if it doesn't load or play.
      def check(name, text)
        clip = MB::Sound.seq(36).n4
        g = MB::Sound.keeping_random_state { GraphIO.load(text, inputs: { midi: clip }) }
        g = g.first if g.is_a?(Array)
        g = g.to_a.first if g.respond_to?(:to_a) && !g.respond_to?(:sample)
        g.sample(800)
      rescue Error
        raise
      rescue StandardError, ScriptError => e
        raise Error.new("fit_patch #{name}: the document doesn't load or play: #{e.class}: #{e.message.lines.first&.strip}", document: text)
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

      # Yields each numeric literal of +node+'s tree with the keyword it is
      # the value of (a Symbol, or nil).
      def literals(node, key = nil, &block)
        case node
        when Prism::FloatNode, Prism::IntegerNode
          yield node, key
        when Prism::AssocNode
          k = node.key.is_a?(Prism::SymbolNode) ? node.key.unescaped.to_sym : nil
          literals(node.key, nil, &block)
          literals(node.value, k, &block)
        else
          node.compact_child_nodes.each { |c| literals(c, nil, &block) }
        end
      end

      # True if literal +node+ prints +value+ at its own precision: a
      # literal with 3 or more decimals is any value rounding to it, a
      # shorter one the value to 6 places.
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
            d >= 3 ? (value - lit).abs <= 0.5 * 10.0**-d * (1 + 1e-9) : (value.round(6) - lit).abs <= 1e-12
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

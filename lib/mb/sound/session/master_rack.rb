module MB
  module Sound
    class Session
      # Effect racks on the master, and the master chain kept as an effect
      # rack (master-rack-1; the maintainer, 2026-11-22: "Rack, and master
      # takes racks").  One mechanism for chains everywhere: what plays on
      # the master can be saved as a rack document and played again on the
      # master or on a track.
      #
      #     master { |mix| mix.hp1(30).reverb(:room).softclip }
      #     master.save_rack :glue      # a rack document; rack :glue in the session
      #     master :glue                # back on the master later
      #     fx :drums, :glue            # or on a track
      #
      # #effect resolves what `master` takes besides blocks and mastering
      # presets: a Rack (named or anonymous, kind :effect), a library effect
      # Entry, or a Symbol naming a mastering preset (which wins), a rack
      # in the Session, or a library effect (rack documents, library-file
      # chains, effect presets).  #block wraps one as a master block (a
      # Block, which Session#master stores like any block, so undo, panic,
      # warm-ups, and set documents treat it alike).
      #
      # #save captures the latest #master call (its block and mastering
      # preset) as a rack: the block runs on a stand-in for the mix with as
      # many channels as the Session (Rack#build_on_stand_ins), the recipes
      # print its body (GraphIO::RackWriter), a preset ends it as
      # `.master(:club, lufs: -9)`, and every knob the chain reads becomes
      # a rack knob at its current value (knobs it defines keep their
      # ranges; knobs it only reads by name are declared first from the
      # Session's).
      module MasterRack
        # A master block made from an effect rack or a library effect
        # (#block): applies #effect to the mix.  #label names it in
        # journal entries and `master`.
        class Block < Proc
          # The Rack or library Entry the block applies.
          attr_accessor :effect

          # The effect as `master` prints it (rack(:glue), an arack,
          # L.fx.reverb.hall).
          def label
            MasterRack.label(@effect)
          end
        end

        # What `master` shows (Session#master_info's text) with the chain
        # it shows, so `master.save_rack :glue` saves what was shown.
        class View < String
          def initialize(text, session:, block:, preset:)
            super(text)
            @session = session
            @block = block
            @preset = preset
          end

          # Saves the master chain shown as rack document +name+ (a Symbol)
          # on the save shelf, like `save :name, rack` (never replacing:
          # see #save_rack!; +bump: true+ saves the next free version), and
          # defines rack +name+ in the Session from the saved document.
          # Returns the Rack, or nil when nothing was saved.  +tags:+ and
          # +about:+ describe it for Library find.
          #
          #     master { |mix| mix.hp1(30).reverb(:room).softclip }
          #     master.save_rack :glue
          #     master :glue              # later, or in another session
          #     fx :drums, :glue          # on a track
          def save_rack(name, bump: false, tags: nil, about: nil)
            MasterRack.save(@session, name, block: @block, preset: @preset, replace: false, bump: bump, tags: tags, about: about)
          end

          # Like #save_rack, replacing rack document +name+ and the
          # Session's rack +name+ if they exist (the user shelf's git
          # history keeps the old document).
          def save_rack!(name, tags: nil, about: nil)
            MasterRack.save(@session, name, block: @block, preset: @preset, replace: true, bump: false, tags: tags, about: about)
          end
        end

        # Names a captured rack can't take: `master :club` plays the
        # mastering preset, `master :show` (no argument) shows the chain.
        def self.reserved_names
          [*Mastering.names, :show]
        end

        module_function

        # The effect +value+ stands for on the master: a Rack (named
        # racks and anonymous ones; kind :effect), a library effect Entry
        # (a rack entry gives its Rack), nil for a mastering preset (a
        # Mastering::Preset, a preset name; the caller builds it), or the
        # rack or effect a Symbol names in +session+ (see #by_name; raising
        # with suggestions for an unknown name).  Other values give nil
        # (the caller's errors say what master takes).
        def effect(value, session)
          case value
          when Symbol then Mastering.names.include?(value) ? nil : by_name(value, session)
          when Rack then check_rack(value)
          when Library::Entry then entry_effect(value, session)
          end
        end

        # The rack or library effect named +name+: a rack in +session+,
        # else the one library effect of that name (L.fx: rack documents,
        # library-file chains, effect presets).  Raises ArgumentError with
        # suggestions when there is none, or when the name is ambiguous.
        def by_name(name, session)
          if (r = session.racks[name])
            return check_rack(r)
          end

          effects = Library.index.entries(kind: :effect)
          hits = effects.select { |e| e.name == name }
          if hits.empty?
            names = (Mastering.names + session.racks.names + effects.map(&:name)).uniq
            raise ArgumentError, "master #{name.inspect}: no mastering preset, rack, or effect is named #{name.inspect}" \
                                 "#{Library.suggest(name, names)}\n(masters lists the mastering presets, racks the session's racks, L.fx the effects)"
          end
          if hits.length > 1
            raise ArgumentError, "master #{name.inspect}: #{hits.length} effects are named #{name} (#{hits.map(&:head_path).join(', ')}): " \
                                 "give one, e.g. master #{hits.first.head_path}"
          end
          entry_effect(hits.first, session)
        end

        # +rack+, if it can play on the master (an effect: audio in, audio
        # out); else ArgumentError.
        def check_rack(rack)
          return rack if rack.kind == :effect

          raise ArgumentError, "master plays effect racks (audio in, audio out); #{rack.label} is #{a_kind(rack.kind)} (#{rack.signature})"
        end

        # The effect of library Entry +entry+: its Rack when it is one (a
        # session rack, a library-file chain, a rack document, defined in
        # +session+ like `preset :name`), else the Entry (an effect preset:
        # applied to the mix).
        def entry_effect(entry, session)
          unless entry.kind == :effect
            raise ArgumentError, "master plays effects; #{entry.head_path} is #{a_kind(entry.kind)} (L.fx lists effects)"
          end
          return check_rack(entry.builder) if entry.builder.is_a?(Rack)
          if (r = Library.rack_of(entry))
            return check_rack(GraphIO.place_rack(session, r, source: entry.location))
          end
          if entry.settings.is_a?(Hash) && entry.settings[:document] && GraphIO.parse(entry.location).rack?
            return check_rack(Session.with_context(session: session) { MB::Sound.preset(entry.location, session: session) })
          end

          entry
        end

        # A master Block applying +effect+ (a Rack or an Entry) to the mix.
        def block(effect)
          b = Block.new { |mix| effect.call(mix) }
          b.effect = effect
          b
        end

        # How +effect+ prints in `master` and journal entries.
        def label(effect)
          case effect
          when Rack then effect.name ? "rack(#{effect.name.inspect})" : "an #{effect.constructor}"
          when Library::Entry then effect.head_path
          else effect.inspect
          end
        end

        # "an effect", "a note_fx", ...
        def a_kind(kind)
          k = kind.to_s
          "#{k.match?(/\A[aeiou]/) ? 'an' : 'a'} #{k}"
        end

        # Saves the master chain +block+ and +preset+ (Session#master_block
        # and #master_preset when shown) as rack document +name+, then
        # defines rack +name+ in +session+ from the saved document (see
        # View#save_rack).  Returns the Rack, or nil when nothing was saved
        # (Library::Saving says why).
        def save(session, name, block:, preset:, replace:, bump:, tags: nil, about: nil)
          return nil unless name_ok?(session, name, replace)

          rack, stand_ins = printing_rack(session, name, block, preset)
          path = Library::Saving.save(name, rack, replace: replace, bump: bump, tags: tags, about: about, stand_ins: stand_ins)
          return nil unless path

          Session.with_context(session: session) { MB::Sound.preset(path, session: session, racks: replace ? :saved : nil) }
        end

        # The rack document text of the chain (see #printing_rack), as
        # #save writes it (for specs and the session fuzz, which don't
        # write files).
        def text(session, name, block: session.master_block, preset: session.master_preset)
          rack, stand_ins = printing_rack(session, name, block, preset)
          GraphIO.dump(rack, stand_ins: stand_ins)
        end

        # The chain loaded back from its rack document text (see #text): a
        # Rack named +name+, not defined in any Session.
        def rack(session, name, block: session.master_block, preset: session.master_preset)
          GraphIO.load(text(session, name, block: block, preset: preset))
        end

        # True if +name+ can name a captured rack in +session+; else
        # MB::Sound.live_error (raising in scripts and specs) saying why.
        def name_ok?(session, name, replace)
          why =
            if !name.is_a?(Symbol)
              "rack names are Symbols (got #{name.inspect})"
            elsif reserved_names.include?(name)
              "master #{name.inspect} #{name == :show ? 'shows the master chain' : 'plays the mastering preset'}, so a rack can't be named #{name.inspect}; " \
                "pick another name (e.g. :#{name}_glue)"
            elsif (kind = session.names.kind(name)) && kind != :rack
              "#{name.inspect} names a #{kind.to_s.tr('_', ' ')} in this session; pick another name"
            elsif kind == :rack && !replace
              "rack #{name.inspect} is defined in this session; master.save_rack! #{name.inspect} replaces it and its document, or pick another name"
            end
          return true unless why

          MB::Sound.live_error(ArgumentError.new("master.save_rack: #{why}; nothing was saved"))
          false
        end

        # The rack that prints the chain, and the stand-in options its
        # document builds with: [Rack, { channels:, knobs: }].  The block
        # runs on a stand-in mix of the Session's channels; knobs the chain
        # only reads by name are declared first from the Session's (so they
        # become rack knobs), and every knob starts at the Session knob's
        # current value.
        def printing_rack(session, name, block, preset)
          if block.nil? && preset.nil?
            raise ArgumentError, 'master is bypass: nothing to save (set master { |mix| ... } or master :club first)'
          end

          channels = session.channels
          body = ->(sig) { finish(apply(block, sig, channels), preset, channels) }
          dry = Rack.new(name, in: :audio, out: :audio, constructor: :arack, block: proc { |sig| body.(sig) }, quiet: true)
          result, _stand, app = dry.build_on_stand_ins(channels: channels)

          read = session_knobs(result).reject { |n, _| app.knobs.key?(n) }
          start = {}
          (app.knobs.keys + read.keys).each do |n|
            k = session.knobs[n]
            start[n] = current(k) if k
          end
          wrapper = proc { |sig|
            read.each { |n, k| declare(n, k) }
            body.(sig)
          }
          [Rack.new(name, in: :audio, out: :audio, constructor: :arack, block: wrapper, quiet: true), { channels: channels, knobs: start }]
        end

        # +block+ (a master block) on +sig+ (the whole mix as a bundle, or
        # its channels for a block with one parameter per channel).
        def apply(block, sig, channels)
          return sig if block.nil?
          return block.call(sig) if block.arity == 0 || block.arity == 1
          return block.call(*Array.new(channels) { |i| sig[i] }) if block.arity < 0 || block.arity == channels

          raise ArgumentError, "Give the master block one parameter (the whole mix) or #{channels} (one per channel); got #{block.arity}"
        end

        # +out+ (the block's result; an Array of channels as a bundle, which
        # an effect rack returns) through mastering preset +preset+, as
        # Session#master ends a chain with one (a single channel copied to
        # every channel first).
        def finish(out, preset, channels)
          out = GraphNode::Channels.new(out) if out.is_a?(Array) # (unrecorded: prints as [l, r].channels)
          return out unless preset

          out = out.stereo if channels == 2 && out.outputs.length == 1
          out.master(preset.name, **preset.options)
        end

        # The Session knobs (not rack knobs) a built chain +result+ reads,
        # by name: plain names only (a track's :"bass/cutoff" stays the
        # track's).
        def session_knobs(result)
          roots = result.is_a?(Array) ? result : result.outputs
          nodes = roots.flat_map { |n| [n, *n.graph] }
          knobs = nodes.grep(GraphNode::Knob::Reader).map(&:knob) + nodes.grep(GraphNode::Knob)
          knobs.uniq(&:__id__).each_with_object({}) { |k, h|
            next if k.rack_knob || !k.session || k.name.to_s.include?('/')
            h[k.name] = k
          }
        end

        # Declares rack knob +name+ inside a rack's block with Session knob
        # +knob+'s range, curve, unit, controller, and settings.
        def declare(name, knob)
          spec = knob.spec
          p = spec.param
          opts = {}
          opts[:range] = p.range if p.range && !p.implied
          opts[:curve] = p.curve if p.curve && p.curve != p.default_curve
          opts[:unit] = p.unit if p.unit
          opts[:cc] = spec.cc if spec.cc
          opts[:description] = p.description if p.description
          opts[:clamp] = false unless p.clamp
          opts[:takeover] = spec.takeover unless spec.takeover == :pickup
          opts[:smooth] = spec.smooth unless spec.smooth == Fades::DECLICK_SECONDS
          MB::Sound.knob(name, p.typed(spec.default), **opts)
        end

        # The value knob +k+ holds (where a turn is headed, if one is).
        def current(k)
          k.moving? || k.target.nil? ? k.value : k.target
        end
      end
    end
  end
end

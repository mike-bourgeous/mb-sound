module MB
  module Sound
    class Arrangement
      # Library instruments as tracks' patches (library-instruments-1,
      # 2026-10-28; design/notes/arrangement.md, Library instruments): the
      # maintainer's guesses `track :bass, L.inst.dnb.dnb_reese`, `track
      # :bass, :dnb_reese`, and `track :bass, riff, L.inst.x` (a clip and an
      # instrument) all make the patch `{ |clip| preset :dnb_reese, midi:
      # clip }`.  An instrument Entry (any family: graph documents,
      # library-file instruments, SQ-80 patches, genre patches, struck
      # resonators), a kit Entry (tr808, tr909), or a Symbol naming one
      # becomes a patch Proc that builds it from the track's clip
      # (InstrumentPatch.patch); effect entries raise with the spelling that
      # works, except resonators, which play as their struck instrument
      # (L.fx.bar on a track is L.inst.bar).
      module InstrumentPatch
        # Raised for a value that can't be a track's instrument (an
        # effect, a set, an unknown name).
        class Error < ArgumentError; end

        # Entry kinds a track can play from its clip.
        KINDS = %i[instrument kit].freeze

        module_function

        # The Library::Entry +value+ names as a track's instrument (an
        # Entry or a Symbol), or nil if +value+ is neither.  Raises Error
        # for effects (with the spelling that works), sets, and unknown
        # names.  +track+ is the track's name, for messages.
        def entry_for(value, track: :x)
          case value
          when Library::Entry then check(value, track)
          when Symbol then check(lookup(value, track), track)
          end
        end

        # True if +value+ is something #entry_for takes (an Entry or a
        # Symbol).
        def instrument?(value)
          value.is_a?(Library::Entry) || value.is_a?(Symbol)
        end

        # The Entry a Symbol names for a track: what `preset :x` loads (a
        # graph document or a library-file instrument, in shelf order),
        # else the one instrument or kit of that name in another family
        # (an SQ-80 patch, a genre patch, tr909, a struck resonator).
        def lookup(name, track)
          kind, found = Library.index.preset_target(name)
          if kind == :entry
            return found
          elsif kind == :document
            hit = Library.index.entries(family: :preset).find { |e| e.location == found }
            return hit if hit
          end

          hits = Library.index.entries.select { |e| e.name == name && e.family != :preset && (KINDS.include?(e.kind) || struck_twin(e)) }
          hits = hits.reject { |e| e.kind == :effect } if hits.length > 1
          return hits.first if hits.length == 1
          if hits.length > 1
            paths = hits.map(&:head_path)
            raise Error, "track #{track.inspect}, #{name.inspect}: #{hits.length} instruments are named #{name} (#{paths.join(', ')}): give one, e.g. track #{track.inspect}, #{paths.first}"
          end
          names = Library.index.entries.select { |e| KINDS.include?(e.kind) }.map(&:name).uniq
          raise Error, "track #{track.inspect}, #{name.inspect}: no instrument #{name}#{did_you_mean(name, names)} (find '#{name}' searches the library; L.inst lists instruments)"
        end

        # +entry+ if a track can play it from its clip (an instrument or
        # kit, or a resonator effect's struck twin), else raises Error
        # saying where it goes instead.
        def check(entry, track)
          return entry if KINDS.include?(entry.kind)
          if (twin = struck_twin(entry))
            return twin
          end

          path = entry.head_path
          case entry.kind
          when :effect
            raise Error, "#{path} is an effect (#{entry.label}), not an instrument: put it after one in the patch, e.g. " \
              "track(#{track.inspect}) { |clip| preset(:dnb_reese, midi: clip).then(&#{path}) }, or on a bus: bus(:fx) { |sig| sig.then(&#{path}) }"
          when :clip
            raise Error, "#{path} is a clip: give it with an instrument, e.g. track #{track.inspect}, #{path}, L.inst.dnb.dnb_reese"
          when :set
            raise Error, "#{path} is a set: preset #{entry.name.inspect} loads it (its tracks, scenes, and flow)"
          else
            raise Error, "#{path} is a #{entry.kind} (#{entry.label}), not an instrument a track can play (L.inst lists instruments)"
          end
        end

        # The struck instrument for a resonator effect entry (L.fx.bar ->
        # L.inst.bar), or nil (see StruckMethods).
        def struck_twin(entry)
          return nil unless entry.family == :resonator
          Library.index.lookup(:struck, entry.name, note: false)
        rescue StandardError
          nil
        end

        # A patch Proc for +entry+: builds it from the track's clip
        # (`preset :dnb_reese, midi: clip` for a graph document, `entry.(clip)`
        # otherwise).  The Proc answers #library_entry (the Entry) and
        # prints as `track :x, :name` in set documents (SetWriter).
        def patch(entry)
          patch =
            if entry.family == :preset && entry.settings.is_a?(Hash) && entry.settings[:document]
              input = Array(entry.settings[:inputs]).first || :midi
              path = entry.location
              ->(clip) { MB::Sound.preset(path, input => clip) }
            elsif (names = TrackKnobs.entry_params(entry))
              # (an entry family's params as the track's knobs: struck decays)
              ->(clip) { entry.call(clip, **TrackKnobs.entry_knobs(entry, names)) }
            else
              ->(clip) { entry.call(clip) }
            end
          patch.define_singleton_method(:library_entry) { entry }
          patch.define_singleton_method(:source_location) { nil }
          patch.define_singleton_method(:inspect) { "#<patch #{entry.head_path}>" }
          patch
        end

        # The Library::Entry a track's +patch+ plays (through the counting
        # and binding wrappers), or nil for a patch block.
        def entry_of(patch)
          p = patch
          4.times do
            return nil if p.nil?
            return p.library_entry if p.respond_to?(:library_entry)
            p = p.respond_to?(:unbound_patch) ? p.unbound_patch : (p.respond_to?(:counted_patch) ? p.counted_patch : nil)
          end
          nil
        end

        # The Symbol that names +entry+ for `track :x, :name` (it resolves
        # back to the same entry), or nil.
        def symbol_for(entry)
          found = lookup(entry.name, :x) rescue nil
          found && found.family == entry.family && found.location == entry.location ? entry.name : nil
        end

        def did_you_mean(name, names)
          require 'did_you_mean'
          s = DidYouMean::SpellChecker.new(dictionary: names.map(&:to_s)).correct(name.to_s).first
          s ? " (did you mean #{s.to_sym.inspect}?)" : ''
        end
      end
    end
  end
end

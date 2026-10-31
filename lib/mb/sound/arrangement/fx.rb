module MB
  module Sound
    class Arrangement
      # A track's effect insert (library-2; the maintainer, 2026-10-30:
      # "Build fx: slot"): effects that process what the track's patch
      # builds, after it and before the track's fader and routing.
      #
      #     track :keys, L.inst.tine_piano, fx: L.fx.reverb.hall
      #     track :keys, riff, :tine_piano, fx: [:juno1, :hall]   # a chain, in order
      #     fx :keys, L.fx.dub                                     # swaps it at the track's launch point
      #     fx :keys, :off                                         # takes it out
      #
      # Values: a library effect Entry (`L.fx.hall`, a graph document or
      # library-file chain), a Symbol naming one effect (`:hall`; a name two
      # families share raises with their head paths), `{ reverb: :plate }`
      # (a family and a name: what set documents print for those), a Proc
      # or Method taking the signal (`->(sig) { sig.lp4(900) }`; not saved
      # in set documents), or an Array of those.  `fx :x, ...` on a playing
      # track rebuilds it at its launch point (one command, one undo step),
      # carrying the instrument's running state (Session::Carry) and letting
      # the old effect ring out under the new one (spill-over), so an echo
      # or a reverb's tail isn't cut.  Effects go on patch tracks (an
      # instrument or a patch block); a graph track's effects belong in its
      # graph.
      module Fx
        # Raised for a value that can't be an effect insert.
        class Error < ArgumentError; end

        # The values that take a track's insert out.
        OFF = [nil, false, :off, :none].freeze

        module_function

        # +value+ as an insert chain: a frozen Array of library Entries and
        # Procs (empty for OFF values).  Raises Error for anything else,
        # +track+ naming the track in messages.
        def chain(value, track: :x)
          return [].freeze if OFF.include?(value)
          Array(value.is_a?(Hash) ? [value] : value).flat_map { |v| one(v, track) }.freeze
        end

        # The effect entry (or Proc) for one insert value.
        def one(value, track)
          case value
          when Library::Entry
            return [value] if value.kind == :effect
            raise Error, "fx #{track.inspect}: #{value.head_path} is #{a_kind(value)}, not an effect (L.fx lists effects)"
          when Proc, Method
            [value]
          when Symbol
            [lookup(value, track)]
          when Hash
            value.map { |family, name|
              raise Error, "fx #{track.inspect}: give { family: :name } (e.g. { reverb: :plate }; got #{value.inspect})" unless family.is_a?(Symbol) && name.is_a?(Symbol)
              e = Library.index.lookup(family, name)
              e ||= Library.index.entries(family: family).find { |x| x.name == name }
              raise Error, "fx #{track.inspect}: no #{family} #{name.inspect}#{Library.suggest(name, Library.index.entries(family: family).map(&:name))}" unless e
              one(e, track).first
            }
          else
            raise Error, "fx #{track.inspect}: an effect is a library effect (L.fx.hall, :hall), a { family: :name } pair, a Proc taking the signal, " \
                         "or a list of those (got #{value.class})"
          end
        end

        # The effect entry named +name+ (a Symbol) among the library's
        # effects: the one of that name, else Error naming the choices.
        def lookup(name, track)
          hits = Library.index.entries(kind: :effect).select { |e| e.name == name }
          return hits.first if hits.length == 1
          if hits.empty?
            names = Library.index.entries(kind: :effect).map(&:name).uniq
            raise Error, "fx #{track.inspect}: no effect #{name.inspect}#{Library.suggest(name, names)} (L.fx lists effects)"
          end
          raise Error, "fx #{track.inspect}: #{hits.length} effects are named #{name} (#{hits.map(&:head_path).join(', ')}): give one, " \
                       "e.g. fx #{track.inspect}, #{hits.first.head_path}"
        end

        # +graph+ through +chain+ (see #chain), in order.
        def apply(chain, graph)
          return graph if chain.nil? || chain.empty?
          chain.reduce(graph) { |g, f| f.call(g) }
        end

        # A short label for +chain+ ("L.fx.hall", "L.fx.juno1 + L.fx.hall",
        # "off"), for journal entries and listings.
        def label(chain)
          return 'off' if chain.nil? || chain.empty?
          chain.map { |f| f.is_a?(Library::Entry) ? f.head_path : 'a block' }.join(' + ')
        end

        # +chain+ as the value a set document's track line prints (Symbols,
        # or { family: :name } where a Symbol names another effect too), or
        # nil if a Proc is in it (set documents can't save code there).
        def set_value(chain)
          return nil if chain.nil? || chain.empty? || chain.any? { |f| !f.is_a?(Library::Entry) }
          vals = chain.map { |e|
            hits = Library.index.entries(kind: :effect).select { |x| x.name == e.name }
            hits.length == 1 ? e.name : { e.family => e.name }
          }
          vals.length == 1 ? vals.first : vals
        end

        def a_kind(entry)
          k = entry.kind.to_s
          "#{k.match?(/\A[aeiou]/) ? 'an' : 'a'} #{k}"
        end
      end

      # Gives track +name+ the effect insert +value+ (see Fx; :off takes it
      # out).  On a playing track the change rebuilds it at +point+ (its
      # launch point by default), carrying the instrument's state and
      # spilling the old effect's tail: one command, one undo step; a
      # stopped track plays it from its next launch.  Returns the journal
      # entry, or the track's name when nothing was playing.
      def fx(name, value, point = LaunchPoint::NONE)
        tr = tracks[name] or raise ArgumentError, "fx #{name.inspect}: no track #{name.inspect}#{GraphIO.suggest(name, tracks.keys)}"
        raise Fx::Error, "fx #{name.inspect}: effect inserts go on tracks with a patch or an instrument; a graph track's effects go in its graph" unless tr.patch?
        chain = Fx.chain(value, track: name)
        chain = nil if chain.empty?
        playing = tr.clip && @session.playing_after_queue?(name)
        unless playing && (tr.fx || []) != (chain || []) # (stopped, or the same effects: nothing to rebuild)
          @mutex.synchronize { tr.fx = chain }
          return name
        end
        entry = nil
        @session.command("fx #{name.inspect} -> #{Fx.label(chain)}") {
          before = undo_state
          @mutex.synchronize { tr.fx = chain }
          entry = rebuild_track(tr, point, nil, carry: true, spill: true)
          @session.note_undo_extra(self, before, undo_state)
        }
        entry && @session.journal[entry.seq]
      end
    end
  end
end

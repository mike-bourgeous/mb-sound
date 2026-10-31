module MB
  module Sound
    module Library
      # What `play entry` and `audition entry` play (Entry#to_playable;
      # library-instruments-1, audition-1, ui-scaffold-1): the maintainer's
      # guesses `play L.fx.bar`, `play L.inst.x`.  Instruments play a demo
      # phrase (struck ones moved toward their resonator's typical pitch),
      # kits a beat, resonator effects one strike of their struck
      # instrument (Struck), clips on their instrument, other effects their
      # Listening Bench material, the A7 arp (Library::Bench, audition-1),
      # mastering chains the same arp through them, envelope presets a
      # triangle and some noise shaped by them; the rest say what to do
      # with them.
      module Audition
        # A beat for kit entries.
        KIT_DEMO = { kick: 'x...x...x...x...', snare: '....x.......x...', closed_hat: 'x.x.x.x.x.x.x.xx' }.freeze

        # The level of an audition on MAIN (`audition` when the output has
        # no CUE): under the set, so a loud preset doesn't jump out.
        MAIN_GAIN = -6.db

        # Envelope times (attack, decay, sustain, release) envelope presets
        # play with.
        ENVELOPE_DEMO = [0.01, 0.3, 0.6, 0.5].freeze

        # What `audition` started (see LibraryMethods#audition): +path+ the
        # entry's head path, +what+ it plays, +where+ (:cue or :main), the
        # journal +change+.  Prints as one line.
        Started = Data.define(:path, :what, :where, :change) do
          def to_s
            where_text = where == :cue ? 'on CUE' : "on MAIN at #{Audition::MAIN_GAIN.decibels.round} dB (no CUE on this output)"
            "audition #{path}: #{what}, #{where_text}; audition off stops it"
          end

          def inspect = "#<#{self}>"
        end

        module_function

        # A Playable::Graph (or something Playable.graph takes) for +entry+;
        # raises Playable::Unplayable with a working spelling otherwise.
        def playable(entry)
          path = entry.head_path
          if (st = Struck.entry_for(entry))
            if entry.kind == :effect
              return Playable.wrap(entry.ping, "#{path} struck once (#{st.head_path} at #{Struck.home_note(st.name).name})", true,
                "a resonator rings when struck: #{path}.ping(C5) strikes it at a note, #{st.head_path}.(clip) plays it from notes")
            end
            return Playable.wrap(st.(Struck.phrase(st.name)), "#{path} playing a demo phrase", true,
              "a struck instrument plays notes: #{path}.(clip), track :x, #{path}")
          end

          case entry.kind
          when :instrument
            Playable.wrap(entry.(Playable.demo_phrase), "#{path} playing a demo phrase", true,
              "an instrument plays notes: #{path}.(clip), or track :x, #{path}")
          when :kit
            Playable.wrap(entry.(MB::Sound.grid(16, **KIT_DEMO)), "#{path} playing a beat", true,
              "a kit plays a grid: #{path}.(grid(16, kick: 'x...'))")
          when :clip
            entry.call
          when :effect
            Playable.wrap(entry.audition(:mix), "#{path} on the audition mix (beat and bass, pluck, pad, then its tail)", true,
              "an effect processes a sound: #{path}.audition(:arp), (:break), or (:pad) for the other Bench materials, sig.then(&#{path}) on any sound")
          when :master
            # (the Bench has no mastering sets: the effects' audition mix through the chain)
            Playable.wrap(entry.(Bench.effect_material(:mix).build), "#{path} on the audition mix", true,
              "a mastering chain ends the master: master #{entry.name.inspect}, or mix.then(&#{path})")
          when :envelope
            env = entry.family == :env_curve ? MB::Sound.adsr(*ENVELOPE_DEMO, curve: entry.name) : MB::Sound.public_send(entry.name, *ENVELOPE_DEMO)
            g = Playable.graph(env)
            Playable::Graph.new(nodes: g.nodes, description: "#{path} shaping a triangle and some noise", ends: true,
                                note: "an envelope shapes a sound: 220.hz.saw * #{entry.family == :env_curve ? "adsr(0.01, 0.3, 0.6, 0.5, curve: #{entry.name.inspect})" : entry.to_ruby}")
          else
            raise Playable::Unplayable, "#{path} is a #{entry.kind} (#{entry.label}): nothing to play by itself"
          end
        end

        # The Entry +what+ names for `audition`: an Entry, or a Symbol
        # naming one entry (any family; L.all's words).  Raises
        # ArgumentError with the choices when a name is ambiguous or
        # unknown.
        def entry_for(what)
          return what if what.is_a?(Entry)
          raise ArgumentError, "audition takes a library entry (L.inst.dnb.dnb_reese, L.fx.reverb.hall) or its name (got #{what.inspect})" unless what.is_a?(Symbol)
          found = Heads::Query.new(nil, path: 'L.all').word(what)
          return found if found.is_a?(Entry)
          raise ArgumentError, "audition #{what.inspect}: #{found.size} entries are named or tagged #{what} (#{found.first(6).map(&:head_path).join(', ')}#{found.size > 6 ? ', ...' : ''}): give one"
        rescue KeyError => e
          raise ArgumentError, "audition #{what.inspect}: #{e.message}"
        end
      end
    end
  end
end

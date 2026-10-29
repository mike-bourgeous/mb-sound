module MB
  module Sound
    module Library
      # What `play entry` plays (Entry#to_playable; library-instruments-1):
      # the maintainer's guesses `play L.fx.bar`, `play L.inst.x`.
      # Instruments play a demo phrase (struck ones moved toward their
      # resonator's typical pitch), kits each voice once, resonator effects
      # one strike of their struck instrument (Struck), clips on their
      # instrument; other effects say how to hear them.
      module Audition
        # A beat for kit entries.
        KIT_DEMO = { kick: 'x...x...x...x...', snare: '....x.......x...', closed_hat: 'x.x.x.x.x.x.x.xx' }.freeze

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
            raise Playable::Unplayable, "#{path} is an effect: hear it on a sound, e.g. play 220.hz.saw.at(0.2).for(1).then(&#{path})"
          else
            raise Playable::Unplayable, "#{path} is a #{entry.kind} (#{entry.label}): nothing to play by itself"
          end
        end
      end
    end
  end
end

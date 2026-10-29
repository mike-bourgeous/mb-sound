module MB
  module Sound
    # Console methods for buses and sends (see Session::Buses and
    # design/notes/buses.md): named effect buses that tracks send to, group
    # buses that tracks play into, and sidechains that read a bus or track
    # by name.  MB::Sound extends itself with this module.
    #
    # Example (bin/sound.rb):
    #     bus(:verb) { |sig| sig.reverb(:hall, mix: 1) }
    #     bus(:echo, to: :verb) { |sig| sig.delay(1.n8.dotted, feedback: 0.4, mix: 1) }
    #     bg :keys, 220.hz.triangle.at(-20.db), send: { verb: -12.db, echo: -18.db }
    #     feed :keys, :verb, -6.db, over: 2.bars    # change a send (journaled, undoable)
    #     feed :keys, :echo, :space                 # a send following knob :space
    #     track(:kick, to: :drums) { |k| tr808(k) } # a track's main out into a bus
    #     bg :bass, bass_line.duck(:drums, only: :kick)   # sidechain from a drum voice
    #     mute :verb; solo :keys                    # buses are strip names (a solo keeps its buses)
    #     buses                                     # what each bus does
    module BusMethods
      # With a block (or +to:+), defines bus +name+: the block builds its
      # effect chain from the bus input like a master chain (one parameter
      # gets every channel as a bundle; no block passes it through), and
      # its output goes to +to:+ (:master, the default, or another bus).
      # Defining it again swaps the chain at the launch point (+on:+,
      # +in:+, +at:+) with the old chain's tails spilling over, or over a
      # +fade:+ in bars (0 cuts).  Returns the journal entry.
      #
      # Without a block or +to:+, returns a node that reads bus (or track)
      # +name+ in a graph: a bundle of the session's channels, or with
      # +only:+ the node of that name inside the track's graph (a drum
      # voice, or a node given `.named(:x)`), one channel.
      #
      #     bus(:verb) { |sig| sig.reverb(:hall, mix: 1) }
      #     pad.compress(sidechain: bus(:drums))
      def bus(name = nil, to: nil, only: nil, at: nil, on: nil, in: nil, fade: nil, &block)
        if name.nil?
          # (`bus` alone, from the take; omnibus15)
          raise ArgumentError, 'bus needs a name: `bus(:verb) { |sig| sig.reverb(:hall, mix: 1) }` makes one, ' \
                               '`track :keys, send: { verb: -12.db }` feeds it, `bus(:verb)` alone reads it, `buses` lists them'
        end
        point = LaunchPoint.of(binding) or return nil
        if block.nil? && to.nil?
          raise ArgumentError, 'Pass a block or to: to define a bus (bus(:name) alone reads it)' if point.given? || !fade.nil?
          return Session.current.bus_tap(name, only: only)
        end
        raise ArgumentError, 'only: is for reading a bus or track (bus(:drums, only: :kick)), not for defining one' if only

        session_command(name, label: "bus #{name.inspect}", kind: :bus) { |s, time|
          s.bus(name, to: to || :master, at: point, fade: fade, start_time: point.given? ? nil : time, &block)
        }
      end

      # Lists the buses: name => "verb: reverb (to master)".
      def buses
        Session.current.bus_info
      end

      # Changes the send from player or track +name+ into bus +bus+ to
      # +level+ (a linear gain like `-6.db`, 0 for off, or a knob name or
      # node to follow): now with a 5 ms glide, at a launch point (+on:+,
      # +in:+, +at:+), or over +over:+ (bars, a Duration, or a Length;
      # linear in gain, shaped by +curve:+, from where it is or +from:+).
      # Returns the journal entry; undoable.  Also available as
      # #send_level and #fx_send (`send` is every Ruby object's method-call
      # method).
      #
      #     feed :keys, :verb, -6.db, over: 2, on: :bar
      def feed(name, bus, level, at: nil, on: nil, in: nil, over: nil, curve: nil, from: nil, smooth: nil)
        point = LaunchPoint.of(binding) or return nil
        name = player_name(name)
        session_command(name, label: "feed #{name.inspect}, #{bus.inspect}", kind: :send) { |s, time|
          s.feed(name, bus, level, at: point, over: over, curve: curve, from: from, smooth: smooth, start_time: point.given? ? nil : time)
        }
      end
      alias send_level feed
      alias fx_send feed

      # The routing of every player name: name => { to:, send: { bus =>
      # level } }.
      def routes
        Session.current.routes
      end
    end
  end
end

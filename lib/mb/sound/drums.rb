module MB
  module Sound
    # Drum machine voices and kits built from library nodes (resonator
    # pings, oscillators, noise, filters, envelopes, delays).  Each voice is
    # a Drums::Voice node played by triggers: a grid row or any clip, a
    # Notes, a MIDI stream, or a trigger signal (impulses valued at their
    # velocity, like Notes#trigger).  A Drums::Kit mixes the voices of a
    # drum machine, playing a whole grid (rows by name) or any MIDI source
    # (notes routed by the General MIDI drum map, see TR808::GM_MAP).
    #
    # Machines: TR808 (see MB::Sound::DrumMethods#tr808 for the console
    # API).  The goal is playability and inspiration, not exact emulation.
    module Drums
      # How much louder (dB) a grid accent (X, velocity 1) is than a plain
      # hit (x, velocity Sequence::Clip::DEFAULT_VELOCITY) by default; see
      # .accented.
      DEFAULT_ACCENT = 6.0

      # The level (dB) of the default grid velocity (0.75) relative to 1.
      DEFAULT_VELOCITY_DB = 20 * Math.log10(Sequence::Clip::DEFAULT_VELOCITY)

      module_function

      # Returns a Notes for a drum +source+ (a Notes as is; a Clip, Seq,
      # MIDI::Stream, or anything MIDI::Stream.for takes, without sustain
      # pedals), or nil if +source+ is a plain graph node (a trigger signal).
      def notes_for(source)
        return source if source.is_a?(MB::Sound::Notes)
        return nil if source.respond_to?(:sample) && !source.is_a?(Sequence::Clip)

        MB::Sound::Notes.new(source, sustain: false)
      end

      # The trigger signal of a +source+ (see .notes_for): Notes#trigger, or
      # the node itself.
      def trigger_for(source)
        notes = notes_for(source)
        notes ? notes.trigger : source
      end

      # Maps the impulse heights (velocities) of +trigger+ so a grid accent
      # (velocity 1) is +accent+ dB louder than a plain hit (velocity 0.75):
      # velocity ** (accent / 2.5).  MIDI velocities follow the same curve
      # (the default 6 dB is about velocity ** 2.4).  An accent of 0 makes
      # every hit full level.
      def accented(trigger, accent = DEFAULT_ACCENT)
        exponent = accent.to_f / -DEFAULT_VELOCITY_DB
        raise ArgumentError, "Accent must be 0 dB or more (got #{accent.inspect})" if exponent < 0
        return trigger if exponent == 1

        (trigger.aabs ** [exponent, 1e-3].max).named("accent #{MB::M.sigfigs(accent.to_f, 3)} dB")
      end

      # A one-shot decay envelope on every rising edge of +trigger+: rises
      # over +attack+ and falls to silence over +time+ (seconds, a Length, or
      # a node) along a +curve+ dB exponential (see Envelope).  Its peak is
      # the trigger's height (the velocity) unless +velocity: false+.
      def decay_env(trigger, time, attack: 0.0005, curve: 60, velocity: true)
        MB::Sound.adsr(
          attack, time, 0.0, 0.001,
          trigger: trigger, velocity: velocity ? trigger : nil, sensitivity: velocity ? 0..1 : 0,
          curve: [0, curve, curve], hold: false
        )
      end

      # Sums +nodes+ (numbers are skipped) into one node that keeps going
      # until every input has ended (a Mixer without stop_early), so a ring
      # outlives a click.
      def mix(*nodes)
        nodes = nodes.flatten.reject { |n| n.is_a?(Numeric) && n == 0 }
        return nodes.first if nodes.length == 1

        GraphNode::Mixer.new(nodes, stop_early: false)
      end

      # A frequency in Hz from a number, Pitch/Note, or node.
      def hz(value)
        value.is_a?(MB::Sound::Pitch) ? value.oscillator_frequency : value
      end

      # 2 ** +x+ for numbers or nodes.
      def exp2(x)
        2.0 ** x
      end

      # Checks +knobs+ against a voice's +defaults+ and returns them merged.
      def knobs(voice, defaults, knobs)
        extra = knobs.keys - defaults.keys
        unless extra.empty?
          raise ArgumentError, "Unknown #{voice} knob#{'s' if extra.length > 1} #{extra.map(&:inspect).join(', ')} (knobs: #{defaults.keys.map(&:inspect).join(', ')})"
        end
        defaults.merge(knobs)
      end
    end
  end
end

require_relative 'drums/voice'
require_relative 'drums/kit'
require_relative 'drums/tr808'

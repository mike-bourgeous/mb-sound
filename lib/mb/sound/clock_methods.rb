module MB
  module Sound
    # Console commands for clocks (see MB::Sound::Clock): timebases for
    # clips and audio loops other than the session's bars.
    #
    #     clock :tide, 31.1.seconds                 # a loop period
    #     clock :reese, 138.75.bpm                  # its own tempo
    #     clock :swing_half, 5/4r                   # a ratio of the session tempo
    #     clock :tide, 31.1.seconds, speed: :tide_speed   # speed from a knob
    #     gear :reese, 165 => 138.75                # the ratio 138.75/165
    #     track :bowl, clock: :tide do |c| ... end  # a track's clips on :tide
    #     bg :bass, bassline, clock: :reese
    #     bowl % 19.7.seconds; riff.clocked(:reese)
    #     clocks                                    # name => what, and where
    module ClockMethods
      # Defines (or redefines) the Session clock +name+ from +base+ (a
      # Tempo like 138.75.bpm, a Rational ratio of the session tempo like
      # 5/4r, or a loop period like 19.7.seconds), with +speed:+ (a number,
      # a knob name, knob(:x), or a param like cc(1, 0.5..2)), or returns
      # the existing clock without a base.  Clock names share the
      # Session's namespace with tracks and knobs.  Returns the Clock.
      def clock(name, base = nil, speed: nil)
        session = Session.current
        if base.nil?
          raise ArgumentError, "clock #{name.inspect}, x: give a tempo (138.75.bpm), a ratio (5/4r), or a period (19.7.seconds)" unless speed.nil?
          return session.clock!(name)
        end
        if base.is_a?(GraphNode) || base.is_a?(Range)
          # (`clock :woozy, 0.1.hz.lfo.at(0.5..2)`: from the take; omnibus15)
          raise ArgumentError, "clock #{name.inspect}, base: the base is a fixed tempo (138.75.bpm), ratio (5/4r), or period (19.7.seconds) " \
                               "(got #{ArgTypes.describe_value(base)}); a moving speed goes in speed:, e.g. " \
                               "`clock #{name.inspect}, 1/1r, speed: 4.bars.lfo.at(0.5..2)` (a tempo LFO, knob(:x), or cc(1, 0.5..2))"
        end
        session.define_clock(name, base, speed: speed.nil? ? 1 : speed)
      end

      # Defines clock +name+ as a gear ratio between two tempos:
      # `gear :reese, 165 => 138.75` is `clock :reese, 138.75/165r` (a
      # ratio of the session tempo: the record plays at 138.75 while the
      # set is at 165, and follows the set's tempo changes in proportion).
      # Numbers or Tempos.  Returns the Clock.
      def gear(name, mapping = nil, speed: nil, **pairs)
        mapping = pairs if mapping.nil? && !pairs.empty?
        unless mapping.is_a?(Hash) && mapping.length == 1
          raise ArgumentError, "gear #{name.inspect}, from => to: two tempos, e.g. `gear #{name.inspect}, 165 => 138.75` (got #{mapping.inspect})"
        end
        from, to = mapping.first
        from = from.is_a?(Tempo) ? from : Tempo.new(from)
        to = to.is_a?(Tempo) ? to : Tempo.new(to)
        clock(name, to / from, speed: speed)
      end

      # Lists the clocks: name => "19.7 s period, cycle 4 + 0.12".
      def clocks
        Session.current.clock_info
      end
    end

    module Sequence
      module Clocked
        # Puts +sound+ on clock +clock+ (a clip or Sample, or the clips and
        # loop players inside a graph or bundle; see PlaybackMethods#bg's
        # +clock:+).  Clips with a clock of their own keep it.  Returns the
        # clocked sound.
        def self.apply(sound, clock)
          return sound if clock.nil?
          case sound
          when Sequence::Clip then sound.clocking ? sound : sound.clocked(clock)
          when MB::Sound::Sample then sound.clocked(clock)
          when Array then sound.map { |s| apply(s, clock) }
          else
            nodes = sound.respond_to?(:outputs) ? sound.outputs : [sound]
            found = nodes.flat_map { |n| n.respond_to?(:graph) ? [n, *n.graph] : [n] }
            hits = found.select { |n| n.respond_to?(:reclock) }
            raise ArgumentError, "clock: needs a clip, a Sample, or a graph playing clips or loops (got #{sound.class})" if hits.empty?
            c = MB::Sound::Clock.coerce(clock)
            c = check_name(c) if c.is_a?(Symbol)
            hits.uniq.each { |n| n.reclock(c) }
            sound
          end
        end
      end
    end
  end
end

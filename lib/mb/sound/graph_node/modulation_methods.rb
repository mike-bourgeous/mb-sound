module MB
  module Sound
    module GraphNode
      # The modulation effects' DSL methods (#flanger, #rotary), included
      # in GraphNode and Channels.  Not run per channel (see
      # ChannelDispatch::EXCLUDED): a stereo input's sides get LFOs
      # +spread+ apart, and a rotary speaker has one input.
      module ModulationMethods
        # A flanger: a short swept delay sweeping a comb of notches.
        #
        # See GraphNode::Flanger.
        #
        # +preset_or_rate+ is a preset name (:sweep, the default; :jet,
        # :sheen, :steel, :orbit, :tape_flange; `L.fx.flanger`) or the LFO rate:
        # Hz, a Pitch, a musical length per cycle that follows the tempo
        # (`2.bars`, `knob(:len).bars`), a Length per cycle (`4.seconds`),
        # or a node of Hz.  Options override the preset's settings (numbers
        # or nodes where noted):
        # +:delay+ - The sweep's center delay: seconds or a length (`2.ms`;
        #            a node of seconds too).  The comb's notches sit at odd
        #            multiples of 1 / (2 delay).
        # +:range+ - Sweep width in octaves of delay at depth 1 (a node
        #            too), or a Range of delay times for the sweep's ends
        #            (`0.5.ms..8.ms`, then without +:delay+).
        # +:depth+ - Share of the range the LFO sweeps, 0..1 (node too).
        # +:feedback+ - Feedback around the delay, -0.95..0.95 (node too):
        #               positive sharpens the comb's peaks, negative makes
        #               it hollow and metallic.
        # +:mix+ - Linear dry/wet crossfade, 0..1 (0.5: equal parts, the
        #          deepest notches); multiplies +:dry+ and +:wet+ (levels,
        #          1 by default; a negative wet inverts the wet polarity).
        # +:spread+ - The right side's LFO phase offset in cycles (0.25 a
        #             quarter, 0.5 opposite); nonzero makes a mono input
        #             stereo.  A stereo input is always flanged per side.
        # +:shape+ - :triangle or :sine.
        # +:phase+ - The left LFO's starting phase in cycles.
        # +:law+ - :octaves (default: the delay, and so the notches, move
        #          evenly in pitch) or :linear (the delay moves evenly in
        #          time between the same ends).
        # +:through_zero+ - true delays the dry signal by +:delay+ too, so
        #                   the sweep passes it (tape flanging; adds
        #                   +:delay+ of latency).
        # +:sweep+ - A node of -1..1 replacing the LFO (an envelope, a
        #            knob, an LFO of your own), on both sides.
        # +:interpolation+ - The delay's reads (:sinc, :cubic, :linear;
        #                    see #delay).
        #
        # Examples (bin/sound.rb):
        #     bg :pad, 110.hz.saw.at(-12.db).flanger                   # :sweep
        #     bg :drums, drums.flanger(:jet)
        #     bg :pad, 110.hz.saw.at(-12.db).flanger(2.bars, feedback: -0.7, spread: 0.25)
        #     bg :pad, 110.hz.saw.at(-12.db).flanger(:steel, range: 0.3.ms..3.ms)
        #     v.hz.saw.flanger(sweep: v.amp_env * 2 - 1, depth: 0.8)   # an envelope sweep
        def flanger(preset_or_rate = nil, **options)
          Flanger.build(self, preset_or_rate, **options)
        end

        # A rotary speaker: spinning horn and drum rotors.
        #
        # See GraphNode::Rotary.
        #
        # The sound splits at +:crossover+ (800 Hz) into a treble horn and a
        # bass drum that spin; each rotor's distance to a microphone sweeps
        # a short delay (Doppler: the pitch wavers) and its direction its
        # level (tremolo), and the two microphones +:spread+ of a turn apart
        # make the stereo.  +preset+ is :cabinet (default, slow), :whirl
        # (fast), or :chorale (gentle and wide; `L.fx.rotary`).  Options
        # override it:
        # +:speed+ - :slow (chorale), :fast (tremolo), :stop, a number 0..1,
        #            or a node of 0..1 (a knob) to switch live: the horn
        #            spins up in about a second, the drum in about five.
        # +:crossover+ - Hz between the drum and the horn.
        # +:horn+, +:drum+ - levels (gains, `-3.db`, or nodes).
        # +:doppler+, +:tremolo+ - depth scales (1 = the cabinet).
        # +:spread+ - the microphones' angle in turns (0 mono, 0.5 opposite).
        # +:ramp+ - scale on the spin-up and slow-down times.
        # +:mix+ - linear dry/wet (1 the cabinet alone; number or node).
        #
        # Returns a stereo bundle (a stereo input is mixed to mono first,
        # as the cabinet has one input).
        #
        # Examples (bin/sound.rb):
        #     bg :organ, organ.rotary                         # slow
        #     bg :organ, organ.rotary(:whirl)                 # fast
        #     bg :organ, organ.rotary(speed: knob(:spin))     # turn :spin, 1 to speed up, 0 to slow down
        def rotary(preset = nil, **options)
          Rotary.build(self, preset, **options)
        end
        alias rotary_speaker rotary
      end
    end
  end
end

module MB
  module Sound
    module GraphNode
      # The #flanger DSL method, included in GraphNode and Channels.  Not
      # run per channel (see ChannelDispatch::EXCLUDED): a stereo input's
      # sides get LFOs +spread+ apart.
      module FlangerMethods
        # A flanger (GraphNode::Flanger): a short delay swept by an LFO sweeps a comb of notches.
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
      end
    end
  end
end

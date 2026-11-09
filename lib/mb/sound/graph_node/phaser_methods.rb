module MB
  module Sound
    module GraphNode
      # The #phaser DSL method, included in GraphNode and Channels.  Not run
      # per channel (see ChannelDispatch::EXCLUDED): a stereo input's sides
      # get LFOs +spread+ apart.
      module PhaserMethods
        # A phaser (GraphNode::Phaser): moving notches from LFO-swept allpass stages.
        #
        # +preset_or_rate+ is a preset name (:vintage, the default; :swirl,
        # :ripple, :deep12, :jet; `L.fx.phaser`) or the LFO rate: Hz, a Pitch,
        # a musical length per cycle that follows the tempo (`1.bar`,
        # `2.bars`, `knob(:len).bars`), a Length per cycle (`4.seconds`), or
        # a node of Hz.  Options override the preset's settings (numbers or
        # nodes where noted):
        # +:depth+ - Share of the range the LFO sweeps, 0..1 (node too).
        # +:stages+ - Allpass stages, 2-12, even (stages / 2 notches).
        # +:feedback+ - Feedback around the stages, -0.95..0.95 (node too):
        #               resonant peaks between the notches; negative moves
        #               them halfway.
        # +:mix+ - Linear dry/wet crossfade, 0..1 (0.5 default: equal parts,
        #          the deepest notches); multiplies +:dry+ and +:wet+ (levels,
        #          1 by default; a negative wet inverts the wet polarity,
        #          turning notches into peaks).
        # +:center+ - Sweep center in Hz (a Pitch or a node too).
        # +:range+ - Sweep width in octaves at depth 1 (a node too), or a
        #            Range of frequencies for the sweep's ends (`200..5000`,
        #            then without +:center+).
        # +:spread+ - The right side's LFO phase offset in cycles (0.25 a
        #             quarter, 0.5 opposite); nonzero makes a mono input
        #             stereo.  A stereo input is always phased per side.
        # +:shape+ - :sine (default) or :triangle.
        # +:phase+ - The left LFO's starting phase in cycles.
        # +:sweep+ - A node of -1..1 replacing the LFO (an envelope, a
        #            knob, an LFO of your own), on both sides.
        #
        # Examples (bin/sound.rb):
        #     bg :pad, 110.hz.saw.at(-12.db).phaser                    # :vintage
        #     bg :pad, 110.hz.saw.at(-12.db).phaser(:swirl)            # stereo swirl
        #     bg :pad, 110.hz.saw.at(-12.db).phaser(1.bar, stages: 8, feedback: 0.6)
        #     bg :pad, 110.hz.saw.at(-12.db).phaser(:jet, range: 300..6000)
        #     v.hz.saw.phaser(sweep: v.amp_env * 2 - 1, depth: 0.8)   # an envelope sweep
        def phaser(preset_or_rate = nil, **options)
          Phaser.build(self, preset_or_rate, **options)
        end
      end
    end
  end
end

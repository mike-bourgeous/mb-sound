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
        # :ripple, :deep12, :jet, :barberpole, :circle; `L.fx.phaser`) or the LFO rate: Hz, a Pitch,
        # a musical length per cycle that follows the tempo (`1.bar`,
        # `2.bars`, `knob(:len).bars`), a Length per cycle (`4.seconds`), or
        # a node of Hz.  Options override the preset's settings (numbers or
        # nodes where noted):
        # +:depth+ - Share of the range the LFO sweeps, 0..1 (node too).
        # +:stages+ - Allpass stages, 2-32, even (stages / 2 notches).
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
        # +:above+ - Keeps the lows dry below this frequency (Hz or a Pitch;
        #            a 4th-order Linkwitz-Riley split), so a kick keeps its
        #            weight: `drums.phaser(:ripple, above: 200)`.  :jet has
        #            150 Hz; `above: nil` phases everything.
        # +:amount+ - One knob from light (0) to extreme (1); 0.5 is the
        #             preset as it is.  Moves depth, mix, and feedback
        #             together (and stages, for a number: halved at 0,
        #             doubled at 1); a node (a knob) moves them live.
        # +:direction+ - :up or :down makes a barber pole: staggered sweeps
        #                crossfaded so the notches climb (or fall) forever,
        #                one pass over +:range+ per LFO cycle (the
        #                :barberpole preset; `phaser(:jet, direction: :down)`).
        #                A number or a node is a direction knob: its sign
        #                the way the notches move, its size the speed (1
        #                the preset's rate, 2 twice as fast, 0 held still);
        #                turned live it slows, stops, and reverses the
        #                notches where they are, with no jump.  At most
        #                40 passes a second (rate x direction; a moving
        #                direction is clipped there).
        # +:lean+ - Feedback on one half of the LFO's sweep (-1..1, or a
        #           node): 1 keeps the feedback only while the notches rise
        #           (none while they fall), -1 only while they fall, 0.5
        #           half of it on the way back; the resonant whistle sweeps
        #           one way, the plain notches sweep back quietly
        #           (`phaser(:jet, lean: -1)`).  Not with +:sweep+ or
        #           +:direction+.
        # +:oscillate+ - true (mode 0) or a mode index: a self-oscillating
        #                loop on that one resonance (the chain's output
        #                saturated and bandpassed at the mode in the
        #                feedback path); +:feedback+ then goes to +-1.25
        #                and past +-1 the phaser whistles at a level the
        #                loop sets, input or not.  Negative feedback's
        #                modes are the notches from the bottom, positive
        #                feedback's the peaks between them
        #                (Phaser.mode_frequency; Phaser.mode_center).  A
        #                fraction tunes the loop between two modes, a node
        #                moves it (each new mode kicked from silence once),
        #                and a list whistles on several modes at once (a
        #                loop each on one sweep, the dry signal once), with
        #                +:feedback+, +:level+, and +:pitch+ as lists too.
        #                With +:direction+ the barber pole whistles.
        # +:level+ - The oscillating loop's level (a number, Decibels, or
        #            a node; 1 by default): its saturator is
        #            level * tanh(y / level), so the whistle's level
        #            follows it (`level: 14` is the input scaled by 1/14
        #            and the output by 14).
        # +:pitch+ - The whistle's frequency at the sweep's middle (Hz, a
        #            Pitch, or a node such as `notes.freq`), in place of
        #            +:center+: the stages' center is set from the mode,
        #            every sample.  A Range is the whistle's sweep ends
        #            (`pitch: 250..2110`, in place of +:range+).
        # +:lanes+ - N phasers in series, their LFOs spread evenly around
        #            the circle (phases i / N), so with an even N as many
        #            notches fall as rise at every moment (the :circle
        #            preset: 4 lanes of 4 stages).  Not with +:sweep+ or
        #            +:direction+.
        #
        # Examples (bin/sound.rb):
        #     bg :pad, 110.hz.saw.at(-12.db).phaser                    # :vintage
        #     bg :pad, 110.hz.saw.at(-12.db).phaser(:swirl)            # stereo swirl
        #     bg :pad, 110.hz.saw.at(-12.db).phaser(1.bar, stages: 8, feedback: 0.6)
        #     bg :pad, 110.hz.saw.at(-12.db).phaser(:jet, range: 300..6000)
        #     v.hz.saw.phaser(sweep: v.amp_env * 2 - 1, depth: 0.8)   # an envelope sweep
        #     bg :drums, drums.phaser(:ripple, above: 150)             # the kick stays dry
        #     bg :pad, pad.phaser(:swirl, amount: knob(:phase_amt))     # light to extreme on a knob
        #     bg :pad, pad.phaser(:barberpole)                          # forever rising (direction: :down falls)
        #     bg :pad, pad.phaser(:barberpole, direction: knob(:dir, 1, range: -2..2))   # turn it: up, stop, down, faster
        #     bg :pad, pad.phaser(:jet, lean: -1)                       # the whoosh only on the way down
        #     bg :pad, pad.phaser(stages: 32, oscillate: 7, feedback: -1.05, pitch: 250..2110, rate: 4.bars, mix: 0.1)   # a whistle 250-2110 Hz
        #     bg :pad, pad.phaser(stages: 16, oscillate: [2, 4, 6], pitch: [A4, E5, C6], feedback: [0, 1, 2].map { |i| 4.bars.lfo.with_phase(i / 3.0).at(-0.9..-1.2) }, range: 2, rate: 8.bars, mix: 0.1)   # three whistles swelling in turn
        #     bg :lead, pad.phaser(stages: 8, oscillate: 1, feedback: -1.15, pitch: seq(A4, C5, E5).n4.loop.freq, mix: 0.1)   # a whistle singing a melody
        #     bg :pad, pad.phaser(:circle)                              # as many notches falling as rising
        def phaser(preset_or_rate = nil, **options)
          Phaser.build(self, preset_or_rate, **options)
        end
      end
    end
  end
end

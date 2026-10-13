module MB
  module Sound
    module GraphNode
      # DSL methods that turn graphs into Samples (see MB::Sound::Sample).
      module SamplingMethods
        # Renders this graph offline into a Sample (see SamplerMethods#bounce)
        # for +length+ (a Duration, Length, or bars), e.g. resampling a bass:
        #
        #     reese = 55.hz.unison(5, detune: 20.cents) { |p| p.saw }.lp4(900)
        #     bass = reese.bounce(1.bar, root: A1)
        #     synth(midi, voices: 1) { |v| bass.looped.play(v) * v.env(0.005, 0.2, 0.8, 0.1) }
        def bounce(length, **options)
          MB::Sound.bounce(self, length, **options)
        end
      end
    end
  end
end

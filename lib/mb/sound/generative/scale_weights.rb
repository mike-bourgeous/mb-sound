module MB
  module Sound
    module Generative
      # Scale#weights (included into MB::Sound::Scale): the scale as a
      # probability scale.
      module ScaleWeights
        # The scale's notes as Weights (see Generative::Weights): 1 each,
        # or one weight per degree from the root (cycled), e.g. the root,
        # third, and fifth favored:
        #
        #     scale(:dorian, :d).weights
        #     scale(:minor, :a).weights(4, 1, 3, 1, 3, 1, 1)
        def weights(*degrees)
          Weights.of_scale(self, degrees.empty? ? nil : degrees)
        end
      end
    end

    Scale.include(Generative::ScaleWeights)
  end
end

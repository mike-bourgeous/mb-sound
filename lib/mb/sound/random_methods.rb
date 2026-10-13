module MB
  module Sound
    # The root random number generator, so random sounds repeat (user
    # decision, 2026-10-04: one RNG design).  Everything random that new code
    # adds either draws from the root generator, or, where the order of draws
    # can't be controlled (e.g. oscillators drawing a new phase at every note
    # in a render loop), takes a sub-seed from it when it is created
    # (#next_seed) and keeps its own Random.  Creating things in the same
    # order after the same #seed gives the same sounds.
    #
    # The root seed starts at RANDOM_SEED from the environment, or
    # DEFAULT_SEED, so renders repeat from run to run; set another with
    # `seed 42` (bin/sound.rb).
    #
    # Users so far: Tone#random_phase (alias #rnd), Tone#noise (and
    # MB::Sound.noise; each noise tone keeps its own splitmix64 state, see
    # Tone::State#noise), Synth (per-lane seeds through #with_seed),
    # Pitch#unison (a sub-seed for the random detune layout), and spectral
    # Noise (draws from Internal.root_rng).  Older randomness keeps its own
    # generators for now: Clip seeds (probability, #permute) and Reverb
    # seeds; they could move to sub-seeds from here later.
    module RandomMethods
      # The root seed used unless RANDOM_SEED is set or #seed is called.
      DEFAULT_SEED = 0

      # Restarts the root random number generator from +seed+ (an Integer),
      # so everything random created from now on repeats.  Returns the seed.
      # Without an argument, returns the current root seed (see
      # #random_seed).
      #
      # Example (bin/sound.rb):
      #     seed 7
      #     play 3.times.map { 110.hz.saw.rnd }.sum   # the same phases each time after `seed 7`
      def seed(seed = nil)
        return random_seed if seed.nil?

        Internal.reseed(seed)
      end

      # The root seed (see #seed).
      def random_seed
        Internal.root_seed
      end

      # Runs the block, then puts the root random generator back as it
      # was, so seeds drawn inside don't change later draws (graph
      # documents build set patches once to save them; see
      # GraphIO::SetWriter).  Returns the block's value.
      def keeping_random_state
        rng = Internal.root_rng.dup
        seed = Internal.root_seed
        yield
      ensure
        Internal.restore_rng(rng, seed) if rng
      end

      # Draws a seed for a sub-generator from the root generator (a
      # non-negative Integer below 2**62), e.g. `Random.new(MB::Sound.next_seed)`.
      def next_seed
        Internal.root_rng.rand(1 << 62)
      end

      # Returns +seed+: graph documents write seeds drawn when the graph
      # was built as `seed: drawn_seed(N)` (GraphIO::FORMAT 2), so
      # GraphIO.load(seeds: :fresh) can redraw them while keeping seeds the
      # code gave.  Their loader reads the mark itself; this method lets
      # the same text run as plain Ruby.
      def drawn_seed(seed)
        Integer(seed)
      end

      # Runs the block with the root generator restarted from +seed+, then
      # puts the previous root generator back as it was (its draws so far
      # kept), so everything random created in the block (e.g. Tone#rnd)
      # depends only on +seed+ and the block's own order of draws.  Used by
      # Synth to give every voice lane its own seed (synth seed + lane
      # index).  Returns the block's value.
      #
      #     a = MB::Sound.with_seed(5) { 110.hz.saw.rnd }
      #     b = MB::Sound.with_seed(5) { 110.hz.saw.rnd }   # same phase as a
      def with_seed(seed)
        old_seed = random_seed
        old_rng = Internal.root_rng
        seed(seed)
        yield
      ensure
        Internal.restore_rng(old_rng, old_seed) if old_rng
      end
    end
  end
end

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
    # Tone::State#noise), Synth (per-lane seeds through #with_seed).  Older
    # randomness keeps its own generators for now: Noise::RAND (spectral
    # noise), Clip seeds
    # (probability, #permute), and Reverb/FdnReverb seeds; they could move to
    # sub-seeds from here later.
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

        @root_seed = Integer(seed)
        @root_rng = Random.new(@root_seed)
        @root_seed
      end

      # The root seed (see #seed).
      def random_seed
        root_rng
        @root_seed
      end

      # The root random number generator (a Random), for code that can
      # control the order of its draws.
      def root_rng
        seed(default_seed) if @root_rng.nil?
        @root_rng
      end

      # The root seed at startup: RANDOM_SEED from the environment, or
      # DEFAULT_SEED (restore it with `seed default_seed`; the specs do
      # before every example).
      def default_seed
        ENV['RANDOM_SEED'] ? Integer(ENV['RANDOM_SEED']) : DEFAULT_SEED
      end

      # Draws a seed for a sub-generator from the root generator (a
      # non-negative Integer below 2**62), e.g. `Random.new(MB::Sound.next_seed)`.
      def next_seed
        root_rng.rand(1 << 62)
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
        old_rng = @root_rng
        seed(seed)
        yield
      ensure
        if old_rng
          @root_seed = old_seed
          @root_rng = old_rng
        end
      end
    end
  end
end

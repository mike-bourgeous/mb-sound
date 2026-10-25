module MB
  module Sound
    # Turns on YJIT, Ruby's JIT compiler, for bin/ scripts, with a lower call
    # threshold than Ruby's default (yjit-threshold-1, 2026-10-25).
    #
    # YJIT compiles a method (and each branch of it, lazily) once it has been
    # called CALL_THRESHOLD times.  Ruby's default is 30 calls (120 in apps
    # with over 40k instruction sequences), so code that runs only a few
    # times before a scene change lands (a patch's first buffers, a new
    # player's setup) still compiles on the render thread when the change
    # lands.  A lower threshold compiles it during the warm-ups
    # (MB::Sound.warm_up, Arrangement#rehearse) instead.  Ruby fixes the
    # threshold when YJIT starts, so bin/ scripts no longer enable YJIT in
    # their shebang (RUBY_YJIT_ENABLE=1); they set MB_SOUND_YJIT=1, and
    # loading mb-sound enables YJIT here with the threshold, before the
    # library's own code loads.
    #
    # Environment:
    # - MB_SOUND_YJIT=1 (the shebang): enable YJIT at CALL_THRESHOLD; 0 or
    #   unset: leave YJIT as Ruby started it.
    # - MB_SOUND_YJIT_CALL_THRESHOLD=n: use n calls instead (for A/B
    #   measurements with bin/scene_profile.rb).
    #
    # YJIT already on when mb-sound loads (`ruby --yjit`, RUBY_YJIT_ENABLE=1,
    # `--yjit-call-threshold=n`) keeps Ruby's threshold: RubyVM::YJIT.enable
    # can't change it once YJIT runs.  `ruby bin/x.rb` and specs run without
    # YJIT, as before.
    module JIT
      # Calls before YJIT compiles a method or block (Ruby's default: 30).
      CALL_THRESHOLD = 30

      # Turns YJIT on as the environment asks (see the module comment).
      # Returns the threshold used, or nil when it left YJIT alone.
      def self.enable_from_env(env = ENV)
        return nil unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
        return nil unless %w[1 true on yes].include?(env['MB_SOUND_YJIT'].to_s.downcase)
        return nil if RubyVM::YJIT.enabled?

        threshold = Integer(env['MB_SOUND_YJIT_CALL_THRESHOLD'] || CALL_THRESHOLD)
        raise ArgumentError, "MB_SOUND_YJIT_CALL_THRESHOLD must be at least 1 (got #{threshold})" if threshold < 1

        RubyVM::YJIT.enable(call_threshold: threshold)
        @threshold = threshold
      end

      # The call threshold this module enabled YJIT with, or nil when it
      # didn't (YJIT off, or turned on by Ruby's own options).
      def self.threshold
        @threshold
      end
    end
  end
end

MB::Sound::JIT.enable_from_env

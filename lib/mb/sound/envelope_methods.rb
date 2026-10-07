module MB
  module Sound
    # Envelope constructors, extended into MB::Sound (and so available in
    # bin/sound.rb).  Each makes an MB::Sound::Envelope from a preset (see
    # Envelope::PRESETS) with positional attack, decay, sustain, and release
    # (defaults: 5 ms, 0.2 s, 0.7, 0.3 s), plus any Envelope#initialize
    # options (+:curve+, +:hold+, +:gate+, +:trigger+, +:velocity+,
    # +:choke+, +:sensitivity+, +:velocity_scale+, +:legato+, +:sample_rate+).
    #
    # Without a gate or trigger, they are one-shots: they start on their
    # first sample, release +:hold+ seconds later (default twice the attack
    # plus decay, at least 0.1 s), and end (see Envelope).
    #
    # Examples:
    #     play 220.hz.ramp * adsr(0.01, 0.3, 0.5, 1)
    #     play 220.hz.ramp * adsr(0.01, 0.3, 0.5, 1, curve: :swell, hold: 2)
    #     play 220.hz.ramp * amp_env(0.002, 1, 0, 1)
    #     play 220.hz.ramp.filter(:lowpass, cutoff: 150.constant * filter_env(0.005, 0.5, depth: 5), quality: 6)
    #     play 220.hz.pm(440.hz.at(3) * fm_env(0.002, 2)) * amp_env(0.002, 2, 0.2, 1)
    #     play (120.hz.ramp * adsr(gate: 2.hz.lfo.square.at(0..1))).filter(1200.hz.lowpass)
    module EnvelopeMethods
      # A generic envelope with :analog curves ([12, 60, 60] dB) and velocity
      # sensitivity 0..1 (the peak is the velocity).
      def adsr(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        MB::Sound::Envelope.preset(:adsr, attack, decay, sustain, release, **options)
      end

      # A generic control envelope with :analog curves and velocity
      # sensitivity 0.5..1 (linear).
      def env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        MB::Sound::Envelope.preset(:env, attack, decay, sustain, release, **options)
      end
      alias envelope env

      # An amplitude envelope: :analog curves with a gentler release ([12,
      # 60, 40] dB, for pads), and velocity from -18 dB to 0 dB (interpolated
      # in dB).
      def amp_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        MB::Sound::Envelope.preset(:amp_env, attack, decay, sustain, release, **options)
      end
      alias amp_envelope amp_env

      # An FM modulation index envelope: :dx curves ([-30, 30, 30] dB),
      # sustain 0 by default, and velocity from -12 dB to 0 dB (in dB), a
      # moderate per-operator velocity sensitivity like classic FM synths
      # (was -18 dB until 2026-10-07; in a chain of modulators the ranges
      # add up, so 18 dB per operator gave about 30 dB of index range).
      # Give +sensitivity:+ for more or less (e.g. `-18.db..0.db`).
      def fm_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        MB::Sound::Envelope.preset(:fm_env, attack, decay, sustain, release, **options)
      end
      alias fm_envelope fm_env

      # A filter cutoff envelope whose output is a cutoff multiplier, 2 **
      # (env * depth): :analog curves, sustain 0 by default, +:depth+ (alias
      # +:octaves+) 2 octaves by default (a number of octaves, an Interval
      # once that exists, or a graph node such as the mod wheel, read every
      # sample), and velocity sensitivity 0.5..1 (linear) scaling the depth.
      #
      # Example:
      #     play 110.hz.ramp.filter(:lowpass, cutoff: 200.constant * filter_env(0.01, 0.4, depth: 4), quality: 4)
      def filter_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        MB::Sound::Envelope.preset(:filter_env, attack, decay, sustain, release, **options)
      end
      alias filt_env filter_env
      alias filter_envelope filter_env

      # An SQ-80-style envelope from panel values (levels -63..+63, times
      # 0..63; see MB::Sound::SQ80.env_options for the keywords), plus any
      # Envelope options (+:gate+, +:trigger+, ...).  Velocity and key time
      # scaling (+:t1v+, +:tk+) need +:velocity+ and +:key+ nodes;
      # Notes#sq80_env wires them to the notes.
      #
      #     play 220.hz.ramp * sq80_env(l1: 63, l2: 30, l3: 45, t1: 20, t2: 24, t3: 30, t4: 32)
      def sq80_env(**options)
        known = SQ80.method(:env_options).parameters.map(&:last)
        env_opts = options.slice(*known)
        rest = options.except(*known, :velocity)
        rest[:velocity] = options[:velocity] if options.key?(:velocity)
        segments_opts = SQ80.env_options(**env_opts)
        MB::Sound::Envelope.preset(:adsr, **segments_opts, **rest)
      end
    end
  end
end

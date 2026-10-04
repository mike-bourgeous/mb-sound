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
    # first sample, hold the sustain level for +:hold+ seconds, release, and
    # end (see Envelope).
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
      # sustain 0 by default, and velocity from -18 dB to 0 dB (in dB).
      def fm_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        MB::Sound::Envelope.preset(:fm_env, attack, decay, sustain, release, **options)
      end
      alias fm_envelope fm_env

      # A filter cutoff envelope whose output is a cutoff multiplier, 2 **
      # (env * depth): :analog curves, sustain 0 by default, +:depth+ (alias
      # +:octaves+) 2 octaves by default (a number of octaves, or an Interval
      # once that exists), and velocity sensitivity 0.5..1 (linear) scaling
      # the depth.
      #
      # Example:
      #     play 110.hz.ramp.filter(:lowpass, cutoff: 200.constant * filter_env(0.01, 0.4, depth: 4), quality: 4)
      def filter_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        MB::Sound::Envelope.preset(:filter_env, attack, decay, sustain, release, **options)
      end
      alias filt_env filter_env
      alias filter_envelope filter_env
    end
  end
end

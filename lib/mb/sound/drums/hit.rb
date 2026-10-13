module MB
  module Sound
    module Drums
      # What a kit voice's block builds its sound from (see Drums::Machine
      # and DrumMethods#kit): the voice's accented trigger (#trigger, #t),
      # its knobs (one reader per knob, e.g. #tune, #decay; or #[]), and
      # layers played by the trigger, each at the hit's velocity:
      #
      # - #body (alias #ping): a struck resonator (a decaying sine) with
      #   optional pitch sweep, the kick, tom, and snare head;
      # - #noise: filtered noise under a decay envelope (snares, claps,
      #   shakers);
      # - #click: a short lowpassed tick (the beater);
      # - #metal: a bank of square oscillators at inharmonic ratios (808
      #   hats and cymbals), to filter and multiply by an #env;
      # - #sample: a MB::Sound::Sample played from the start on every hit
      #   (sampler-style, pitched by +tune+ semitones);
      # - #fm: a two-operator FM tone (bells, zaps, FM toms);
      # - #env (decay envelopes), #sweep (pitch envelopes), #velocity
      #   (the hit's velocity, held), #bursts (repeated hits: claps), #mix.
      #
      # Layers are graph nodes, so they mix with + and scale with *, and
      # every other DSL method works on them too:
      #
      #     voice :kick, tune: 50, decay: 0.5 do |h|
      #       h.body(h.tune, decay: h.decay, sweep: 3, sweep_time: 25.ms).softclip(0.7) + h.click(0.4)
      #     end
      #
      # A block without parameters runs on the Hit itself, so the same
      # voice is also
      #
      #     voice :kick, tune: 50, decay: 0.5 do
      #       body(tune, decay: decay, sweep: 3, sweep_time: 25.ms).softclip(0.7) + click(0.4)
      #     end
      class Hit
        # Layer and helper names, which knobs may not use.
        METHODS = [
          :trigger, :t, :velocity, :env, :sweep, :body, :ping, :noise, :click, :metal, :sample, :fm, :bursts, :mix,
          :knobs, :name, :machine, :hz,
        ].freeze

        # The voice name.
        attr_reader :name

        # The machine name.
        attr_reader :machine

        # The voice's knob values (a frozen Hash).
        attr_reader :knobs

        # Made by Drums::Machine for each voice of a kit: +trigger+ is the
        # accented trigger, +knobs+ the voice's knob values.
        def initialize(trigger, knobs:, name:, machine:)
          @trigger = trigger
          @knobs = knobs.dup.freeze
          @name = name
          @machine = machine
          @knobs.each_key do |k|
            define_singleton_method(k) { @knobs[k] }
          end
        end

        # The value of knob +k+.
        def [](k)
          @knobs.fetch(k) { raise KeyError, "No knob #{k.inspect} on the #{@name} (knobs: #{@knobs.keys.map(&:inspect).join(', ')})" }
        end

        # The voice's trigger signal: an impulse at every hit, valued at the
        # accented velocity (see Drums.accented).  Alias #t.
        def trigger
          @trigger
        end
        alias t trigger

        # The velocity of the last hit, held until the next (0 before the
        # first), e.g. to scale a layer without an envelope.
        def velocity
          @trigger.sample_hold(@trigger)
        end

        # A decay envelope on every hit, peaking at the velocity (unless
        # +velocity: false+): rises over +attack+ (0.5 ms) and falls 60 dB
        # (+curve+) over +decay+ (seconds, a Length, or a node).
        def env(decay, attack: 0.0005, curve: 60, velocity: true)
          Drums.decay_env(@trigger, decay, attack: attack, curve: curve, velocity: velocity)
        end

        # A pitch envelope (a multiplier for a frequency): 1 + +amount+ at
        # every hit, falling back to 1 over +time+ along a +curve+ dB
        # exponential.  `body(50, sweep: 3)` is `body(50 * sweep(3, 30.ms))`.
        def sweep(amount, time = 0.03, curve: 60)
          return 1 if amount.is_a?(Numeric) && amount == 0
          Drums.decay_env(@trigger, time, velocity: false, curve: curve) * amount + 1
        end

        # A struck resonator (GraphNode::Resonator): every hit rings as a
        # sine at +freq+ (Hz, a Pitch, or a node) falling 60 dB in +decay+,
        # at the hit's velocity.  +sweep+ bends the pitch up by that ratio
        # at the strike, falling over +sweep_time+ (a kick's punch: 3 starts
        # at 4x the pitch); +drop+ and +drop_time+ add a second, slower
        # bend (a tom's droop).  Alias #ping.
        def body(freq, decay: 0.3, sweep: 0, sweep_time: 0.03, drop: 0, drop_time: 0.1, phase: 0)
          f = Drums.hz(freq)
          bend = mult(self.sweep(sweep, sweep_time), self.sweep(drop, drop_time, curve: 30))
          @trigger.ping(one?(bend) ? f : bend * f, decay: decay, phase: phase)
        end
        alias ping body

        # Noise through optional filters (+highpass+, +lowpass+, +bandpass+
        # cutoffs in Hz, numbers or nodes; +quality+ for each) under a decay
        # envelope (#env with +decay+, +attack+, +curve+).  +color+ :white
        # (default) or a node to use instead of white noise.
        def noise(decay: 0.2, attack: 0.0005, curve: 60, highpass: nil, lowpass: nil, bandpass: nil, quality: 0.7, color: :white)
          n = color == :white ? MB::Sound.noise : color
          n = n.filter(:highpass, cutoff: Drums.hz(highpass), quality: quality) if highpass
          n = n.filter(:bandpass, cutoff: Drums.hz(bandpass), quality: quality) if bandpass
          n = n.filter(:lowpass, cutoff: Drums.hz(lowpass), quality: quality) if lowpass
          n * env(decay, attack: attack, curve: curve)
        end

        # The beater's click: the trigger itself (one sample at the
        # velocity) through a lowpass whose cutoff +tone+ (0..1) moves from
        # 400 Hz to 6.4 kHz, at +level+.
        def click(level = 0.5, tone: 0.5)
          (@trigger * level).filter(:lowpass, cutoff: Drums.exp2(tone * 4) * 400, quality: 0.7)
        end

        # A bank of naive square oscillators (the 808's six at 205.3 Hz and
        # up by default), lowest at +tune+ (Hz, a Pitch, or a node), the
        # others at the ratios of +freqs+, mixed to about 1.  Free running
        # (not reset by hits): filter it and multiply by an #env.
        def metal(tune = TR808::METAL[0], freqs: TR808::METAL)
          TR808.metal(tune, freqs: freqs)
        end

        # Plays +sample+ (a MB::Sound::Sample; a Sampler::Instrument plays
        # its first region's key) from its start on every hit, +tune+
        # semitones up (a number or a node), at the hit's velocity: under a
        # decay envelope (#env) of +decay+ if given, else held at the
        # velocity until the next hit.  +interpolation+ and +mips+ as for
        # Sampler::Instrument#play (`interpolation: :none, mips: false` is
        # the grainy drop-sample read).
        def sample(sample, tune: 0, decay: nil, curve: 60, interpolation: :optimal, mips: nil)
          inst = sample.is_a?(MB::Sound::Sampler::Instrument) ? sample : sample.to_instrument(keytrack: 0)
          root = inst.regions.first&.root || inst.regions.first&.sample&.root || 60
          options = { trigger: @trigger, number: root, interpolation: interpolation }
          options[:mips] = mips unless mips.nil?
          if tune.is_a?(Numeric) || tune.is_a?(MB::Sound::Interval)
            options[:transpose] = tune
          else
            # The sampler reads +freq+ relative to the key's own frequency
            a4 = MB::Sound.tuning.frequency_of(69).to_f
            options[:freq] = Drums.exp2(tune / 12.0) * (a4 * 2.0**((root - 69) / 12.0))
          end
          s = inst.play(**options)
          s * (decay.nil? ? velocity : env(decay, curve: curve))
        end

        # A two-operator FM tone restarted by every hit: a sine carrier at
        # +freq+ (Hz, a Pitch, or a node) phase-modulated by a sine at
        # +ratio+ × +freq+ with +index+ (cycles) falling to nothing over
        # +index_decay+ (the brightness of the strike), under a decay
        # envelope of +decay+.  +sweep+ and +sweep_time+ bend the pitch as
        # for #body.
        def fm(freq, ratio: 1.4, index: 0.5, decay: 0.3, index_decay: nil, sweep: 0, sweep_time: 0.03)
          f = Drums.hz(freq)
          bend = self.sweep(sweep, sweep_time)
          f = bend * f unless one?(bend)
          fnode = f.is_a?(Numeric) ? f.constant : f
          mod = (fnode * ratio).tone.sine.reset(@trigger)
          idx = index_decay ? env(index_decay, velocity: false) * index : index
          carrier = fnode.tone.sine.pm(mod, idx).reset(@trigger)
          carrier * env(decay)
        end

        # The trigger repeated +count+ times +spacing+ apart (seconds or a
        # Length), each repeat +falloff+ times the last (Drums::Repeats): a
        # clap's bursts.  `bursts(4, 9.ms)` hits at 0, 9, 18, and 27 ms.
        def bursts(count, spacing, falloff: 1.0)
          s = MB::Sound::Length.seconds(spacing)
          Repeats.new(@trigger, Array.new(Integer(count)) { |i| [i * s, falloff**i] })
        end

        # Sums nodes (numbers of 0 are skipped) into one node that lasts as
        # long as its longest input (see Drums.mix).
        def mix(*nodes)
          Drums.mix(*nodes)
        end

        # Hz from a number, Pitch, or node (see Drums.hz).
        def hz(value)
          Drums.hz(value)
        end

        def to_s
          "#{@machine} #{@name} hit (#{@knobs.keys.join(', ')})"
        end

        def inspect
          "#<#{self.class.name} #{to_s}>"
        end

        private

        def mult(a, b)
          return b if one?(a)
          return a if one?(b)
          a * b
        end

        def one?(x)
          x.is_a?(Numeric) && x == 1
        end
      end
    end
  end
end

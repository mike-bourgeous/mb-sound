module MB
  module Sound
    module GraphNode
      # Tape echoes (delay-fx-1): a delay whose repeats run through a tape
      # sim on every pass, one sample at a time in a feedback loop
      # (FeedbackLoop): wow and flutter wobble the delay time (a slow
      # random drift and a sine), and every pass runs through a highpass
      # and a lowpass for the tape's band (+low_cut:+, +tone:+) and
      # saturation (+drive:+).  The
      # loop's own delay absorbs the insert's latency, so the repeats stay
      # +time+ apart on average.
      #
      # Presets are the :delay family of the library (`L.fx.delay.dub`,
      # `find 'dark echo'`); use them with GraphNode#tape_echo
      # (StereoDelayMethods#tape_echo):
      #
      #     play keys.tape_echo(:dub)
      #     play keys.tape_echo(:tape, time: 1.n8.dotted, feedback: 0.6)
      #     play drums.tape_echo(:ping_pong, mix: 0.25)
      module TapeEcho
        extend MB::Sound::Presettable

        # The settings a tape echo takes (see StereoDelayMethods#tape_echo).
        KEYS = %i[time feedback mix tone low_cut drive wow flutter stereo spread].freeze

        # Stereo modes: :mono (one tape per channel), :ping_pong (repeats
        # alternate left and right; stereo out).
        STEREO = %i[mono ping_pong].freeze

        # The wow rate (Hz; a smooth random drift, GraphNode::Drift) and the
        # flutter rate (Hz; a sine).
        WOW_RATE = 0.7
        FLUTTER_RATE = 6.5

        # Latency compensation of the echo loops: the group delay at DC
        # (FeedbackLoop's compensate: :dc).  The default :pitch mode
        # measures the loop's phase at 1 / time, a few Hz for an echo,
        # where the tape's highpass leads by up to 180 degrees: repeats
        # landed up to half an echo late (measured on master-ai 8c7c1c24:
        # `delay(0.1, feedback: 0.5) { |fb| fb.filter(200.hz.highpass(quality:
        # 0.5)).filter(3000.hz.lowpass(quality: 0.5)) }` puts its first echo
        # 2321 samples late; :dc within a few samples).
        COMPENSATE = :dc

        # Delay time smoothing: off, since #delay's default smoothing starts
        # a node delay time at 0 and glides it up (measured: a 0.375 s
        # wobbled time read 1200-1600 samples in the first buffers, so the
        # tail ended before the first echo); the wobble is smooth anyway.
        SMOOTH = false

        preset_family :delay, kind: :effect, label: 'tape echo preset', keys: KEYS,
          about: 'Tape echoes: sig.tape_echo(:dub)',
          apply: ->(name, input, **options) { input.tape_echo(name, **options) },
          code: ->(e) { "sig.tape_echo(#{e.name.inspect})" }

        param :time, 0.375, range: 0.001..4.0, unit: 's', description: 'Echo time (seconds or a musical length)'
        param :feedback, 0.5, range: 0.0..1.2, description: 'How much of each repeat comes back (above 1 the saturation holds it)'
        param :mix, 0.35, range: 0.0..1.0, description: 'Dry/wet crossfade (0 dry, 1 wet)'
        param :tone, 3500.0, range: 300.0..16000.0, unit: 'Hz', description: 'Lowpass cutoff in the loop (darker repeats below)'
        param :low_cut, 150.0, range: 20.0..1000.0, unit: 'Hz', description: 'Highpass cutoff in the loop'
        param :drive, 1.5, range: 0.0..10.0, description: 'Saturation drive in the loop (0 clean)'
        param :wow, 0.3, range: 0.0..2.0, unit: 'ms', description: 'Slow random delay wobble depth in ms'
        param :flutter, 0.05, range: 0.0..0.5, unit: 'ms', description: 'Fast delay wobble depth in ms'

        preset :reel, time: 3.n16, feedback: 0.5, mix: 0.35, tone: 3500.0, low_cut: 150.0, drive: 1.5, wow: 0.3, flutter: 0.05,
          tags: %i[warm tape echo], about: 'A warm reel-to-reel echo on dotted eighths (3/16), darker every repeat'
        preset :slapback, time: 0.11, feedback: 0.12, mix: 0.3, tone: 5000.0, low_cut: 120.0, drive: 1.2, wow: 0.1, flutter: 0.03,
          tags: %i[short rockabilly vocal], about: 'One quick 110 ms tape slap (rockabilly vocals, guitars)'
        preset :ping_pong, time: 1.n8, feedback: 0.55, mix: 0.3, tone: 4000.0, low_cut: 200.0, drive: 1.2, wow: 0.15, flutter: 0.03,
          stereo: :ping_pong, spread: 1.0,
          tags: %i[stereo wide echo], about: 'Tape repeats bouncing left and right on eighths'
        preset :dub, time: 3.n8, feedback: 0.72, mix: 0.4, tone: 1800.0, low_cut: 300.0, drive: 2.5, wow: 0.5, flutter: 0.08,
          tags: %i[dark dub long saturated], about: 'Dark, saturated dub echo on dotted quarters, ringing on'

        # Builds a tape echo of +input+ (a node or a bundle) from preset
        # +name+ and +options+ (see StereoDelayMethods#tape_echo).
        def self.build(input, name, seed: nil, **options)
          bad = options.keys - KEYS
          unless bad.empty?
            guess = DidYouMean::SpellChecker.new(dictionary: KEYS + [:seed]).correct(bad[0]).first
            raise ArgumentError, "tape_echo: unknown option#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')}#{guess ? " (did you mean #{guess.inspect}?)" : ''}"
          end

          s = { stereo: :mono, spread: 1.0 }.merge(preset_settings(name)).merge(options)
          unless STEREO.include?(s[:stereo])
            raise ArgumentError, "tape_echo stereo: is #{STEREO.map(&:inspect).join(' or ')} (got #{s[:stereo].inspect})"
          end
          seed ||= MB::Sound.next_seed

          l, r = StereoDelayMethods.sides(input, 'tape_echo')
          if s[:stereo] == :ping_pong
            ping_pong(l.equal?(r) ? l : (l + r) * 0.5, l, r, s, seed)
          elsif l.equal?(r) && !input.is_a?(Channels)
            mono(l, s, seed)
          else
            Channels.new([mono(l, s, seed), mono(r, s, seed + 1)])
          end
        end

        # One tape: dry and echoes of +sig+ mixed.
        def self.mono(sig, s, seed)
          g = s[:feedback]
          time = wobbled(s[:time], s, [seed])
          echoes = sig.feedback(sustain: false, compensate: COMPENSATE) { |fb, inp| color((inp + fb * g).delay(time, smooth: SMOOTH), s) }
          StereoDelayMethods.wet_dry([sig], [echoes], dry: 1, wet: 1, mix: s[:mix]).outputs[0]
        end

        # Tape ping-pong: the right repeats are a loop of one 2 x +time+
        # delay through two tape passes (the left pass and the right pass,
        # their wobbles summed in the one delay's time, so latency
        # compensation keeps the repeats 2 x +time+ apart on average), and
        # the left repeats are the input plus the fed-back right repeats
        # through +time+ and a tape pass outside the loop (a loop's inner
        # nodes can't be read outside it).
        def self.ping_pong(mono_in, l, r, s, seed)
          g = s[:feedback]
          long = wobbled(s[:time] * 2, s, [seed, seed + 1]) # (Durations, Lengths, numbers, and nodes double)
          right = mono_in.feedback(sustain: false, compensate: COMPENSATE) { |fb, inp|
            color(color((inp + fb * g).delay(long, smooth: SMOOTH), s), s) * g
          }
          left = color(DelayMethods.ring_sum(mono_in, right * g).delay(wobbled(s[:time], s, [seed + 2]), smooth: SMOOTH), s)

          echoes = Channels.new([left, right])
          spread = s[:spread]
          echoes = echoes.width(spread) unless spread.is_a?(Numeric) && spread == 1
          StereoDelayMethods.wet_dry([l, r], echoes.outputs, dry: 1, wet: 1, mix: s[:mix])
        end

        # The delay time +time+ plus one wow and flutter wobble per seed in
        # +seeds+ (tape passes), in seconds (a Duration follows the tempo
        # through Sequence::TempoNode), or +time+ itself without wobble.
        def self.wobbled(time, s, seeds)
          wow = s[:wow].to_f / 1000.0
          flutter = s[:flutter].to_f / 1000.0
          return time unless wow > 0 || flutter > 0

          t = Sequence::TempoNode.seconds_source(time)
          seeds.each do |sd|
            t = t + MB::Sound.drift(WOW_RATE, range: -wow..wow, seed: sd) if wow > 0
            t = t + FLUTTER_RATE.hz.sine.at(flutter) if flutter > 0
          end
          t
        end

        # The tape's color on +sig+ (one pass): a highpass and a lowpass
        # for its band, then saturation.
        def self.color(sig, s)
          sig = sig.filter(:highpass, cutoff: s[:low_cut], quality: 0.5**0.5) if s[:low_cut] && s[:low_cut] > 0
          sig = sig.filter(:lowpass, cutoff: s[:tone], quality: 0.5**0.5) if s[:tone] && s[:tone] > 0
          drive = s[:drive].to_f
          sig = (sig * drive).softclip * (1.0 / drive) if drive > 0
          sig
        end
      end
    end
  end
end

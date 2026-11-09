module MB
  module Sound
    module GraphNode
      # A rotary speaker (effects-2): the sound split at a crossover into a
      # treble horn and a bass drum that spin, each heard by two
      # microphones.  As a rotor turns, its distance to a microphone
      # changes (the Doppler effect: a delay swept by the rotation, so the
      # pitch wavers) and it points toward and away from it (amplitude
      # modulation); the microphones sit +spread+ of a turn apart, so the
      # left and right channels move against each other.  The rotors spin
      # at a slow (chorale) or fast (tremolo) speed and take time to get
      # there: the horn about a second, the heavier drum several (each
      # rotor's speed glides at a fixed rate, Hz per second, up and down).
      #
      # Built from the library's pieces: a Linkwitz-Riley crossover of SVFs,
      # a #delay per rotor and microphone with a node time (sinc reads),
      # Tone LFOs whose frequency is the rotor's gliding speed (#clip_rate),
      # so the rotation's phase stays continuous through speed changes.
      #
      # Presets are the :rotary family of the library (`L.fx.rotary`); use
      # them with GraphNode#rotary (ModulationMethods#rotary).  Numbers from
      # published descriptions of the classic two-rotor organ cabinet (see
      # design/notes/modulation.md; unverified against measurements).
      module Rotary
        extend MB::Sound::Presettable

        # Rotor speeds in Hz: [slow, fast].
        HORN_SPEEDS = [0.8, 6.7].freeze
        DRUM_SPEEDS = [0.67, 5.7].freeze

        # Seconds each rotor takes from slow to fast and from fast to slow
        # at ramp: 1 (its glide is linear in Hz).
        HORN_RAMP = [1.0, 1.6].freeze
        DRUM_RAMP = [5.0, 5.5].freeze

        # Doppler depth (seconds of delay either side of the center) and
        # the delay's center, per rotor at doppler: 1.
        HORN_DOPPLER = 0.00044
        DRUM_DOPPLER = 0.00015
        CENTER = 0.0012

        # Amplitude modulation depth per rotor at tremolo: 1 (the gain
        # falls by this share when the rotor points away).
        HORN_AM = 0.5
        DRUM_AM = 0.3

        # Seconds of silence played after the input (longer than any delay
        # read: CENTER + HORN_DOPPLER * doppler at most half of it).
        TAIL = 0.01

        # Speeds by name (0 slow, 1 fast; :stop holds both rotors still).
        SPEEDS = { slow: 0.0, chorale: 0.0, fast: 1.0, tremolo: 1.0, stop: :stop }.freeze

        # The settings GraphNode#rotary takes (besides a preset name).
        KEYS = %i[speed crossover horn drum doppler tremolo spread ramp mix].freeze

        preset_family :rotary, kind: :effect, label: 'rotary preset', keys: KEYS,
          about: 'Rotary speakers: sig.rotary(:whirl)',
          apply: ->(name, input, **options) { input.rotary(name, **options) },
          code: ->(e) { "sig.rotary(#{e.name.inspect})" }

        param :speed, :slow, range: SPEEDS.keys, description: 'Rotor speed: :slow (chorale), :fast (tremolo), :stop; or 0..1 / a node (a knob) to switch live'
        param :crossover, 800.0, range: 200.0..3000.0, unit: 'Hz', description: 'Crossover between the drum (below) and the horn (above)'
        param :horn, 1.0, range: 0.0..2.0, description: 'Horn level (linear gain, or dB like -3.db)'
        param :drum, 1.0, range: 0.0..2.0, description: 'Drum level (linear gain, or dB like -3.db)'
        param :doppler, 1.0, range: 0.0..3.0, description: 'Doppler (pitch waver) depth, 1 = the cabinet'
        param :tremolo, 1.0, range: 0.0..2.0, description: 'Amplitude modulation depth, 1 = the cabinet (at most 1 / the rotor depth)'
        param :spread, 0.25, range: 0.0..0.5, unit: 'cycles', description: 'Angle between the two microphones in turns (0 mono, 0.5 opposite)'
        param :ramp, 1.0, range: 0.1..4.0, description: 'Scale on the rotors\' spin-up and slow-down times'
        param :mix, 1.0, range: 0.0..1.0, description: 'Dry/wet crossfade, linear (1 the cabinet alone)'

        preset :cabinet, speed: :slow, crossover: 800.0, horn: 1.0, drum: 1.0, doppler: 1.0, tremolo: 1.0, spread: 0.25, ramp: 1.0, mix: 1.0,
          tags: %i[organ classic slow], about: 'A two-rotor organ cabinet at chorale (slow) speed (the defaults)'
        preset :whirl, speed: :fast, crossover: 800.0, horn: 1.0, drum: 1.0, doppler: 1.0, tremolo: 1.0, spread: 0.25, ramp: 1.0, mix: 1.0,
          tags: %i[organ fast], about: 'The same cabinet at tremolo (fast) speed'
        preset :chorale, speed: :slow, crossover: 800.0, horn: 0.9, drum: 1.0, doppler: 0.6, tremolo: 0.5, spread: 0.4, ramp: 1.0, mix: 0.8,
          tags: %i[gentle subtle stereo], about: 'A gentle, wide slow rotation, a little dry mixed in, for pads and keys'

        # The default preset (GraphNode#rotary without a preset name).
        DEFAULT_PRESET = :cabinet

        # Builds a rotary speaker on +input+ (mono, or stereo mixed to mono
        # as a cabinet's single input; see ModulationMethods#rotary).
        # Returns a stereo Channels bundle (the two microphones).
        def self.build(input, preset = nil, **options)
          bad = options.keys - KEYS
          unless bad.empty?
            guess = DidYouMean::SpellChecker.new(dictionary: KEYS).correct(bad[0]).first
            raise ArgumentError, "rotary: unknown option#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')}#{guess ? " (did you mean #{guess.inspect}?)" : ''}"
          end
          unless preset.nil? || preset.is_a?(Symbol) || preset.is_a?(String)
            raise ArgumentError, "rotary: give a preset name (#{preset_names.map(&:inspect).join(', ')}) or speed: (got #{preset.inspect})"
          end

          s = preset_settings(preset.nil? ? DEFAULT_PRESET : preset.to_sym).merge(options)
          sample_rate = input.sample_rate
          crossover = GraphNode.build_setting(s[:crossover])
          crossover = crossover.oscillator_frequency if crossover.is_a?(MB::Sound::Pitch)
          unless crossover.is_a?(Numeric) && crossover.real? && crossover > 0 && crossover < sample_rate / 2
            raise ArgumentError, "rotary crossover: is a frequency in Hz below Nyquist (got #{s[:crossover].inspect})"
          end
          doppler = number(s[:doppler], 'doppler')
          tremolo = number(s[:tremolo], 'tremolo')
          ramp = number(s[:ramp], 'ramp')
          raise ArgumentError, "rotary ramp: is a positive scale (got #{ramp})" unless ramp > 0
          spread = ModulationLfo.cycles(s[:spread], 'rotary', 'spread')
          horn_level = level(s[:horn], 'horn')
          drum_level = level(s[:drum], 'drum')
          speed = speed_setting(s[:speed])
          mix = s[:mix]
          mix = BlendMethods.amount(GraphNode.build_setting(mix)) unless mix.nil?

          l, r = StereoDelayMethods.sides(input, 'rotary')
          mono = l.equal?(r) ? l : (l + r) * 0.5
          # Both microphones end together, TAIL after the input, with every
          # delayed sample played (the delays don't ring out on their own:
          # each would end its longest delay after the input, a different
          # frame per side)
          raise ArgumentError, "rotary doppler: #{doppler} reaches past the tail" if CENTER + HORN_DOPPLER * doppler > TAIL / 2
          mono = mono.and_then(MB::Sound.silence(TAIL))
          lo, hi = split(mono, crossover)
          mics = [0.0, spread]

          horn = rotor(hi, speed, HORN_SPEEDS, HORN_RAMP, ramp, HORN_DOPPLER * doppler, HORN_AM * tremolo, mics, sample_rate, 'horn')
          drum = rotor(lo, speed, DRUM_SPEEDS, DRUM_RAMP, ramp, DRUM_DOPPLER * doppler, DRUM_AM * tremolo, mics, sample_rate, 'drum')
          # (sums that read every input to the end: both bands of the
          # crossover end on one frame, and a Mixer stopping at its first
          # ended input left the other band unread)
          wets = [0, 1].map { |m|
            parts = [Chorus.scale(horn[m], horn_level), Chorus.scale(drum[m], drum_level)].compact
            parts.empty? ? horn[m] * 0 : parts.length == 1 ? parts[0] : Mixer.new(parts, sample_rate: sample_rate, stop_early: false)
          }
          return Channels.new(wets) if mix.nil? || (mix.is_a?(Numeric) && mix == 1)

          dg, wg = BlendMethods.gains(mix, :linear)
          dry = [l.get_sampler, r.get_sampler]
          Channels.new([0, 1].map { |m| Chorus.mix(dry[m], wets[m], dg, wg) || dry[m] * 0 })
        end

        # [low, high] of +node+ split at +frequency+ Hz: Linkwitz-Riley
        # 4th order (each side two Butterworth SVFs, Q 1 / sqrt(2), so the
        # sum is flat).  Independent filters rather than #bands' Crossover:
        # its bands must be read in lockstep, and a short read upstream (the
        # input's end before the TAIL) put one band's Tee a frame ahead
        # ("Crossover band 1 sampled again before the other bands").
        def self.split(node, frequency)
          q = Math.sqrt(0.5)
          lo = node.filter(:lowpass, cutoff: frequency, quality: q).filter(:lowpass, cutoff: frequency, quality: q)
          hi = node.filter(:highpass, cutoff: frequency, quality: q).filter(:highpass, cutoff: frequency, quality: q)
          [lo, hi]
        end

        # One rotor of +band+ heard at microphone phases +mics+ (turns):
        # [left, right].  +speed+ is a number 0..1, :stop, or a node of
        # 0..1; +speeds+ the rotor's [slow, fast] Hz, +ramps+ its seconds
        # from one to the other (times +ramp+).
        def self.rotor(band, speed, speeds, ramps, ramp, doppler, am, mics, sample_rate, name)
          slow, fast = speeds
          rate = rotor_rate(speed, slow, fast, ramps.map { |t| t * ramp }, sample_rate)
          am = am.clamp(0.0, 1.0)
          mics.map { |phase|
            # The rotor's angle from the microphone: cos 0 is pointing at it
            # (nearest: shortest delay, loudest); a sine LFO a quarter turn on
            angle = rotation(rate, phase + 0.25, sample_rate)
            if doppler == 0 && am == 0
              band.get_sampler
            else
              out = doppler == 0 ? band.get_sampler : band.delay(angle * -doppler + CENTER, smooth: false, ring_out: false)
              am == 0 ? out : out * (angle * (am / 2) + (1 - am / 2))
            end
          }
        end

        # The rotor's speed in Hz: a number for a fixed speed, else the
        # speed node mapped to slow..fast gliding at the rotor's ramp
        # (linear in Hz, starting at the slow speed).
        def self.rotor_rate(speed, slow, fast, ramps, sample_rate)
          return 0.0 if speed == :stop
          return slow + (fast - slow) * speed if speed.is_a?(Numeric)

          rise = (fast - slow) / ramps[0]
          fall = (fast - slow) / ramps[1]
          (speed.aclip(0, 1) * (fast - slow) + slow).clip_rate(rise, -fall, reset: slow)
        end

        # A sine LFO of the rotor at +rate+ (Hz, number or node) starting at
        # +phase+ turns, -1..1 (cos of the angle from the microphone).
        def self.rotation(rate, phase, sample_rate)
          return Math.cos(2 * Math::PI * (phase - 0.25)).constant if rate.is_a?(Numeric) && rate == 0
          ModulationLfo.tone(rate, shape: :sine, phase: phase, sample_rate: sample_rate, what: 'rotary')
        end

        # The +speed+ setting as 0..1 (a number), :stop, or a node of 0..1.
        def self.speed_setting(speed)
          speed = GraphNode.build_setting(speed) unless speed.respond_to?(:sample)
          return speed.get_sampler if speed.respond_to?(:sample)
          if speed.is_a?(Symbol)
            v = SPEEDS[speed]
            raise ArgumentError, "rotary speed: is #{SPEEDS.keys.map(&:inspect).join(', ')}, 0..1, or a node (got #{speed.inspect})" if v.nil?
            return v
          end
          unless speed.is_a?(Numeric) && speed.real? && (0..1).cover?(speed)
            raise ArgumentError, "rotary speed: is #{SPEEDS.keys.map(&:inspect).join(', ')}, 0..1, or a node (got #{speed.inspect})"
          end
          speed.to_f
        end

        # A plain number setting (+name+ for errors).
        def self.number(v, name)
          v = GraphNode.build_setting(v)
          raise ArgumentError, "rotary #{name}: is a number of at least 0 (got #{v.inspect})" unless v.is_a?(Numeric) && v.real? && v >= 0
          v.to_f
        end

        # A rotor level: Decibels, a number, or a node.
        def self.level(value, name)
          value = GraphNode.build_setting(value) unless value.respond_to?(:sample)
          return Decibels.gain_of(value, "rotary #{name}", zero: true, above_one: true) if value.is_a?(Decibels)
          return value if value.respond_to?(:sample) || (value.is_a?(Numeric) && value.real? && value >= 0)
          raise ArgumentError, "rotary #{name}: is a level (a number, Decibels, or a node; got #{value.inspect})"
        end
      end
    end
  end
end

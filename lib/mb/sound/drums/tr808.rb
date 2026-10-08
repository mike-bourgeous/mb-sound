module MB
  module Sound
    module Drums
      # TR-808-flavored drum voices, after the classic-synths study (branch
      # research-classic-synths): resonator pings for the bridged-T voices
      # (kick, snare heads, toms, congas, rimshot, claves), six naive square
      # oscillators for the hats, cymbal and cowbell, noise for the snare,
      # clap and maracas.  Playable and inspired by the 808, not an exact
      # emulation.
      #
      # Knobs (numbers or graph nodes, so they can move):
      # - tune: the voice's main frequency in Hz (a number, node, or
      #   Pitch/Note such as E1); for the hats and cymbal the lowest of the
      #   six metal oscillators (205.3 Hz), for the cowbell the lower of its
      #   two squares (540 Hz)
      # - decay: seconds to fall silent (-60 dB), or any Length
      # - tone: 0..1, brightness or balance (see VOICES for each voice)
      # - snappy: 0..1, the snare's noise (the toms' noise breath)
      # - level: output gain (e.g. 0.5 or -6.db)
      # - sigh (kick): how far the pitch sweeps up at the strike (0.45 is
      #   45% above +tune+, falling over 30 ms)
      #
      # Every voice also takes +accent:+ (dB louder for a grid X than an x,
      # or for MIDI velocity 127 than 64; see Drums.accented) and
      # +velocity_curve:+ (:grid or :midi, chosen from the source by
      # default).
      #
      # Examples:
      #     TR808.kick(grid(16, 'X..x..x...x.x...').loop, tune: 48, decay: 1.5)
      #     TR808.cowbell(midi, level: 2)          # any MIDI source plays every hit
      #     TR808.kit(grid(16, kick: 'x...x...', snare: '....x...').loop)
      module TR808
        # The six square oscillators of the hats and cymbal, in Hz (Werner
        # et al., ICMC/SMC 2014: 205.3, 304.4, 369.6, 522.7 nominal; the
        # last two trimmed, typically 540 and 800 Hz, also the cowbell's).
        METAL = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].freeze

        # Default knobs per voice, in mix order.  +level+ sets the kit
        # balance (the kick peaks near 1 at full velocity).
        VOICES = {
          kick: { tune: 52.0, decay: 2.4, tone: 0.5, sigh: 0.45, level: 1.0 }.freeze,
          snare: { tune: 180.0, decay: 0.25, tone: 0.5, snappy: 0.6, level: 0.9 }.freeze,
          rimshot: { tune: 455.0, decay: 0.07, tone: 0.5, level: 0.5 }.freeze,
          clap: { decay: 0.2, tone: 0.5, level: 0.6 }.freeze,
          closed_hat: { tune: METAL[0], decay: 0.06, tone: 0.5, level: 0.35 }.freeze,
          open_hat: { tune: METAL[0], decay: 0.45, tone: 0.5, level: 0.35 }.freeze,
          cymbal: { tune: METAL[0], decay: 1.6, tone: 0.5, level: 0.3 }.freeze,
          cowbell: { tune: 540.0, decay: 0.5, tone: 0.5, level: 0.45 }.freeze,
          low_tom: { tune: 95.0, decay: 1.7, tone: 0.5, snappy: 0.15, level: 0.7 }.freeze,
          mid_tom: { tune: 140.0, decay: 1.5, tone: 0.5, snappy: 0.15, level: 0.65 }.freeze,
          high_tom: { tune: 190.0, decay: 1.3, tone: 0.5, snappy: 0.15, level: 0.6 }.freeze,
          low_conga: { tune: 220.0, decay: 0.9, tone: 0.3, level: 0.55 }.freeze,
          mid_conga: { tune: 330.0, decay: 0.8, tone: 0.3, level: 0.5 }.freeze,
          high_conga: { tune: 440.0, decay: 0.7, tone: 0.3, level: 0.45 }.freeze,
          claves: { tune: 2500.0, decay: 0.15, tone: 0.5, level: 0.35 }.freeze,
          maracas: { decay: 0.06, tone: 0.5, level: 0.3 }.freeze,
        }.freeze

        # dB of `more_cowbell: true` (see .more_cowbell).
        MORE_COWBELL = 6.0

        # dB of more cowbell that doubles its decay (see .more_cowbell).
        MORE_COWBELL_DOUBLING = 12.0

        # Other names for voices (grid rows and keyword arguments).
        ALIASES = {
          bass_drum: :kick, bd: :kick, sd: :snare, rim: :rimshot, side_stick: :rimshot, cp: :clap,
          hat: :closed_hat, hh: :closed_hat, ch: :closed_hat, oh: :open_hat, cy: :cymbal, crash: :cymbal,
          ride: :cymbal, cb: :cowbell, bell: :cowbell, lt: :low_tom, mt: :mid_tom, ht: :high_tom,
          tom: :mid_tom, conga: :mid_conga, lc: :low_conga, mc: :mid_conga, hc: :high_conga,
          cl: :claves, clave: :claves, ma: :maracas, maraca: :maracas, shaker: :maracas,
        }.freeze

        # General MIDI drum notes for each voice (a MIDI pad or drum track
        # plays the kit through these; grid rows named after GM drums land
        # on the same voices).  The 808 has fewer voices than GM, so similar
        # sounds share one (e.g. every cymbal plays the cymbal).
        GM_MAP = {
          kick: [35, 36],
          rimshot: [37],
          snare: [38, 40],
          clap: [39],
          closed_hat: [42, 44],
          open_hat: [46],
          low_tom: [41, 43, 45],
          mid_tom: [47, 48],
          high_tom: [50],
          cymbal: [49, 51, 52, 53, 55, 57, 59],
          cowbell: [56],
          high_conga: [62, 60],
          mid_conga: [63, 61],
          low_conga: [64],
          maracas: [69, 70],
          claves: [75, 76, 77],
        }.freeze

        # Voice names by GM note (from GM_MAP).
        GM_NOTES = GM_MAP.flat_map { |v, notes| notes.map { |n| [n, v] } }.to_h.freeze

        module_function

        # The voice name for +name+ (a voice, an alias, or a GM drum name
        # or note number), or nil.
        def voice_name(name)
          case name
          when Symbol
            return name if VOICES.key?(name)
            return ALIASES[name] if ALIASES.key?(name)
            gm = Sequence::Grid::GM_DRUMS[name]
            gm && GM_NOTES[gm]
          when Numeric
            GM_NOTES[name]
          end
        end

        # Builds the voice +name+ (see VOICES) played by +source+ (see
        # Drums.notes_for; an Array of sources all play it) with +knobs+,
        # returning a Drums::Voice.
        # +:accent+ is in dB (see Drums.accented); +:choke+ (open hat) is a
        # source (or sources) whose hits cut the voice off (the closed hat's,
        # in a kit); +:metal+ is a shared metal oscillator bank (see
        # .metal), as in a kit; +:skip_idle+ as for Voice.
        # +:velocity_curve+ is :grid or :midi (see Drums.accented), by
        # default chosen from the sources (Drums.velocity_curve: clips and
        # grids :grid, MIDI files and live MIDI :midi).
        def voice(name, source, accent: DEFAULT_ACCENT, velocity_curve: nil, choke: nil, metal: nil, skip_idle: true, **knobs)
          key = voice_name(name) || raise(ArgumentError, "Unknown TR-808 voice #{name.inspect} (voices: #{VOICES.keys.join(', ')})")
          k = Drums.knobs(key, VOICES[key], knobs)

          notes = []
          trigger_source = ->(src) {
            list = src.is_a?(Array) ? src : [src]
            raise ArgumentError, "No source for the #{key}" if list.empty?
            Drums.mix(list.map { |s|
              n = Drums.notes_for(s)
              notes << n if n
              n ? n.trigger : s
            })
          }

          velocity_curve ||= Drums.velocity_curve(source.is_a?(Array) ? source : [source])
          tap = Voice::Tap.new('trigger')
          inputs = [[trigger_source.(source), tap]]
          trigger = Drums.accented(tap, accent, curve: velocity_curve)

          extra = {}
          if key == :open_hat && choke
            choke_tap = Voice::Tap.new('choke')
            inputs << [trigger_source.(choke), choke_tap]
            extra[:choke] = choke_tap
          end
          extra[:metal] = metal if metal && [:closed_hat, :open_hat, :cymbal].include?(key)

          graph = Build.public_send(key, trigger, **k, **extra)
          Voice.new(
            graph, name: key, machine: :tr808, inputs: inputs, notes: notes,
            knobs: k.merge(accent: accent, velocity_curve: velocity_curve), skip_idle: skip_idle
          )
        end

        VOICES.each_key do |v|
          define_method(v) do |source, **knobs|
            voice(v, source, **knobs)
          end
          module_function v
        end

        # Builds a Drums::Kit of 808 voices played by +source+:
        # - a grid Kit (`grid(16, kick: 'x...', snare: '....x...')`): each
        #   row plays the voice it names (a voice, an alias such as :hat or
        #   :bd, or a GM drum name; see .voice_name), keeping each row's own
        #   loop (polymeter);
        # - anything else MIDI (a Clip or Seq, a Notes such as the
        #   console's `midi`, a MIDI file or Stream): notes are routed to
        #   voices by GM_MAP (36 kick, 38 snare, 42 closed hat, ...; +:map+
        #   adds or replaces voice => notes entries), every voice of the
        #   map unless +:only+ lists some (for a clip, only the voices its
        #   notes play).
        #
        # Voice knobs are Hashes by voice name (aliases work), e.g. `kick: {
        # tune: 48, decay: 1.2 }`; +:accent+ (dB, see Drums.accented) applies
        # to every voice unless a voice's Hash sets its own, and so does
        # +:velocity_curve+ (:grid or :midi, by default from the source:
        # :grid for grids and clips, :midi for MIDI files and live MIDI;
        # see Drums.accented).  +:more_cowbell+
        # raises the cowbell and lengthens its decay: true for +6 dB, or a
        # number of dB (see .more_cowbell).
        #
        # The open hat is choked by the closed hat, and the hats and cymbal
        # share one metal oscillator bank when their tunes are the same
        # numbers, as on the 808.  Idle voices are skipped unless
        # +skip_idle: false+ (see Voice).
        def kit(source, accent: DEFAULT_ACCENT, velocity_curve: nil, only: nil, map: {}, more_cowbell: nil, skip_idle: true, **settings)
          settings = settings.to_h { |name, k|
            key = voice_name(name) || raise(ArgumentError, "Unknown TR-808 voice #{name.inspect} (voices: #{VOICES.keys.join(', ')})")
            raise ArgumentError, "Knobs for the #{key} must be a Hash (got #{k.inspect})" unless k.is_a?(Hash)
            [key, k]
          }
          settings[:cowbell] = TR808.more_cowbell(settings[:cowbell] || {}, more_cowbell) if more_cowbell

          sources = voice_sources(source, only: only, map: map)
          raise ArgumentError, "Nothing in #{source} plays a TR-808 voice" if sources.empty?

          # Shared metal bank for voices with the same (numeric) tune
          banks = {}
          metal_for = ->(knobs, voice_key) {
            tune = knobs.fetch(:tune, VOICES[voice_key][:tune])
            tune.is_a?(Numeric) ? (banks[tune.to_f] ||= metal(tune)) : nil
          }

          # The open hat's choke reads the closed hat's notes through its own
          # Notes (each voice reads its sources itself)
          choke_sources = ->(src) {
            Array(src).map { |s| s.is_a?(MB::Sound::Notes) ? MB::Sound::Notes.new(s.stream, sustain: false) : s }
          }

          voices = {}
          VOICES.each_key do |v|
            next unless sources.key?(v)

            knobs = settings.fetch(v, {})
            opts = { accent: accent, velocity_curve: velocity_curve, skip_idle: skip_idle }.merge(knobs)
            opts[:metal] = metal_for.(knobs, v) if [:closed_hat, :open_hat, :cymbal].include?(v)
            opts[:choke] = choke_sources.(sources[:closed_hat]) if v == :open_hat && sources[:closed_hat]
            voices[v] = voice(v, sources[v], **opts)
          end

          Kit.new(voices, machine: :tr808)
        end

        # Returns cowbell +knobs+ with more cowbell: +amount+ is true (+6
        # dB) or dB.  The level rises by +amount+ dB and the decay (given or
        # default) grows with it, doubling every MORE_COWBELL_DOUBLING dB:
        # decay × 2 ** (dB / 12), so +6 dB rings about 1.41x as long (0.71
        # s by default) and +12 dB twice as long (1 s).  Negative amounts
        # give less (and shorter) cowbell.
        def more_cowbell(knobs, amount)
          db = amount == true ? MORE_COWBELL : amount.to_f
          knobs.merge(
            level: knobs.fetch(:level, VOICES[:cowbell][:level]) * 10 ** (db / 20.0),
            decay: knobs.fetch(:decay, VOICES[:cowbell][:decay]) * 2 ** (db / MORE_COWBELL_DOUBLING),
          )
        end

        # Sources by voice name for .kit (see there).
        def voice_sources(source, only:, map:)
          only = only && Array(only).map { |v| voice_name(v) || raise(ArgumentError, "Unknown TR-808 voice #{v.inspect}") }

          if source.is_a?(Sequence::Kit)
            groups = Hash.new { |h, k| h[k] = [] }
            source.each do |row, clip|
              key = voice_name(row) || voice_name(clip.events.first&.value)
              raise ArgumentError, "Grid row #{row.inspect} doesn't name a TR-808 voice (voices: #{VOICES.keys.join(', ')})" unless key
              groups[key] << clip if only.nil? || only.include?(key)
            end
            return groups
          end

          gm = GM_MAP.merge(map.to_h { |v, notes|
            [voice_name(v) || raise(ArgumentError, "Unknown TR-808 voice #{v.inspect} in map:"), Array(notes)]
          })
          voices = only || gm.keys
          if source.is_a?(Sequence::Clip)
            # A clip's notes are known: only the voices it plays
            values = source.events.map(&:value)
            voices = voices.select { |v| gm.fetch(v).any? { |n| values.include?(n) } }
          end
          stream = MB::Sound::MIDI::Stream.for(source)
          voices.to_h { |v| [v, MB::Sound::Notes.new(stream.keys(*gm.fetch(v)), sustain: false)] }
        end

        # The six metal oscillators (naive squares, like the circuit) mixed
        # at 1/6 each, with the lowest at +tune+ Hz (number or node) and the
        # others at their 808 ratios.
        def metal(tune = METAL[0], freqs: METAL)
          tune = Drums.hz(tune)
          ratios = freqs.map { |f| f / freqs[0] }
          Drums.mix(ratios.map { |r|
            f = tune * r
            (f.is_a?(Numeric) ? f.hz : f.tone).asquare.at(1.0 / ratios.length)
          }).named('808 metal')
        end

        # The graph builders for each voice, from the (accented) trigger
        # signal and the knobs.  Each returns the voice's graph at about
        # +level+ peak for full velocity.
        module Build
          S = MB::Sound

          # Snare noise: seconds of decay per unit of snappy (plus 0.1 s),
          # and gain per unit of snappy.
          SNARE_NOISE_TIME = 0.25
          SNARE_NOISE_GAIN = 1.4

          module_function

          # Bridged-T resonator pinged by the trigger, its pitch sweeping up
          # by +sigh+ at the strike (the trigger pulse leaking into the
          # resonator), plus a lowpassed click whose brightness is +tone+.
          def kick(t, tune:, decay:, tone:, sigh:, level:)
            sweep = Drums.decay_env(t, 0.03, velocity: false) * sigh + 1
            body = t.ping(sweep * Drums.hz(tune), decay: decay)
            click = (t * (0.35 + 0.5 * tone)).filter(:lowpass, cutoff: Drums.exp2(tone * 4) * 400, quality: 0.7)
            (Drums.mix(body * 0.8, click).softclip(0.8, 1.0) * level).named('808 kick')
          end

          # Two pinged heads (+tune+ and 1.86 × +tune+; +tone+ shifts the
          # balance to the upper one) plus band-limited noise whose level
          # and length are +snappy+.
          def snare(t, tune:, decay:, tone:, snappy:, level:)
            f = Drums.hz(tune)
            low = t.ping(f, decay: decay) * (1.0 - 0.5 * tone)
            high = t.ping(f * 1.86, decay: decay * 0.67) * (0.5 + 0.5 * tone)
            noise = S.noise
              .filter(:highpass, cutoff: 1800, quality: 0.7)
              .filter(:lowpass, cutoff: Drums.exp2(tone - 0.5) * 9000, quality: 0.7)
            noise_env = Drums.decay_env(t, snappy * SNARE_NOISE_TIME + 0.1)
            (Drums.mix(Drums.mix(low, high) * 0.33, noise * noise_env * (snappy * SNARE_NOISE_GAIN)) * level).named('808 snare')
          end

          # Two short pings (455 Hz and 3.66 × that; +tone+ favors the upper
          # one) through a highpass and a hard-ish clip for the knock.
          def rimshot(t, tune:, decay:, tone:, level:)
            f = Drums.hz(tune)
            pings = Drums.mix(t.ping(f, decay: decay) * (1.2 - 0.6 * tone), t.ping(f * 3.66, decay: decay * 0.6) * (0.4 + 0.8 * tone))
            ((pings.filter(:highpass, cutoff: 400, quality: 0.7) * 0.9).softclip(0.8, 1.0) * level).named('808 rimshot')
          end

          # Bandpassed noise (about 1.1 kHz, +tone+ moves it) with three
          # quick bursts about 10.5 ms apart, then a tail of +decay+.
          def clap(t, decay:, tone:, level:)
            spacing = 0.0105
            bursts = Drums.mix(t, t.delay(spacing), t.delay(spacing * 2))
            burst_env = S.adsr(0.0002, spacing * 0.9, 0.0, 0.001, trigger: bursts, velocity: bursts, curve: [0, 20, 20], hold: false)
            tail = t.delay(spacing * 3)
            tail_env = Drums.decay_env(tail, decay)
            noise = S.noise.filter(:bandpass, cutoff: Drums.exp2(tone - 0.5) * 1100, quality: 1.6)
            (noise * (burst_env + tail_env * 0.5) * (4.6 * level)).named('808 clap')
          end

          # The metal oscillators through the upper (~7.1 kHz) band and a
          # highpass (+tone+ moves it ±1/2 octave).
          def hats(metal, tone)
            hp = Drums.exp2(tone - 0.5) * 6000
            metal.filter(:bandpass, cutoff: 7100, quality: 1.2).filter(:highpass, cutoff: hp, quality: 0.7)
          end

          def closed_hat(t, tune:, decay:, tone:, level:, metal: nil)
            band = hats(metal || TR808.metal(tune), tone)
            (band * Drums.decay_env(t, decay) * (7.8 * level)).named('808 closed hat')
          end

          # The open hat: the closed hat's sound with a longer decay, cut off
          # by +choke+ (the closed hat's trigger in a kit).
          def open_hat(t, tune:, decay:, tone:, level:, metal: nil, choke: nil)
            band = hats(metal || TR808.metal(tune), tone)
            env = S.adsr(0.0005, decay, 0.0, 0.001, trigger: t, velocity: t, choke: choke, curve: [0, 60, 60], hold: false)
            (band * env * (5.7 * level)).named('808 open hat')
          end

          # Both metal bands (~3.44 and ~7.1 kHz): +tone+ trades the long
          # lower band for the shorter upper one.
          def cymbal(t, tune:, decay:, tone:, level:, metal: nil)
            m = metal || TR808.metal(tune)
            low = m.filter(:bandpass, cutoff: 3440, quality: 1.5) * Drums.decay_env(t, decay) * (1.0 - 0.7 * tone)
            high = m.filter(:bandpass, cutoff: 7100, quality: 1.2) * Drums.decay_env(t, decay * 0.5) * (0.4 + tone)
            (Drums.mix(low, high) * (2.5 * level)).named('808 cymbal')
          end

          # Two squares (540 and 800 Hz) through a bandpass (+tone+ moves it
          # around 2.64 kHz), with a fast drop into a +decay+ tail.
          def cowbell(t, tune:, decay:, tone:, level:)
            f = Drums.hz(tune)
            squares = TR808.metal(f, freqs: [540.0, 800.0])
            env = Drums.mix(Drums.decay_env(t, 0.02) * 0.6, Drums.decay_env(t, decay) * 0.4)
            band = squares.filter(:bandpass, cutoff: Drums.exp2(tone - 0.5) * (f * (2640 / 540.0)), quality: 1.5)
            (band * env * (2.2 * level)).named('808 cowbell')
          end

          # A tuned ping whose pitch drops (+tone+: 0 none, 1 50%) over 50
          # ms, plus a breath of bandpassed noise (+snappy+).
          def tom(t, tune:, decay:, tone:, snappy:, level:, name: 'tom')
            f = Drums.hz(tune)
            drop = Drums.decay_env(t, 0.05, velocity: false) * (0.5 * tone) + 1
            body = t.ping(drop * f, decay: decay)
            parts = [body]
            if !snappy.is_a?(Numeric) || snappy > 0
              parts << S.noise.filter(:bandpass, cutoff: f * 6, quality: 1.0) * Drums.decay_env(t, decay * 0.08) * snappy
            end
            (Drums.mix(*parts) * level).named("808 #{name}")
          end

          def low_tom(t, **k) = tom(t, **k, name: 'low tom')
          def mid_tom(t, **k) = tom(t, **k, name: 'mid tom')
          def high_tom(t, **k) = tom(t, **k, name: 'high tom')

          # Congas: toms without the noise.
          def conga(t, tune:, decay:, tone:, level:, name: 'conga')
            tom(t, tune: tune, decay: decay, tone: tone, snappy: 0, level: level, name: name)
          end

          def low_conga(t, **k) = conga(t, **k, name: 'low conga')
          def mid_conga(t, **k) = conga(t, **k, name: 'mid conga')
          def high_conga(t, **k) = conga(t, **k, name: 'high conga')

          # A high, short ping (+tone+ adds a slight pitch drop).
          def claves(t, tune:, decay:, tone:, level:)
            drop = Drums.decay_env(t, 0.01, velocity: false) * (0.1 * tone) + 1
            (t.ping(drop * Drums.hz(tune), decay: decay) * level).named('808 claves')
          end

          # A short burst of highpassed noise (+tone+ moves the highpass).
          def maracas(t, decay:, tone:, level:)
            noise = S.noise.filter(:highpass, cutoff: Drums.exp2(tone - 0.5) * 5000, quality: 0.7)
            env = S.adsr(0.002, decay, 0.0, 0.001, trigger: t, velocity: t, curve: [0, 40, 40], hold: false)
            (noise * env * (1.05 * level)).named('808 maracas')
          end
        end
      end
    end
  end
end

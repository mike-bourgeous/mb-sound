module MB
  module Sound
    # Mastering presets: named master chains with a loudness target
    # (mastering-1, 2026-10-17).  `master :club` (console and
    # Session#master), `mix.master(:club)` in any graph, `masters` to list
    # them.  A Preset is a frozen value: its chain steps (built from the
    # library's own nodes: mono_below, compress, bands, softclip, limit,
    # filters), its Loudness::Target, true-peak ceiling, the default drive
    # into the chain, notes, and sources.
    #
    # Every chain has one gain stage, the trim, after the level-independent
    # stages (mono low end, subsonic highpass) and before everything that
    # reacts to level (glue compression, de-essing, clipping, limiting).
    # The trim is where loudness targets are reached:
    # - renders measure, then set it exactly (two passes; see
    #   Mastering::Targeting and PlaybackMethods#render), so a render lands
    #   on the target at any buffer size;
    # - live, it is the preset's +drive+ (which assumes a mix arriving at
    #   ASSUMED_INPUT_LUFS), or with +ride: true+ a slow rider
    #   (GraphNode::Rider) that moves it toward the target from short-term
    #   loudness, holding through silence and breakdowns.
    #
    #     master :club                         # loud, low crest, -0.5 dBTP
    #     master :streaming, platform: :apple  # -16 LUFS, -1 dBTP
    #     master :quiet, lufs: :ebu_r128       # broadcast: -23 LUFS
    #     master :vinyl                        # mono lows, de-essed, no brickwall
    #     master(:club, ride: true) { |mix| mix.filter(:highpass, cutoff: knob(:air)) }
    #     render 'song.flac', bars: 64 { master :club; my_song }   # lands on -8.5 LUFS
    module Mastering
      # The loudness a live chain's default drive assumes the mix arrives at
      # (LUFS): about where full-scale parts land at the default -10 dB
      # master gain (measured on the bin/songs renders, mastering-1).
      ASSUMED_INPUT_LUFS = -20.0

      # A mastering preset (see Mastering).  +name+ (a Symbol), +title+,
      # +steps+ (an Array of [method, args, kwargs], applied in order to the
      # mix; [:trim, [], {}] is the gain stage, [:de_ess, [frequency],
      # kwargs] a split-band de-esser, [:highpass, [cutoff], {}] a
      # subsonic filter, anything else a GraphNode method), +target+ (a
      # Loudness::Target), +ceiling+ (the true-peak ceiling, Decibels),
      # +limiter+ (true if the chain ends in a brickwall limiter; without
      # one, renders keep the true peak under the ceiling by lowering the
      # trim), +drive+ (the live trim, Decibels), +fixed+ (true when
      # +drive+ was given: renders keep it instead of measuring), +ride+
      # (nil, or the rider's settings), +options+ (the options it was made
      # with, for printing), +notes+, and +source+.
      Preset = Data.define(:name, :title, :steps, :target, :ceiling, :limiter, :drive, :fixed, :ride, :options, :notes, :source) do
        # Applies the chain to +mix+ (a node or bundle), with +trim+ (a gain,
        # Decibels or linear) instead of the preset's drive if given.
        # Returns a node (one channel) or a bundle.
        def apply(mix, trim: nil)
          gain = trim || drive
          steps.reduce(mix) { |m, (method, args, kwargs)|
            case method
            when :trim
              if ride
                m.ride(target.lufs, start: gain, **ride)
              else
                m * gain
              end
            when :de_ess
              m.bands(*args) { |lo, hi| [lo, hi.compress(**kwargs)] }
            when :highpass
              m.filter(:highpass, cutoff: args[0], quality: kwargs.fetch(:quality, 0.7071))
            else
              m.public_send(method, *args, **kwargs)
            end
          }
        end

        # True if renders measure and set the trim (not with a fixed
        # +drive+ or a rider).
        def targeted?
          !fixed && !ride
        end

        # The call that makes this preset, e.g. `:club` or
        # `:club, lufs: -8` (for #to_ruby and set documents).
        def call_ruby
          [name.inspect, *options.map { |k, v| "#{k}: #{Mastering.ruby(v)}" }].join(', ')
        end

        # `Mastering.preset(:club, lufs: -8)`, which makes this preset again.
        def to_ruby
          "Mastering.preset(#{call_ruby})"
        end

        # A one-line summary, e.g. "club: -8.5 LUFS, -0.5 dBTP, mono_below
        # 120 -> trim -> compress -> softclip -> limit".
        def summary
          tp = format('%.1f dBTP', ceiling.db_value)
          chain = steps.map(&:first).join(' -> ')
          drive_text = fixed ? ", drive #{format('%+.1f', drive.db_value)} dB" : ''
          "#{name}: #{format('%.1f', target.lufs)} LUFS, #{tp}#{limiter ? '' : ' (no limiter)'}#{drive_text}#{ride ? ', riding' : ''}; #{chain}"
        end

        def to_s
          summary
        end

        def inspect
          "#<Mastering::Preset #{summary}>"
        end
      end

      # What each preset is for, its defaults, and the reasons for its
      # chain (see design/notes/master_effects.md, "Mastering presets").
      DEFINITIONS = {
        club: {
          title: 'Club: loud, low crest, mono lows',
          defaults: { lufs: -8.5, ceiling: -0.5.db, mono: 120, glue: true, clip: true },
          notes: 'Dance music for club systems: mono below 120 Hz, gentle glue (2:1 RMS), a soft clipper that only rounds ' \
                 'the highest peaks, then a true-peak limiter at -0.5 dBTP; about -8 to -9 LUFS integrated.  ' \
                 '"Less clipping, more limiting" (maintainer, 2026-10-13): clip: false leaves the peaks to the limiter.',
          source: 'Maintainer picks 2026-10-13/17 (low crest, near max true peak, -0.5 dBTP shares); genre templates dnb/house/techno; ' \
                  'Giannoulis et al. 2012 (compressor design); BS.1770-4 Annex 2 (true peak)',
        },
        streaming: {
          title: 'Streaming: platform loudness, -1 dBTP',
          defaults: { lufs: :spotify, mono: false, glue: true },
          notes: 'Reaches a streaming platform\'s normalization level (Loudness::TARGETS: :spotify -14, :youtube -14, ' \
                 ':apple_music -16, :amazon_music -14, :soundcloud -14, ...) with gentle glue (1.5:1 RMS) and a true-peak ' \
                 'limiter at the platform\'s ceiling.  Lossy encoders add inter-sample peaks: renders report decoded ' \
                 'MP3/AAC true peaks (MixReport, Mastering.codec_peaks).',
          source: 'Loudness::TARGETS (Spotify for Artists, read 2026-10-07; others reported, unverified); AES TD1008 ' \
                  '(streaming loudness recommendation, -1 dBTP for lossy encodes; from memory)',
        },
        quiet: {
          title: 'Quiet: wide dynamics, light limiting',
          defaults: { lufs: -18.0, mono: false, glue: false },
          notes: 'Ambient, film, and headphone listening: no compression, a slow-release true-peak limiter at -1 dBTP as a ' \
                 'safety; -18 LUFS by default, lufs: :ebu_r128 (-23) or :atsc_a85 (-24) for broadcast.',
          source: 'EBU R 128-2023 (-23 LUFS, -1 dBTP); ATSC A/85:2026 (-24 LKFS, -2 dBTP); genre :ambient (-19..-16)',
        },
        vinyl: {
          title: 'Vinyl: mono lows, tamed highs, no brickwall',
          defaults: { lufs: -13.0, ceiling: -3.db, mono: 150, glue: true, de_ess: 5500 },
          notes: 'For a cutting engineer: mono below 150 Hz and a 25 Hz highpass (lateral bass is fine, vertical bass ' \
                 'throws the stylus), gentle glue, and a split-band de-esser above 5.5 kHz, since the RIAA pre-emphasis ' \
                 'boosts the treble by up to about 20 dB at 20 kHz while cutting (sibilance and hats limit the level a cut ' \
                 'can take).  No brickwall limiter: the cutting engineer sets the level, so peaks stay under -3 dBTP by ' \
                 'trim alone (renders lower the trim instead of limiting).',
          source: 'RIAA equalization curve (IEC 60098); genre :jungle (mono below 150 Hz for vinyl); common cutting-room ' \
                  'advice (mono lows, controlled sibilance, headroom), from memory',
        },
      }.freeze

      # Options every preset takes (see .preset).
      OPTIONS = %i[lufs platform ceiling drive ride mono glue clip de_ess].freeze

      # Rider settings for `ride: true` (see GraphNode::Rider; +range+ and
      # times as there).
      RIDE_DEFAULTS = { range: 9.db, down: 3.0, up: 10.0, gate: 10.0 }.freeze

      class << self
        # The preset names.
        def names
          DEFINITIONS.keys
        end

        # True if +name+ names a preset (a Symbol or String).
        def preset?(name)
          (name.is_a?(Symbol) || name.is_a?(String)) && DEFINITIONS.key?(name.to_sym)
        end

        # Every preset at its defaults, by name.
        def presets
          names.to_h { |n| [n, preset(n)] }
        end

        # A Preset: +name+ (:club, :streaming, :quiet, :vinyl, or a Preset,
        # which +options+ then change) with +options+:
        # - +lufs:+ the integrated loudness target: LUFS, a Loudness::TARGETS
        #   name (:spotify, :ebu_r128, ...), or a Loudness::Target;
        # - +platform:+ (the same as +lufs:+ with a name; for :streaming);
        # - +ceiling:+ the true-peak ceiling (`-1.db`; default from the
        #   target or the preset);
        # - +drive:+ a fixed trim (`9.db`): renders keep it instead of
        #   measuring;
        # - +ride:+ true (or a Hash of GraphNode::Rider settings) rides the
        #   trim toward the target live;
        # - +mono:+ Hz below which the low end is mono, or false;
        # - +glue:+ false to skip the glue compressor;
        # - +clip:+ (:club) false to skip the soft clipper;
        # - +de_ess:+ (:vinyl) the de-esser's crossover (Hz), or false.
        def preset(name, **options)
          if name.is_a?(Preset)
            return name if options.empty?
            options = name.options.merge(options)
            name = name.name
          end
          key = name.respond_to?(:to_sym) ? name.to_sym : name
          definition = DEFINITIONS[key]
          unless definition
            raise ArgumentError, "Unknown mastering preset #{name.inspect}#{Form.suggest(key, names)} (presets: #{names.map(&:inspect).join(', ')})"
          end
          unknown = options.keys - OPTIONS
          unless unknown.empty?
            raise ArgumentError, "Unknown option#{unknown.length > 1 ? 's' : ''} #{unknown.map(&:inspect).join(', ')} for master #{key.inspect}#{Form.suggest(unknown[0], OPTIONS)}"
          end
          if options.key?(:platform) && options.key?(:lufs)
            raise ArgumentError, 'Pass lufs: or platform:, not both'
          end

          o = definition[:defaults].merge(options)
          o[:lufs] = o.delete(:platform) if o.key?(:platform)
          target = target_of(o[:lufs])
          # An explicit ceiling, else the preset's own (club, vinyl), else
          # the target's (platforms, broadcast)
          ceiling = options.fetch(:ceiling) { definition[:defaults][:ceiling] || (target.true_peak || Loudness::DEFAULT_TRUE_PEAK).db }
          ceiling = Decibels.new(Decibels.db_of(ceiling, 'ceiling')) unless ceiling.is_a?(Decibels)
          raise ArgumentError, "ceiling: must be at most 0 dBTP (got #{ceiling.inspect})" if ceiling.db_value > 0

          fixed = options.key?(:drive)
          drive = fixed ? o[:drive] : (target.lufs - ASSUMED_INPUT_LUFS).db
          drive = Decibels.new(Decibels.db_of(drive, 'drive')) unless drive.is_a?(Decibels)

          ride = o[:ride]
          ride = case ride
                 when nil, false then nil
                 when true then RIDE_DEFAULTS
                 when Hash
                   bad = ride.keys - RIDE_DEFAULTS.keys
                   raise ArgumentError, "Unknown ride: settings #{bad.map(&:inspect).join(', ')} (use #{RIDE_DEFAULTS.keys.join(', ')})" unless bad.empty?
                   RIDE_DEFAULTS.merge(ride).freeze
                 else
                   raise ArgumentError, "ride: is true, false, or a Hash of rider settings (got #{ride.inspect})"
                 end

          steps = send(:"#{key}_steps", o, target, ceiling).map { |m, a, k| [m, a.freeze, k.freeze].freeze }.freeze
          Preset.new(
            name: key, title: definition[:title], steps: steps, target: target, ceiling: ceiling,
            limiter: steps.any? { |s| s[0] == :limit }, drive: drive, fixed: fixed, ride: ride,
            options: options.dup.freeze, notes: definition[:notes], source: definition[:source]
          )
        end

        # Runs the block (building a master chain) with +trim+ (a linear gain
        # or nil) as the trim of targeted presets built in it (a render's
        # measured gain; see Targeting), collecting the presets built.
        # Returns [block value, presets].
        def building(trim: nil)
          old = Thread.current[:mb_sound_mastering]
          state = { trim: trim, built: [] }
          Thread.current[:mb_sound_mastering] = state
          [yield, state[:built]]
        ensure
          Thread.current[:mb_sound_mastering] = old
        end

        # The trim for targeted presets in the chain being built (see
        # .building), or nil for their drive.
        def render_trim
          Thread.current[:mb_sound_mastering]&.dig(:trim)
        end

        # Records a preset built into the chain being built (see .building).
        def note_built(preset)
          Thread.current[:mb_sound_mastering]&.dig(:built)&.push(preset)
        end

        # The Loudness::Target for a +lufs:+ value.
        def target_of(value)
          case value
          when Loudness::Target then value
          when Numeric, Symbol, String then Loudness.target(value.is_a?(Numeric) ? value.to_f : value)
          else
            raise ArgumentError, "lufs: is a number of LUFS or a Loudness::TARGETS name (got #{value.inspect})"
          end
        end

        # Ruby text for an option value.
        def ruby(value)
          case value
          when Decibels then value.inspect
          when Loudness::Target then value.key ? value.key.inspect : format('%g', value.lufs)
          when Hash then "{ #{value.map { |k, v| "#{k}: #{ruby(v)}" }.join(', ')} }"
          else value.inspect
          end
        end

        private

        def mono_steps(o)
          o[:mono] ? [[:mono_below, [o[:mono]], {}]] : []
        end

        # Glue: a gentle RMS compressor whose threshold sits +over+ dB above
        # the target loudness (after the trim the mix arrives near the
        # target, so the gain reduction is about the same for every song).
        def glue_step(target, over:, ratio:, attack:, release:)
          [:compress, [], { threshold: (target.lufs + over).db, ratio: ratio, knee: 6, attack: attack, release: release, detector: :rms }]
        end

        def club_steps(o, target, ceiling)
          steps = mono_steps(o)
          steps << [:trim, [], {}]
          steps << glue_step(target, over: 3, ratio: 2, attack: 0.01, release: 0.15) if o[:glue]
          steps << [:softclip, [0.8, 1.0], {}] if o[:clip]
          steps << [:limit, [], { ceiling: ceiling, release: 0.08 }]
        end

        def streaming_steps(o, target, ceiling)
          steps = mono_steps(o)
          steps << [:trim, [], {}]
          steps << glue_step(target, over: 5, ratio: 1.5, attack: 0.02, release: 0.25) if o[:glue]
          steps << [:limit, [], { ceiling: ceiling, release: 0.15 }]
        end

        def quiet_steps(o, target, ceiling)
          steps = mono_steps(o)
          steps << [:trim, [], {}]
          steps << glue_step(target, over: 6, ratio: 1.3, attack: 0.03, release: 0.3) if o[:glue]
          steps << [:limit, [], { ceiling: ceiling, release: 0.25 }]
        end

        def vinyl_steps(o, target, ceiling)
          steps = mono_steps(o)
          steps << [:highpass, [25], {}]
          steps << [:trim, [], {}]
          steps << glue_step(target, over: 5, ratio: 1.5, attack: 0.03, release: 0.3) if o[:glue]
          if o[:de_ess]
            steps << [:de_ess, [o[:de_ess]], { threshold: (target.lufs - 8).db, ratio: 4, knee: 6, attack: 0.001, release: 0.06 }]
          end
          steps
        end
      end
    end
  end
end

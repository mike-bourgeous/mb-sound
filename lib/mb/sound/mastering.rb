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
        # Returns a node (one channel) or a bundle.  +tap+ (a callable)
        # gets the signal entering the trim and returns what the trim reads
        # (a render's first pass records it there; see Targeting).
        # +from_trim+ applies only the trim and the steps after it (to the
        # signal entering the trim).
        #
        # +trim+ may be a Targeting::TrimCurve (measure: :sections), read
        # at +session+'s frame.
        def apply(mix, trim: nil, tap: nil, from_trim: false, session: nil)
          gain = trim || drive
          list = from_trim ? steps.drop_while { |st| st[0] != :trim } : steps
          list.reduce(mix) { |m, (method, args, kwargs)|
            case method
            when :trim
              m = tap.call(m) if tap
              if gain.is_a?(Targeting::TrimCurve)
                gain.apply(m, session: session || Session.current)
              elsif ride
                m.ride(target.lufs, start: gain, **ride)
              else
                m * gain
              end
            when :de_ess
              m.bands(*args) { |lo, hi| [lo, hi.compress(**kwargs)] }
            when :dynamic_air
              # Dynamic EQ: the band above args[0] is turned down only
              # while the whole mix (the sidechain) is near the limiters,
              # looking ahead; the rest waits as long, so the bands line up
              m.bands(*args) { |lo, hi|
                cut = hi.compress(sidechain: m, **kwargs)
                [lo.delay(GraphNode::BlendMethods.latency_of(cut, hi).samples), cut]
              }
            when :air_band
              # Multiband: the band above args[0] compressed on its own level
              m.bands(*args) { |lo, hi|
                cut = hi.compress(**kwargs)
                [lo.delay(GraphNode::BlendMethods.latency_of(cut, hi).samples), cut]
              }
            when :highpass
              m.filter(:highpass, cutoff: args[0], quality: kwargs.fetch(:quality, 0.7071))
            else
              m.public_send(method, *args, **kwargs)
            end
          }
        end

        # What a render's target measures: :integrated (the default) or
        # :loudest (see MEASURES).
        def measure
          options.fetch(:measure) { Mastering.preset_settings(name).dig(:defaults, :measure) || :integrated }
        end

        # The window of +measure: :loudest+ in bars (LOUDEST_BARS unless
        # given).
        def loudest_bars
          options[:loudest_bars] || LOUDEST_BARS
        end

        # The share of bars at or under the level +measure: :bars+ targets
        # (BARS_PERCENTILE unless given).
        def percentile
          options.fetch(:percentile) { Mastering.preset_settings(name).dig(:defaults, :percentile) || BARS_PERCENTILE }
        end

        # The share of the mix's section-to-section loudness differences
        # +measure: :sections+ keeps (SECTION_ENERGY unless given).
        def energy
          options.fetch(:energy) { Mastering.preset_settings(name).dig(:defaults, :energy) || SECTION_ENERGY }.to_f
        end

        # Words for what renders measure ("loudest 16 bars", "bars at the
        # 25th percentile"), or nil for :integrated.
        def measure_text
          case measure
          when :loudest then "loudest #{loudest_bars} bars"
          when :bars then "bars at the #{Mastering.ordinal((percentile * 100).round)} percentile"
          when :sections then "each section, energy #{energy}"
          end
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

        # `Mastering.from_preset(:club, lufs: -8)`, which makes this preset
        # again.
        def to_ruby
          "Mastering.from_preset(#{call_ruby})"
        end

        # A one-line summary, e.g. "club: -8.5 LUFS, -0.5 dBTP, mono_below
        # 120 -> trim -> compress -> softclip -> limit".
        def summary
          tp = format('%.1f dBTP', ceiling.db_value)
          chain = steps.map(&:first).join(' -> ')
          drive_text = fixed ? ", drive #{format('%+.1f', drive.db_value)} dB" : ''
          "#{name}: #{format('%.1f', target.lufs)} LUFS#{measure_text ? " (#{measure_text})" : ''}, #{tp}#{limiter ? '' : ' (no limiter)'}#{drive_text}#{ride ? ', riding' : ''}; #{chain}"
        end

        def to_s
          summary
        end

        def inspect
          "#<Mastering::Preset #{summary}>"
        end
      end

      # What each preset is for (about:), its defaults, and the reasons for
      # its chain (see design/notes/master_effects.md, "Mastering presets"):
      # the :mastering family (Presettable).  Each builtin preset's chain is
      # built by its own steps method; a library file's preset takes the
      # chain of another with +like:+ (`mastering :loud_club, like: :club,
      # defaults: { lufs: -7.5 }, about: '...'`).
      extend MB::Sound::Presettable
      preset_family :mastering, kind: :master, label: 'mastering preset', keys: %i[defaults notes source like],
        about: 'Mastering presets: master :club, mix.master(:streaming, platform: :apple)',
        apply: ->(name, mix = nil, **options) { mix ? mix.master(name, **options) : Mastering.from_preset(name, **options) },
        code: ->(e) { "master #{e.name.inspect}" }

      preset :club, about: 'Club: loud, low crest, mono lows', tags: %i[loud dance],
        defaults: { lufs: -8.5, ceiling: -0.5.db, mono: 120, glue: true, clip: false, air: :static, measure: :loudest },
        notes: 'Dance music for club systems: mono below 120 Hz, gentle glue (2:1 RMS, 3 dB over the target), the top ' \
               'octave above 18 kHz rolled off (lossy encoders cut it anyway, and their decoded peaks grow less; air: :dynamic, :band, false), a fast ' \
               'limiter 2 dB over the ceiling for transients, then a true-peak limiter at -0.5 dBTP; -8.5 LUFS ' \
               'integrated.  "Less clipping, more limiting" (maintainer, 2026-10-13; mastering-2 Bench: the two limiters ' \
               'for dnb and techno); clip: true puts a gentle softclip(0.9, 1.4) in place of the fast limiter.  At ' \
               '-0.5 dBTP decoded MP3/AAC peaks can still pass 0 dBTP on dense masters (reports say so).',
        source: 'Maintainer picks 2026-10-13/17 (low crest, near max true peak, -0.5 dBTP shares); genre templates dnb/house/techno; ' \
                'Giannoulis et al. 2012 (compressor design); BS.1770-4 Annex 2 (true peak)'
      preset :streaming, about: 'Streaming: platform loudness, -1 dBTP', tags: %i[platform],
        defaults: { lufs: :spotify, mono: false, glue: true },
        notes: 'Reaches a streaming platform\'s normalization level (Loudness::TARGETS: :spotify -14, :youtube -14, ' \
               ':apple_music -16, :amazon_music -14, :soundcloud -14, ...) with gentle glue (1.5:1 RMS) and a true-peak ' \
               'limiter at the platform\'s ceiling.  Lossy encoders add inter-sample peaks: renders report decoded ' \
               'MP3/AAC true peaks (MixReport, Mastering.codec_peaks).',
        source: 'Loudness::TARGETS (Spotify for Artists, read 2026-10-07; others reported, unverified); AES TD1008 ' \
                '(streaming loudness recommendation, -1 dBTP for lossy encodes; from memory)'
      preset :quiet, about: 'Quiet: wide dynamics, light limiting', tags: %i[dynamic broadcast],
        defaults: { lufs: -18.0, mono: false, glue: false },
        notes: 'Ambient, film, and headphone listening: no compression, a slow-release true-peak limiter at -1 dBTP as a ' \
               'safety; -18 LUFS by default, lufs: :ebu_r128 (-23) or :atsc_a85 (-24) for broadcast.',
        source: 'EBU R 128-2023 (-23 LUFS, -1 dBTP); ATSC A/85:2026 (-24 LKFS, -2 dBTP); genre :ambient (-19..-16)'
      preset :vinyl, about: 'Vinyl: mono lows, tamed highs, no brickwall', tags: %i[analog],
        defaults: { lufs: -14.0, ceiling: -1.db, mono: 150, glue: true, de_ess: 7000, clip: true },
        notes: 'For a cutting engineer: mono below 150 Hz and a 25 Hz highpass (lateral bass is fine, vertical bass ' \
               'throws the stylus), gentle glue, and a split-band de-esser above 7 kHz (3:1, only on the loudest sibilance), since the RIAA pre-emphasis ' \
               'boosts the treble by up to about 20 dB at 20 kHz while cutting (sibilance and hats limit the level a cut ' \
               'can take).  No brickwall limiter: the cutting engineer sets the level, so peaks stay under -1 dBTP by ' \
               'trim alone (renders lower the trim instead of limiting; peaky mixes land under the -14 LUFS target).  ' \
               'A soft clipper last rounds the peaks off (its limit 0.5 dB under the ceiling, the knee 6 dB under that), so ' \
               'a 909 kick or a break reaches the target ("vinyl that clips first", on by default since 2026-10-22; ' \
               'clip: false for trim alone).',
        source: 'RIAA equalization curve (IEC 60098); genre :jungle (mono below 150 Hz for vinyl); common cutting-room ' \
                'advice (mono lows, controlled sibilance, headroom), from memory'
      preset :hot, about: 'Hot: glue, then drive into a clipper and a true-peak limiter', tags: %i[loud clipped],
        defaults: { lufs: -8.5, ceiling: -0.5.db, mono: false, glue: true, measure: :bars },
        notes: 'Kez Volta\'s drum & bass master from "Tunnel Vision" (bin/synths/dnb.rb dnb_master) as a preset: ' \
               'a 2:1 glue compressor at -14 dBFS on the mix as it arrives (before the trim, as Kez had it), the trim ' \
               '(Kez drove 11 dB), a hard softclip(0.6, 1.0), and a true-peak limiter at -0.5 dBTP (60 ms release).  ' \
               'Louder and brighter drops than :club, with audible clipping on dense parts.  Renders measure ' \
               'the bars\' loudness distribution by default (measure: :bars, the quieter quarter of the bars at ' \
               'the target), so the clipper closes the gap between drops and breakdowns.  `drive: 11.db` is Kez\'s ' \
               'render exactly.',
        source: 'Kez Volta, persona panel 2026-10-13 (research-persona-edm); maintainer\'s omnibus9 Bench pick ' \
                '(2026-10-18: "I like the direction but now the breakdown is too quiet")'

      # Options of .from_preset: every preset takes COMMON_OPTIONS, and some
      # their own (PRESET_OPTIONS); an option a preset would ignore raises
      # (decks-1, 2026-10-22; Nev's N14: `master(:vinyl, clip: true)` was
      # accepted and did nothing).
      COMMON_OPTIONS = %i[lufs platform ceiling drive ride mono glue measure loudest_bars percentile energy].freeze
      PRESET_OPTIONS = { club: %i[clip air], vinyl: %i[clip de_ess] }.freeze
      OPTIONS = (COMMON_OPTIONS + PRESET_OPTIONS.values.flatten).uniq.freeze

      # What a render's target measures (+measure:+): the song's integrated
      # loudness, or that of its loudest +loudest_bars:+ bars (windows
      # starting on bar lines; see Mastering::Targeting), so quieter
      # sections keep their distance from the drops instead of coming up
      # to fill the integrated target.  :club measures :loudest (the
      # maintainer's decision, 2026-10-18).
      #
      # :bars (bench-fixes-1, 2026-10-18; interim, see
      # design/notes/master_effects.md) reads the distribution of the
      # bars' loudness: each bar's gated loudness, the bars within
      # BARS_RANGE LU of the loudest one (not silence or tails), and the
      # level +percentile:+ of them sit at or under (0.25: the quieter
      # quarter, breakdowns and intros).  Targeting that level raises the
      # trim until the quiet sections reach it; on a chain that clips and
      # limits, the drops then gain less than the breakdown, so the spread
      # between them closes (Tunnel Vision on :hot: the breakdown 1.8 LU
      # under the drops instead of 3.0).
      #
      # :sections (decks-1, 2026-10-22; panel round 2 K22, the maintainer's
      # Tunnel Vision notes): each pass of the song form's sections gets its
      # own trim, ramped at section starts (Targeting.solve_sections): the
      # loudest section reaches the target, and every other one the target
      # plus +energy:+ (0..1, default 1) times its distance under the
      # loudest in the mix, so energy 1 keeps the mix's curve (quieter
      # sections come up by trim, never by the clipper) and less narrows it
      # (0.4: a breakdown 6 LU under the drop in the mix lands 2.4 LU under).
      MEASURES = %i[integrated loudest bars sections].freeze

      # The default +energy:+ of +measure: :sections+.
      SECTION_ENERGY = 1.0

      # :vinyl's clip: true: the clipper's limit sits this many dB under
      # the ceiling (true peaks between samples), and its knee starts at
      # this share of the limit (-6 dB).
      VINYL_CLIP_MARGIN = 0.5
      VINYL_CLIP_KNEE = 0.5

      # The default +percentile:+ of +measure: :bars+.
      BARS_PERCENTILE = 0.25

      # Bars more than this many LU under the loudest bar don't count for
      # +measure: :bars+ (silence, tails, a lone fading hat).
      BARS_RANGE = 20.0

      # The default window (bars) of +measure: :loudest+ (genre templates
      # set their own from their phrase lengths: Genre::Mix#loudest_bars).
      LOUDEST_BARS = 16

      # Rider settings for `ride: true` (see GraphNode::Rider; +range+ and
      # times as there).
      RIDE_DEFAULTS = { range: 9.db, down: 3.0, up: 10.0, gate: 10.0 }.freeze

      class << self
        # The preset names.
        def names
          preset_names
        end

        # Every preset built at its defaults (Preset values), by name.
        def built_presets
          names.to_h { |n| [n, from_preset(n)] }
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
        # - +clip:+ (:club) true for a gentle soft clipper in place of the
        #   fast limiter; (:vinyl, true by default) a soft clipper after the trim,
        #   so peaky mixes reach the target with their peaks rounded off (false
        #   for trim alone);
        # - +de_ess:+ (:vinyl) the de-esser's crossover (Hz), or false;
        # - +measure:+ :loudest to reach the target with the loudest
        #   +loudest_bars:+ bars (LOUDEST_BARS by default; windows on bar
        #   lines) rather than the whole song (renders; see MEASURES), or
        #   :integrated (the default except for :club), or :bars to reach it
        #   with the level +percentile:+ of the bars sit at or under (see
        #   MEASURES);
        # - +loudest_bars:+ the window of measure: :loudest, in bars;
        # - +percentile:+ (0..1) the share of measure: :bars;
        # - +energy:+ (0..1) the share of the mix's section-to-section
        #   loudness differences measure: :sections keeps (default 1).
        def from_preset(name, **options)
          if name.is_a?(Preset)
            return name if options.empty?
            options = name.options.merge(options)
            name = name.name
          end
          key = name.respond_to?(:to_sym) ? name.to_sym : name
          entry = preset_entry(key)
          key = entry.name
          definition = entry.settings
          defaults = definition[:defaults] || {}
          chain = definition[:like] || key
          accepted = COMMON_OPTIONS + PRESET_OPTIONS.fetch(chain, [])
          unknown = options.keys - OPTIONS
          unless unknown.empty?
            raise ArgumentError, "Unknown option#{unknown.length > 1 ? 's' : ''} #{unknown.map(&:inspect).join(', ')} for master #{key.inspect} (options: #{accepted.join(', ')})#{Form.suggest(unknown[0], accepted)}"
          end
          ignored = options.keys - accepted
          unless ignored.empty?
            owners = ignored.map { |o| "#{o}: (an option of #{PRESET_OPTIONS.select { |_, v| v.include?(o) }.keys.map(&:inspect).join(' and ')})" }
            raise ArgumentError, "master #{key.inspect} would ignore #{owners.join(', ')} (its options: #{accepted.join(', ')})"
          end
          if options.key?(:platform) && options.key?(:lufs)
            raise ArgumentError, 'Pass lufs: or platform:, not both'
          end
          if options.key?(:measure) && !MEASURES.include?(options[:measure])
            raise ArgumentError, "measure: is #{MEASURES.map(&:inspect).join(' or ')} (got #{options[:measure].inspect})"
          end
          if options.key?(:loudest_bars) && !(options[:loudest_bars].is_a?(Integer) && options[:loudest_bars] > 0)
            raise ArgumentError, "loudest_bars: is a number of bars, a positive Integer (got #{options[:loudest_bars].inspect})"
          end
          if options.key?(:percentile) && !(options[:percentile].is_a?(Numeric) && options[:percentile] >= 0 && options[:percentile] <= 1)
            raise ArgumentError, "percentile: is a share of bars from 0 to 1, e.g. 0.25 (got #{options[:percentile].inspect})"
          end
          measure = options.fetch(:measure) { defaults[:measure] || :integrated }
          if options.key?(:loudest_bars) && measure != :loudest
            raise ArgumentError, "loudest_bars: goes with measure: :loudest (master #{key.inspect} measures #{measure.inspect}); it would do nothing"
          end
          if options.key?(:percentile) && measure != :bars
            raise ArgumentError, "percentile: goes with measure: :bars (master #{key.inspect} measures #{measure.inspect}); it would do nothing"
          end
          if options.key?(:energy)
            unless options[:energy].is_a?(Numeric) && options[:energy] >= 0 && options[:energy] <= 1
              raise ArgumentError, "energy: is the share of the mix's section-to-section loudness kept, 0 to 1 (got #{options[:energy].inspect})"
            end
            raise ArgumentError, "energy: goes with measure: :sections (master #{key.inspect} measures #{measure.inspect}); it would do nothing" if measure != :sections
          end

          o = defaults.merge(options)
          o[:lufs] = o.delete(:platform) if o.key?(:platform)
          target = target_of(o[:lufs])
          # An explicit ceiling, else the preset's own (club, vinyl), else
          # the target's (platforms, broadcast)
          ceiling = options.fetch(:ceiling) { defaults[:ceiling] || (target.true_peak || Loudness::DEFAULT_TRUE_PEAK).db }
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

          steps = send(:"#{chain}_steps", o, target, ceiling).map { |m, a, k| [m, a.freeze, k.freeze].freeze }.freeze
          Preset.new(
            name: key, title: entry.about, steps: steps, target: target, ceiling: ceiling,
            limiter: steps.any? { |s| s[0] == :limit }, drive: drive, fixed: fixed, ride: ride,
            options: options.dup.freeze, notes: definition[:notes], source: definition[:source]
          )
        end

        # Runs the block (building a master chain) with +trim+ (a linear gain
        # or nil) as the trim of targeted presets built in it (a render's
        # measured gain; see Targeting), collecting the presets built.
        # Returns [block value, presets].
        #
        # With +capture+, every preset records the signal entering its trim
        # (Targeting::Tap), and the presets come back as Built values.
        def building(trim: nil, capture: false)
          old = Thread.current[:mb_sound_mastering]
          state = { trim: trim, built: [], capture: capture }
          Thread.current[:mb_sound_mastering] = state
          value = yield
          [value, capture ? state[:built] : state[:built].map(&:preset)]
        ensure
          Thread.current[:mb_sound_mastering] = old
        end

        # A preset built while capturing (see .building): the Preset, the
        # Targeting::Tap recording the signal entering its trim, and the
        # bundle or node it returned.
        Built = Struct.new(:preset, :tap, :output)

        # Applies +preset+ to +mix+ for GraphNode#master in the chain being
        # built (see .building): the render's trim for targeted presets,
        # and a Targeting::Tap at the trim while capturing.  Returns the
        # result.
        def build(preset, mix)
          state = Thread.current[:mb_sound_mastering]
          trim = preset.targeted? ? state&.dig(:trim) : nil
          return (preset.apply(mix, trim: trim).tap { state&.dig(:built)&.push(Built.new(preset, nil, nil)) }) unless state&.dig(:capture)

          built = Built.new(preset, nil, nil)
          built.output = preset.apply(mix, trim: trim, tap: ->(m) { built.tap = Targeting::Tap.new(m.outputs) })
          state[:built] << built
          built.output
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
          when Loudness::Target then value.key ? value.key.inspect : format('%g', value.lufs)
          else RubyValue.text(value) { |v| ruby(v) } || value.inspect
          end
        end

        # "25th", "1st", "12th" for an Integer.
        def ordinal(n)
          suffix = (11..13).cover?(n % 100) ? 'th' : { 1 => 'st', 2 => 'nd', 3 => 'rd' }.fetch(n % 10, 'th')
          "#{n}#{suffix}"
        end

        private

        # Kez's chain (see the :hot preset): the glue reads the mix
        # before the trim, as in bin/synths/dnb.rb's dnb_master.
        def hot_steps(o, _target, ceiling)
          steps = mono_steps(o)
          steps << [:compress, [], { threshold: -14.db, ratio: 2, knee: 6, attack: 0.01, release: 0.12 }] if o[:glue]
          steps << [:trim, [], {}]
          steps << [:softclip, [0.6, 1.0], {}]
          steps << [:limit, [], { ceiling: ceiling, release: 0.06 }]
        end

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
          steps.concat(air_steps(o[:air]))
          # Peaks: two limiters (mastering-2 default): a fast one 2 dB
          # over the ceiling (1 ms lookahead, 20 ms release) takes the
          # transients, the final one (1.5 ms, 60 ms) the rest.  (Longer
          # lookaheads, 3 and 5 ms, took 0.06 dB more off the decoded
          # peaks for 1.8x the gain reduction and 3.6x the CPU.)  clip: true
          # puts a gentle softclip(0.9, 1.4) in front of the final limiter
          # instead of the fast one (house's feel).
          if o[:clip]
            steps << [:softclip, [0.9, 1.4], {}]
          else
            steps << [:limit, [], { ceiling: (ceiling.db_value + 2).db, lookahead: 0.001, release: 0.02 }]
          end
          steps << [:limit, [], { ceiling: ceiling, release: 0.06 }]
        end

        # The club's top-octave stage (+air:+): lossy encoders cut the top
        # octave, and their decoded peaks grow where they do; cutting it
        # here first keeps them nearer the ceiling.  :static (default) a
        # 4th-order Butterworth lowpass at 18 kHz; :dynamic the band above
        # 12 kHz turned down while the full mix is over the ceiling (20:1,
        # 1 ms lookahead like the limiters); :band the band above 12 kHz
        # compressed on its own level (3:1 over -18 dBFS); false none.
        # Measured (mastering-2, decoded 192k MP3 true peak, power above 12
        # kHz re the mix, Tunnel Vision at -7.6 LUFS / dnb at -8.5): none
        # +1.13 / +0.22 dBTP, -20.5 / -20.2 dB; :static +0.24 / -0.04,
        # -22.9 / -21.7; two gentle 17.5 kHz lowpasses +0.15 / +0.21,
        # -24.1 / -22.7; :dynamic +0.94 / +0.51, -22.7 / -21.1 (cut 3.5 dB
        # on average, 78% of the time); :band +0.32 / +0.24, -23.5 / -21.7.
        # The decoded overs come from the encoder's own lowpass, not from
        # air at the peaks, so only a static cut reaches them.
        def air_steps(air)
          case air
          when :static, true
            [[:filter, [:lowpass], { cutoff: 18000, quality: 0.5412 }], [:filter, [:lowpass], { cutoff: 18000, quality: 1.3066 }]]
          when :dynamic
            [[:dynamic_air, [12000], { threshold: -0.5.db, ratio: 20, knee: 2, attack: 0.0002, release: 0.02, lookahead: 0.001 }]]
          when :band
            [[:air_band, [12000], { threshold: -18.db, ratio: 3, knee: 6, attack: 0.0005, release: 0.03, lookahead: 0.001 }]]
          when false, nil
            []
          else
            raise ArgumentError, "air: is :static, :dynamic, :band, or false (got #{air.inspect})"
          end
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
            # (mastering-2: 7 kHz, 4 dB under the target, 3:1, 40 ms; the
            # first 5.5 kHz / -8 dB / 4:1 / 60 ms took 2.4 dB off the
            # treble's share of Memory Card, this 0.4 dB)
            steps << [:de_ess, [o[:de_ess]], { threshold: (target.lufs - 4).db, ratio: 3, knee: 6, attack: 0.001, release: 0.04 }]
          end
          # clip: true (decks-1, 2026-10-22; panel round 2 M9/N12: a 909
          # kick or a break held the trim at the ceiling, -18 LUFS for a
          # -14 target): a soft clipper last, its knee 6 dB under its limit
          # and the limit 0.5 dB under the ceiling (true peaks between
          # samples), so the trim can reach the target with the kick's
          # peaks rounded off instead of holding the whole cut down
          if o[:clip]
            limit = (ceiling.db_value - VINYL_CLIP_MARGIN).db.to_f
            steps << [:softclip, [limit * VINYL_CLIP_KNEE, limit], {}]
          end
          steps
        end
      end
    end
  end
end

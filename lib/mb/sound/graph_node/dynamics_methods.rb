module MB
  module Sound
    module GraphNode
      # DSL methods for dynamics: compressors, expanders, gates, ducking,
      # companders, the brickwall limiter, multiband splitting, and a
      # multiband upward/downward compressor (#squeeze).  See
      # design/notes/dynamics.md and GraphNode::Dynamics.
      #
      # Every method takes a single node or a bundle (stereo channels are
      # linked: one detector follows the louder channel, keeping the image)
      # and returns a node for one channel or a bundle for several.  They
      # handle channels themselves (ChannelDispatch::EXCLUDED).
      #
      # Units: every level and gain in dB is written with #db: levels
      # (+threshold+, +upward_threshold+, +ceiling+, +amount+, +range+),
      # gains (+makeup+, +min_gain+/+max_gain+, squeeze's +gain+), and
      # compander points (`compand(-60.db => -80.db, 0.db => -12.db)`).  A
      # Decibels value (`-12.db`) is read as exactly that many dB.  Bare
      # numbers are linear gains, as everywhere else (`threshold: 0.25` is
      # about -12 dB, `makeup: 2` +6 dB).  A negative bare number is a
      # mistake (it raises in scripts and specs; live mode reads it as dB
      # with a warning), and so is a bare 0 where -inf dB means nothing
      # (thresholds, ceilings, makeup, +max_gain+, compander points;
      # MB::Sound.live_error, live mode reads it as 0 dB).  See
      # Decibels.gain_of and .db_of.  A linear level
      # above 1 (louder than full scale, e.g. `threshold: 6`, +15.6 dB)
      # warns once per call site.  Until 2026-10-14 bare numbers at 0 and
      # below meant dB here; graph documents older than format 3 load with
      # that meaning (see .from_old_document).  Knee widths, compand's
      # +over+ and +step+, and compand blocks are plain dB numbers (widths
      # and positions on the dB axis, not levels).
      # Times are seconds, Lengths (5.ms), Durations (1.n8, following the
      # tempo), or nodes.
      #
      # Examples (bin/sound.rb):
      #     drums.compress(threshold: -18.db, ratio: 4, attack: 10.ms, release: 120.ms, makeup: :auto)
      #     bass.duck(kick)                                  # tech house pumping (-18 dB, 1/16 release)
      #     drums.compress(threshold: -30.db, ratio: 8, attack: 3.ms, release: 80.ms, makeup: :auto, mix: 0.4)  # parallel ("New York")
      #     mix.limit(ceiling: -1.db, lookahead: 1.5.ms)        # true-peak brickwall
      #     master { |mix| mix.softclip(0.7, 1).limit(ceiling: -1.db, release: 60.ms) }  # hot mixes: softclip into the limiter
      #     pad.compand(-60.db => -80.db, -40.db => -40.db, 0.db => -12.db)    # expander + 3.3:1 compressor
      #     mix.bands(120.hz, 2000.hz) { |lo, mid, hi| [lo.compress(ratio: 3), mid, hi.at(-2.db)] }
      #     mix.squeeze(:eleven).limit
      module DynamicsMethods
        # A level as a linear gain: a Decibels value (-6.db) is its gain, a
        # bare number a linear gain (Decibels.gain_of; see the Units note
        # above).  +zero+ allows a bare 0 (-inf dB: a full cut, for +range+
        # and +amount+).
        def self.level(value, name, zero: false)
          Decibels.gain_of(value, name, zero: zero, above_one: true)
        end

        # A level in dB: a Decibels value (-6.db) is its exact dB value, a
        # bare number a linear gain (Decibels.db_of).
        def self.level_db(value, name, zero: false)
          Decibels.db_of(value, name, zero: zero, above_one: true)
        end

        # A gain or compander point in dB (+makeup+, +min_gain+/+max_gain+,
        # squeeze +gain+): a Decibels value is its exact dB value, a bare
        # number a linear gain (`makeup: 2` is +6 dB), without the warning
        # above full scale (gains above 1 are what makeup is for).
        def self.gain_db(value, name, zero: false)
          Decibels.db_of(value, name, zero: zero)
        end

        # A dB number for the classes under the DSL (Dynamics, Transfer),
        # which take dB: a Decibels value as its dB value, numbers as they
        # are.
        def self.db_param(value)
          value.is_a?(Decibels) ? value.db_value : value
        end

        # The methods taking levels and their level keywords.
        LEVEL_METHODS = %i[
          compress compressor expand expander noise_gate duck sidechain_duck limit limiter brickwall
        ].freeze
        LEVEL_KEYWORDS = %i[threshold upward_threshold ceiling amount range].freeze

        # Keywords holding dB gains, by method (compand's points too).
        GAIN_KEYWORDS = {
          compress: %i[makeup max_gain], compressor: %i[makeup max_gain],
          expand: %i[makeup], expander: %i[makeup], noise_gate: %i[makeup],
          compand: %i[makeup min_gain max_gain], compander: %i[makeup min_gain max_gain],
          squeeze: %i[gain max_gain],
        }.freeze

        # Arguments for dynamics method +name+ from a graph document older
        # than format 3 (see GraphIO::FORMAT), which wrote dB levels as bare
        # numbers at 0 and below and dB gains and compander points as bare
        # numbers: returns [args, kwargs, changed], those numbers turned
        # into the Decibels they meant (an unlimited -Float::INFINITY or
        # Float::INFINITY +min_gain+/+max_gain+ is left out, the default).
        def self.from_old_document(name, args, kwargs)
          changed = false
          old_db = ->(v) { changed = true; Decibels.new(v) }
          bare = ->(v) { v.is_a?(Numeric) && !v.is_a?(Decibels) && v.real? }
          kwargs = kwargs.dup
          if LEVEL_METHODS.include?(name)
            LEVEL_KEYWORDS.each do |k|
              kwargs[k] = old_db.(kwargs[k]) if bare.(kwargs[k]) && kwargs[k] <= 0
            end
          end
          GAIN_KEYWORDS.fetch(name, []).each do |k|
            next unless bare.(kwargs[k])
            if kwargs[k].infinite? && %i[min_gain max_gain].include?(k)
              kwargs.delete(k)
              changed = true
            else
              kwargs[k] = old_db.(kwargs[k])
            end
          end
          if name == :compand || name == :compander
            point = ->(p) { p.is_a?(Array) && (2..3).cover?(p.length) ? [*p[0, 2].map { |v| bare.(v) ? old_db.(v) : v }, *p[2..]] : p }
            args = args.dup
            if args[0].is_a?(Hash)
              args[0] = args[0].to_h { |a, b| point.([a, b]) }
            elsif args[0].is_a?(Array)
              args[0] = args[0].map(&point)
            end
            kwargs = kwargs.to_h { |k, v| k.is_a?(Symbol) ? [k, v] : point.([k, v]) }
          end
          [args, kwargs, changed]
        end

        # A compressor ratio as a slope above the threshold (1/ratio).
        def self.ratio_slope(ratio, name = 'ratio')
          raise ArgumentError, "#{name} must be a number of at least 1 (got #{ratio.inspect})" unless ratio.is_a?(Numeric) && ratio >= 1
          ratio.to_f.infinite? ? 0.0 : 1.0 / ratio
        end

        # A feed-forward compressor: above +threshold+ the level rises 1 dB
        # per +ratio+ dB (Float::INFINITY for a limiter-like flat top),
        # rounded by a +knee+ dB wide soft knee.  +attack+ and +release+ are
        # the gain's fall and rise times (one-pole time constants), +hold+
        # keeps the reduction that long before releasing.  +makeup+ is a gain
        # (`6.db`) or :auto (half the gain change at 0 dBFS back).
        #
        # +sidechain+ (any node or bundle, or a bus or track name such as
        # :drums; see BusMethods#bus) drives the detector instead of the
        # input; +detector+ is :peak (default) or :rms (+rms+ window);
        # +link+ (default true) uses one detector for every channel;
        # +lookahead+ delays the audio so the gain moves before peaks.
        #
        # Upward compression: +upward_threshold+ (dB) and +upward_ratio+ lift
        # levels below that threshold toward it (2 = half as far below), at
        # most +max_gain+ (default 24.db).  When the level rises, the gain
        # falls over +upward_attack+ (default 1 ms) while it is above 0 dB,
        # then over +attack+, so hits after quiet stretches don't burst
        # through boosted.
        #
        # +mix+ (0..1, default 1) blends the compressed signal with the
        # plain one (parallel or "New York" compression), phase-aligned.
        #
        # Examples (bin/sound.rb):
        #     play file_input('drums.flac').compress(threshold: -20.db, ratio: 4, attack: 10.ms, release: 100.ms, makeup: :auto)
        #     play voice.compress(threshold: -30.db, ratio: 3, upward_threshold: -50.db, upward_ratio: 2)
        def compress(threshold: -20.db, ratio: 4, knee: 6, attack: 0.005, release: 0.1, hold: 0, makeup: 0.db,
                     sidechain: nil, detector: :peak, rms: 0.01, link: true, lookahead: 0,
                     upward_threshold: nil, upward_ratio: 2, upward_attack: 0.001, max_gain: 24.db, mix: 1)
          t = DynamicsMethods.level_db(threshold, 'threshold')
          slope = DynamicsMethods.ratio_slope(ratio)
          corners = [[t, 1.0, slope]]
          desc = "#{dyn_fmt_db(t)} dB #{dyn_fmt_ratio(ratio)}"
          if upward_threshold
            tu = DynamicsMethods.level_db(upward_threshold, 'upward_threshold')
            raise ArgumentError, 'upward_threshold must be below threshold' unless tu < t
            corners.unshift([tu, DynamicsMethods.ratio_slope(upward_ratio, 'upward_ratio'), 1.0])
            desc += ", up #{dyn_fmt_db(tu)} dB #{dyn_fmt_ratio(upward_ratio)}"
          end
          transfer = Dynamics::Transfer.corners(corners[0][0], corners, knee: knee, description: desc)
          finish_dynamics(Dynamics.new(
            outputs, transfer: transfer, down: attack, up: release, hold: hold, hold_up: true,
            detector: detector, rms: rms, link: link, sidechain: sidechain, lookahead: lookahead,
            makeup: dyn_makeup(makeup), max_gain: upward_threshold ? DynamicsMethods.gain_db(max_gain, 'max_gain') : 0.0, boost: upward_attack, mix: mix,
          ))
        end
        alias compressor compress

        # A downward expander: below +threshold+ the level falls +ratio+ dB
        # per dB, by at most +range+ (default -40.db).  +attack+ is how fast
        # it opens, +release+ how fast it closes, +hold+ how long it stays
        # open after the level falls.
        #
        # Example (bin/sound.rb):
        #     play noisy.expand(threshold: -45.db, ratio: 3, range: -30.db)
        def expand(threshold: -40.db, ratio: 2, knee: 6, range: -40.db, attack: 0.001, release: 0.1, hold: 0, makeup: 0.db,
                   sidechain: nil, detector: :peak, rms: 0.01, link: true, lookahead: 0, mix: 1)
          t = DynamicsMethods.level_db(threshold, 'threshold')
          raise ArgumentError, "Expander ratio must be at least 1 (got #{ratio.inspect})" unless ratio.is_a?(Numeric) && ratio >= 1 && ratio.finite?
          r = DynamicsMethods.level_db(range, 'range', zero: true)
          raise ArgumentError, 'range must be at most 0 dB' if r > 0
          transfer = Dynamics::Transfer.corners(t, [[t, ratio.to_f, 1.0]], knee: knee, description: "expand #{dyn_fmt_db(t)} dB 1:#{dyn_fmt_ratio(ratio, false)}, range #{dyn_fmt_db(r)} dB")
          finish_dynamics(Dynamics.new(
            outputs, transfer: transfer, down: release, up: attack, hold: hold, hold_up: false,
            detector: detector, rms: rms, link: link, sidechain: sidechain, lookahead: lookahead,
            makeup: dyn_makeup(makeup), min_gain: r, max_gain: 0.0, mix: mix,
          ))
        end
        alias expander expand

        # A noise gate: an expander with a steep ratio (+ratio+, default 20)
        # and +range+ (default -80.db), opening in +attack+, staying open
        # +hold+ after the level falls, then closing over +release+.
        #
        # Example (bin/sound.rb):
        #     play snare.noise_gate(threshold: -30.db, hold: 30.ms, release: 50.ms)
        def noise_gate(threshold: -50.db, range: -80.db, ratio: 20, knee: 0, attack: 0.0005, hold: 0.02, release: 0.05, **options)
          expand(threshold: threshold, range: range, ratio: ratio, knee: knee, attack: attack, hold: hold, release: release, **options)
        end

        # Sidechain ducking: turns this signal down by up to +amount+ (e.g.
        # -18.db; 18.db is the same, since ducking never boosts; a bare
        # number is a linear gain at most 1, see Decibels.reduction_db)
        # while +sidechain+ (e.g. a kick) is above
        # +threshold+, the reduction growing 1 dB per dB above it (an
        # infinite-ratio compressor with a range) so loud hits duck fully;
        # recovering over +release+ (a one-pole time constant: seconds, a
        # Length, or a Duration that follows the tempo) after +hold+.  The
        # classic tech house pump, also usable in a master chain
        # (`master { |mix| mix.duck(kick) }`).
        #
        # Defaults (2026-10-11, the maintainer's listening pick, "deep pump
        # -18 dB ... I like the deeper cut", with the faster release they
        # suggested): -18 dB, 1 ms attack, 20 ms hold, 1/16 release.  Behind
        # an 808 kick at 124 BPM the gain is -7 dB at the offbeat and -1 dB
        # by the next kick (a 1/8 release: -11 and -4, never recovering).
        # Lighter: `amount: -8.db`; snappier: `release: 1.n32`; longer:
        # `release: 1.n8`; flat-topped: `hold: 1.n16, release: 1.n32`.
        #
        # Example (bin/sound.rb):
        #     kick = grid('x...x...x...x...').loop.trigger.ping(50, decay: 0.3)
        #     bass = seq(A1, A1, C2, A1).n8.loop.tone.saw.lp4(400)
        #     bg [kick, bass.duck(kick)].sum
        #     bg [kick, bass.duck(kick, amount: -10.db, release: 1.n32)].sum   # lighter and snappier
        #
        # +sidechain+ may also name a bus or track (see BusMethods#bus and
        # design/notes/buses.md): `duck(:drums)` follows what :drums plays,
        # and `duck(:drums, only: :kick)` its kick voice (a drum voice, or a
        # node given `.named(:kick)`, inside :drums' graph), read in the same
        # buffer on the exact sample.
        def duck(sidechain, amount: -18.db, threshold: -30.db, knee: 6, attack: 0.001, release: 1.n16, hold: 0.02,
                 detector: :peak, rms: 0.01, link: true, lookahead: 0, only: nil)
          raise ArgumentError, 'duck needs a sidechain node (e.g. the kick)' if sidechain.nil?
          raise ArgumentError, 'only: picks a node inside a bus or track named by a Symbol (duck(:drums, only: :kick))' if only && !sidechain.is_a?(Symbol)
          SidechainMethods.check_impulse_duck(sidechain, attack) if sidechain.is_a?(Symbol) && only.nil?
          sidechain = BusTap.from(sidechain, only: only) if sidechain.is_a?(Symbol)
          a = -Decibels.reduction_db(amount, 'amount')
          t = DynamicsMethods.level_db(threshold, 'threshold')
          transfer = Dynamics::Transfer.corners(t, [[t, 1.0, 0.0]], knee: knee, description: "duck #{dyn_fmt_db(a)} dB above #{dyn_fmt_db(t)} dB")
          finish_dynamics(Dynamics.new(
            outputs, transfer: transfer, down: attack, up: release, hold: hold, hold_up: true,
            detector: detector, rms: rms, link: link, sidechain: sidechain, lookahead: lookahead,
            min_gain: a, max_gain: 0.0,
          ))
        end
        alias sidechain_duck duck

        # An arbitrary compander: a transfer curve from input level (dB) to
        # output level (dB), as points, a block, or a Dynamics::Transfer.
        #
        # Points are levels (`-60.db`) in a Hash (`compand(-60.db => -80.db,
        # -40.db => -40.db, 0.db => -12.db)`) or an Array of [input, output]
        # or [input, output, shape] (shape for the segment to the next
        # point: :linear, :cubic, or a Curve name such as :smooth, a Curve,
        # or a Proc on 0..1).  +interpolation+ is
        # :linear (default) or :cubic (monotone cubics through every point:
        # smooth knees, never overshooting).  Outputs must not decrease.
        # Outside the points the curve continues its end slopes.
        #
        # A block maps input dB to output dB (plain numbers), sampled every +step+ dB over
        # +over+ (default -100..12) and joined by monotone cubics.
        #
        # Times: +attack+ is how fast the gain falls, +release+ how fast it
        # rises, +upward_attack+ (default +attack+) how fast it falls while
        # above 0 dB (a boost).  The gain is limited to
        # +min_gain+..+max_gain+ (gains like -40.db and 12.db; unlimited by
        # default).  The other options are as for #compress.
        #
        # Examples (bin/sound.rb):
        #     play drums.compand(-60.db => -70.db, -30.db => -30.db, 0.db => -10.db, interpolation: :cubic)   # glue with a soft floor
        #     play pad.compand([[-60.db, -80.db], [-40.db, -40.db, :smooth], [0.db, -12.db]])
        #     play noisy.compand { |db| db < -50 ? db * 2 + 50 : db }                      # 1:2 expander below -50
        def compand(points = nil, interpolation: :linear, over: -100..12, step: 1, attack: 0.005, release: 0.1, hold: 0,
                    makeup: 0.db, sidechain: nil, detector: :peak, rms: 0.01, link: true, lookahead: 0,
                    min_gain: nil, max_gain: nil, upward_attack: nil, mix: 1, **more_points, &block)
          bad = more_points.keys.reject { |k| k.is_a?(Numeric) }
          raise ArgumentError, "Unknown compand options: #{bad.map(&:inspect).join(', ')}" unless bad.empty?

          transfer = if points.is_a?(Dynamics::Transfer)
            raise ArgumentError, 'Give compand a transfer curve, points, or a block, not several' if block || !more_points.empty?
            points
          elsif block
            raise ArgumentError, 'Give compand points or a block, not both' if points || !more_points.empty?
            Dynamics::Transfer.from_block(over, step: step, &block)
          else
            pts = points.is_a?(Hash) ? points.to_a : points.to_a
            pts += more_points.to_a
            pts = pts.map { |p|
              next p unless p.is_a?(Array) && (2..3).cover?(p.length)
              [DynamicsMethods.gain_db(p[0], 'compand point input'), DynamicsMethods.gain_db(p[1], 'compand point output'), *p[2..]]
            }
            Dynamics::Transfer.points(pts, interpolation: interpolation)
          end

          finish_dynamics(Dynamics.new(
            outputs, transfer: transfer, down: attack, up: release, hold: hold, hold_up: true,
            detector: detector, rms: rms, link: link, sidechain: sidechain, lookahead: lookahead,
            makeup: dyn_makeup(makeup),
            min_gain: min_gain.nil? ? -Float::INFINITY : DynamicsMethods.gain_db(min_gain, 'min_gain', zero: true),
            max_gain: max_gain.nil? ? Float::INFINITY : DynamicsMethods.gain_db(max_gain, 'max_gain'),
            boost: upward_attack, mix: mix,
          ))
        end
        alias compander compand

        # A lookahead brickwall limiter (Dynamics::Limiter): the output stays
        # at or under +ceiling+ (-1 dB by default; with +true_peak+, its
        # inter-sample peaks too, within about 0.1 dB), the gain ramping down
        # over +lookahead+ before each peak and recovering over +release+.
        # Adds +lookahead+ of latency (plus 6 samples with +true_peak+).
        #
        # Example (bin/sound.rb):
        #     master { |mix| mix.limit(ceiling: -1.db, release: 80.ms) }
        #     # Hot mixes: a softclip in front takes the peaks the limiter
        #     # would pump on (the maintainer's pick on the dynamics bench)
        #     master { |mix| mix.softclip(0.7, 1).limit(ceiling: -1.db, release: 60.ms) }
        def limit(ceiling: -1.db, lookahead: 0.0015, release: 0.1, true_peak: true, link: true)
          finish_dynamics(Dynamics::Limiter.new(outputs, ceiling: ceiling, lookahead: lookahead, release: release, true_peak: true_peak, link: link))
        end
        alias limiter limit
        alias brickwall limit

        # Splits this signal into bands at +frequencies+ (Hz numbers or
        # Pitches, increasing) with Linkwitz-Riley crossovers (+order+ 2, 4
        # (default), or 8), yields one node per band (a bundle per band for
        # multichannel input), low to high, and returns the sum of what the
        # block returns (an Array of nodes or bundles, one-channel results
        # used for every channel).  Untouched bands sum back to the input
        # through an allpass (flat).  Without a block, returns the bands as
        # an Array.
        #
        # Examples (bin/sound.rb):
        #     play drums.bands(150.hz, 3000.hz) { |lo, mid, hi| [lo.compress(ratio: 4), mid, hi.at(-3.db)] }
        #     play mix.bands(300) { |lo, hi| [lo.mono, hi] }   # mono bass
        def bands(*frequencies, order: 4)
          frequencies = frequencies.flatten
          chans = outputs
          splits = chans.map { |c| Dynamics::Crossover.new(c, frequencies, order: order) }
          band_nodes = Array.new(frequencies.length + 1) { |b|
            nodes = splits.map { |s| s.outputs[b] }
            nodes.length == 1 ? nodes[0] : Channels.new(nodes)
          }
          return band_nodes unless block_given?

          results = yield(*band_nodes)
          results = [results] unless results.is_a?(Array)
          raise ArgumentError, 'The bands block must return at least one node' if results.empty?
          summed = Array.new(chans.length) { |c|
            parts = results.map { |r|
              raise ArgumentError, "The bands block must return graph nodes or bundles (got #{r.class})" unless r.is_a?(GraphNode) || r.is_a?(MultiOutput)
              outs = r.outputs
              if outs.length == 1
                outs[0]
              elsif outs.length == chans.length
                outs[c]
              else
                raise ArgumentError, "A band result has #{outs.length} channels; expected 1 or #{chans.length}"
              end
            }
            parts.length == 1 ? parts[0] : Mixer.new(parts)
          }
          summed.length == 1 ? summed[0] : Channels.new(summed)
        end
        alias multiband bands

        # Makes everything below +frequency+ (Hz or a Pitch) mono.  A stereo
        # pair keeps its mid (L + R) / 2 untouched and highpasses its side
        # (L - R) / 2 with the high half of a Linkwitz-Riley crossover
        # (+order+ 2, 4, 8 as for #bands), so a mix whose lows are already
        # mono passes sample for sample (decks-1, 2026-10-22: the crossover
        # this used to split every channel with put the whole mix through
        # its allpass, which turned kick + sub into taller peaks; Nev's N16
        # measured 2.3 LU lost at a -1 dBTP ceiling on a mix with its side
        # 77 dB under the mid).  Three or more channels still split each
        # channel with #bands and average the low bands.  A mastering option
        # for club systems and vinyl, not something headphone or ambient
        # mixes usually want.  One-channel nodes come back unchanged.
        #
        # Example (bin/sound.rb):
        #     master { |mix| mix.mono_below(120).limit(ceiling: -1.db) }
        def mono_below(frequency, order: 4)
          chans = outputs
          return self if chans.length < 2
          return bands(frequency, order: order) { |lo, hi| [lo.mono, hi] } if chans.length > 2

          dampings = Dynamics::Crossover::ORDERS.fetch(order) {
            raise ArgumentError, "order: is #{Dynamics::Crossover::ORDERS.keys.join(', ')} (got #{order.inspect})"
          }
          # LR2 is one critically damped section (a first-order Butterworth
          # squared), LR4 and LR8 each Butterworth section twice
          dampings = order == 2 ? dampings : dampings + dampings
          mid, side = Channels.new(chans).mid_side.outputs
          dampings.each { |k| side = side.filter(:highpass, cutoff: frequency, quality: 1.0 / k) }
          Channels.new([mid, side]).from_mid_side
        end

        # Presets for #squeeze: crossovers (Hz), depth (the parallel mix),
        # the upward boost's fall time, and per band (low, mid, high) the
        # downward threshold (dB) and ratio, upward threshold (dB) and
        # ratio, attack and release (seconds, scaled by +time+).  Values
        # chosen by ear and measurement (inspired by, not copied from, the
        # classic three-band upward/downward "OTT" preset).
        # - :default - gentle glue: 3:1 down, 1.5:1 up, half depth
        # - :eleven - over the top: 66:1 down, 4:1 up, full depth, loud and
        #   crunchy (follow it with #limit)
        SQUEEZE_PRESETS = {
          default: {
            split: [120, 2500].freeze, depth: 0.5, upward_attack: 0.002,
            bands: [
              { down: -24.db, down_ratio: 3, up: -42.db, up_ratio: 1.5, attack: 0.005, release: 0.2 }.freeze,
              { down: -26.db, down_ratio: 3, up: -44.db, up_ratio: 1.5, attack: 0.0025, release: 0.15 }.freeze,
              { down: -28.db, down_ratio: 3, up: -46.db, up_ratio: 1.5, attack: 0.00125, release: 0.1 }.freeze,
            ].freeze,
          }.freeze,
          eleven: {
            split: [88.3, 2500].freeze, depth: 1.0, upward_attack: 0.0005,
            bands: [
              { down: -28.db, down_ratio: 66, up: -46.db, up_ratio: 4, attack: 0.003, release: 0.15 }.freeze,
              { down: -30.db, down_ratio: 66, up: -48.db, up_ratio: 4, attack: 0.0015, release: 0.1 }.freeze,
              { down: -32.db, down_ratio: 66, up: -50.db, up_ratio: 4, attack: 0.00075, release: 0.06 }.freeze,
            ].freeze,
          }.freeze,
        }.freeze

        # Multiband upward + downward compression ("squeeze it to eleven"):
        # three LR4 bands, each compressed downward above a threshold and
        # upward below a lower one (upward below a lower one (at most +max_gain+ of lift, default 24.db)), with
        # :auto makeup per band.  +preset+ is :default (gentle glue) or
        # :eleven (the extreme, OTT-style setting; see SQUEEZE_PRESETS).
        # +downward+ and +upward+ (0..1) scale the ratios toward 1:1; +time+
        # scales attack and release; +depth+ (0..1, default from the
        # preset) mixes each compressed band with the plain band
        # (phase-aligned); +split+ overrides the crossovers; +gain+ is an
        # output gain (`3.db`).  Every band looks +lookahead+ ahead (default 2
        # ms, the node's latency) so the fast attacks catch transients.
        # Master-chain friendly (about 0.7% of realtime per stereo
        # 800-sample buffer).
        #
        # Examples (bin/sound.rb):
        #     play drums.squeeze                     # gentle
        #     play drums.squeeze(:eleven).limit       # crunchy, loud
        #     master { |mix| mix.squeeze(depth: 0.3, time: 0.5) }
        def squeeze(preset = :default, depth: nil, time: 1.0, upward: 1.0, downward: 1.0, split: nil, gain: 0.db, max_gain: 24.db, lookahead: 0.002)
          settings = SQUEEZE_PRESETS[preset]
          raise ArgumentError, "Unknown squeeze preset #{preset.inspect} (use #{SQUEEZE_PRESETS.keys.map(&:inspect).join(' or ')})" unless settings
          depth ||= settings[:depth]
          split ||= settings[:split]
          raise ArgumentError, "Squeeze depth must be 0..1 (got #{depth.inspect})" unless depth.is_a?(Numeric) && (0..1).cover?(depth)
          raise ArgumentError, 'Squeeze splits three bands: give two crossover frequencies' unless split.length == 2
          raise ArgumentError, "Squeeze time must be above 0 (got #{time.inspect})" unless time.is_a?(Numeric) && time > 0
          [upward, downward].each { |v| raise ArgumentError, "Squeeze upward/downward must be 0..1 (got #{v.inspect})" unless v.is_a?(Numeric) && (0..1).cover?(v) }

          out = bands(*split) { |*bs|
            bs.each_with_index.map { |b, i|
              s = settings[:bands][i]
              ratio_down = 1.0 / (1.0 - downward * (1.0 - 1.0 / s[:down_ratio]))
              ratio_up = 1.0 / (1.0 - upward * (1.0 - 1.0 / s[:up_ratio]))
              b.compress(
                threshold: s[:down], ratio: ratio_down, knee: 6, attack: s[:attack] * time, release: s[:release] * time,
                upward_threshold: s[:up], upward_ratio: ratio_up, upward_attack: settings[:upward_attack] * time,
                max_gain: max_gain, makeup: :auto, mix: depth, lookahead: lookahead,
              )
            }
          }
          gain = DynamicsMethods.gain_db(gain, 'gain')
          gain == 0 ? out : out * (10.0 ** (gain / 20.0))
        end

        private

        # +makeup+ for Dynamics: :auto, or dB from a Decibels value or a
        # linear gain (see the Units note above).
        def dyn_makeup(makeup)
          makeup == :auto ? :auto : DynamicsMethods.gain_db(makeup, 'makeup')
        end

        # Returns +node+'s single output for one channel, else the bundle.
        def finish_dynamics(node)
          node.channel_count == 1 ? node.outputs[0] : node
        end

        def dyn_fmt_db(v)
          v.finite? ? MB::M.sigfigs(v, 3).to_s.sub(/\.0\z/, '') : v.to_s
        end

        def dyn_fmt_ratio(r, colon_one = true)
          s = r.to_f.infinite? ? 'inf' : MB::M.sigfigs(r.to_f, 3).to_s.sub(/\.0\z/, '')
          colon_one ? "#{s}:1" : s
        end
      end
    end
  end
end

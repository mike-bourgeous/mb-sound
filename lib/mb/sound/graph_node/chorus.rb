module MB
  module Sound
    module GraphNode
      # A Juno-60-style stereo chorus: one delay line read at two taps whose
      # delay times are swept by a triangle LFO, the right tap's sweep
      # inverted (180 degrees apart), each tap added to the dry signal.
      # Built from library nodes (Tone LFOs, a MultitapDelay with
      # band-limited :sinc reads, SVF lowpasses, noise), so it follows
      # sample rate changes and tempo-synced rates like any graph.
      #
      # Kept self-contained (this file, chorus_nodes.rb, their require
      # lines and the include lines in graph_node.rb and channels.rb, and the
      # ChannelDispatch::EXCLUDED entry) so it can move into a later effects
      # project.
      #
      # Use GraphNode#chorus (ChorusMethods#chorus) to build one.
      module Chorus
        # Chorus modes: triangle LFO rates (Hz; one LFO per entry, each
        # sweeping a left tap and an inverted right tap) and the delay
        # sweep's shortest and longest times (seconds).  The Juno-60 modes
        # are as measured by Andy Harman (pendragon-andyh) on a Juno-60:
        # https://github.com/pendragon-andyh/Juno60/blob/master/Chorus/README.md
        #   - I: 0.513 Hz, 1.66-5.35 ms
        #   - II: 0.863 Hz, 1.66-5.35 ms
        #   - I+II: 9.75 Hz, 3.3-3.7 ms (a fast, shallow vibrato-like warble)
        # :lush (not on the hardware) runs I and II at once: four taps, both
        # LFOs over the I/II range.
        MODES = {
          juno1: { rates: [0.513].freeze, min: 0.00166, max: 0.00535 }.freeze,
          juno2: { rates: [0.863].freeze, min: 0.00166, max: 0.00535 }.freeze,
          juno12: { rates: [9.75].freeze, min: 0.0033, max: 0.0037 }.freeze,
          lush: { rates: [0.513, 0.863].freeze, min: 0.00166, max: 0.00535 }.freeze,
        }.freeze

        # Other names for MODES.
        ALIASES = {
          juno: :juno1,
          juno_i: :juno1,
          juno_ii: :juno2,
          juno_i_ii: :juno12,
          juno3: :lush,
          stacked: :lush,
        }.freeze

        # The Juno-60 chorus board's anti-aliasing (before the BBD) and
        # reconstruction (after) lowpasses as [frequency in Hz, Q] per pole
        # (Q nil for a real pole), from the pole/residue table (table 1) of
        # Holters and Parker, "A Combined Model for a Bucket Brigade Device
        # and its Input and Output Filters", DAFx-18 (2018), section 4,
        # which models the Juno-60's chorus from circuit analysis checked
        # against a recording:
        # https://www.hsu-hh.de/ant/wp-content/uploads/sites/699/2018/09/Holters-Parker-2018-A-Combined-Model-for-a-Bucket-Brigade-Device-and-its-Input-and-Output-Filters.pdf
        # Both are fifth-order lowpasses (after a first-order bias highpass,
        # left out here).  Each pole p gives f = |p| / 2pi and
        # Q = |p| / (-2 Re p).  Played as all-pole cascades (FirstOrder and
        # SVF lowpasses), which match the paper's full transfer functions
        # within 0.3 dB to 30 kHz (the residues' zeros barely matter); the
        # output filter's real pole at 28053 Hz (-0.5 dB at 10 kHz) is left
        # out since it is above Nyquist at 48 kHz.  The input filter alone
        # is -3 dB at 6.5 kHz, the output at 8.75 kHz.  At 48 kHz the
        # filters' bilinear transform cuts more near Nyquist (wet path -27
        # dB at 12 kHz against the analog -21).  (Pendragon's notes
        # mention a 12 dB/octave lowpass; the paper's analysis is used.)
        # Not modeled: the BBD's own sample-and-hold rolloff, which moves
        # with the delay time (clock about 24-77 kHz over the I/II sweep).
        BBD_PRE_POLES = [[7413.4, nil], [9690.6, 0.5487], [10343.9, 1.2360]].freeze
        BBD_POST_POLES = [[8873.5, 0.5416], [10381.0, 1.2412]].freeze

        # The -3 dB frequency (Hz) of the wet path through both of the
        # paper's filters (BBD_PRE_POLES and BBD_POST_POLES, the 28 kHz pole
        # included), computed from the poles.  A cutoff: option scales every
        # pole by cutoff / BBD_CUTOFF.
        BBD_CUTOFF = 5420

        # The BBD flavour's hiss level in dBFS per channel (white noise
        # through the post filter).  An estimate: no measurement of the
        # Juno's chorus noise floor was found (2026-10-08).  The MN3009
        # datasheet gives S/N 88 dB typical (noise 0.2 mVrms max), and a
        # Juno clone's notes (github.com/pirassic/janesixty,
        # docs/calibration-report.md) estimate -84 dB re a 4 Vp-p sine from
        # the datasheet; players describe the Juno-60/106 chorus hiss as
        # clearly audible (no compander), so this stays louder.  UNVERIFIED.
        BBD_HISS = -72

        # Seconds after the longest delay that the chorus keeps running once
        # its input ends (filter ring-out), and over which the hiss fades.
        TAIL_EXTRA = 0.05

        # Returns the mode settings Hash for +mode+ (a MODES key or ALIASES
        # name), raising ArgumentError for unknown modes.
        def self.mode(mode)
          mode = ALIASES.fetch(mode, mode)
          MODES.fetch(mode) {
            raise ArgumentError, "Unknown chorus mode #{mode.inspect} (use one of #{(MODES.keys + ALIASES.keys).join(', ')})"
          }
        end

        # Builds the chorus on +input+ (see ChorusMethods#chorus for
        # parameters), returning a stereo Channels bundle.
        def self.build(input, mode = :juno1, rate: nil, depth: 1, delay: nil, dry: 1, wet: 1, mix: nil, bbd: false, cutoff: nil, hiss: nil, seed: nil, interpolation: :sinc)
          settings = self.mode(mode)

          count = input.channel_count
          raise ArgumentError, "Chorus takes one or two channels (got #{count})" unless count == 1 || count == 2

          sample_rate = input.sample_rate

          if delay
            raise ArgumentError, "delay: must be a Range of lengths (e.g. 2.ms..6.ms), got #{delay.inspect}" unless delay.is_a?(Range)
            lo = MB::Sound::Length.seconds(delay.begin, sample_rate: sample_rate)
            hi = MB::Sound::Length.seconds(delay.end, sample_rate: sample_rate)
          else
            lo = settings[:min]
            hi = settings[:max]
          end
          raise ArgumentError, "Chorus delays must not be negative (got #{lo}..#{hi})" if lo < 0 || hi < 0
          center = (lo + hi) / 2.0
          half = (hi - lo) / 2.0

          if depth.is_a?(Numeric) && center - half * depth.abs < 0
            raise ArgumentError, "depth #{depth} sweeps the delay below zero (at most #{center / half} for this range)"
          end

          dry, wet = mix_gains(dry, wet, mix)

          rates = rates(settings[:rates], rate)
          times = rates.flat_map { |r| [half, -half].map { |h| delay_node(r, center, h, depth, sample_rate) } }

          cutoff = BBD_CUTOFF if cutoff.nil? && bbd
          hiss = BBD_HISS if hiss.nil? && bbd

          # The input keeps playing zeros for the delay tail after it ends
          # (a node depth may sweep further than a numeric one).
          longest = depth.is_a?(Numeric) ? center + half * depth.abs : 2 * hi
          tail = longest + TAIL_EXTRA
          dry_inputs = input.outputs.map { |o| Tail.new(o, tail) }
          enders = ending_nodes(input)

          mono = count == 1 ? dry_inputs[0] : Channels.new(dry_inputs.map(&:get_sampler)).mono
          mono = mono.get_sampler
          scale = cutoff && (cutoff.is_a?(Numeric) ? cutoff.to_f / BBD_CUTOFF : (cutoff * (1.0 / BBD_CUTOFF)).get_sampler)
          wet_input = cutoff ? bbd_filter(mono, BBD_PRE_POLES, scale) : mono

          # Each LFO's taps alternate left, right; stacked LFOs add at equal
          # power.
          taps = wet_input.multitap(*times, interpolation: interpolation).to_a
          tap_gain = Math.sqrt(1.0 / rates.length)
          seeds = [seed, seed && seed + 1]
          wets = [0, 1].map { |side|
            w = taps.values_at(*(side...taps.length).step(2)).reduce(:+)
            w = w * tap_gain unless rates.length == 1
            if hiss
              noise = MB::Sound.noise(seed: seeds[side]).at(hiss.db).at_rate(sample_rate)
              w = w + HissGate.new(noise, dry_inputs, enders, tail)
            end
            w = bbd_filter(w, BBD_POST_POLES, scale) if cutoff
            w
          }

          dry_l, dry_r = count == 1 ? [mono, mono] : dry_inputs.map(&:get_sampler)

          outputs = [[dry_l, wets[0], 'L'], [dry_r, wets[1], 'R']].map { |d, w, side|
            mix(d, w, dry, wet).named("Juno chorus #{side}")
          }

          Channels.new(outputs)
        end

        # The LFO rates for a mode's +defaults+ and the +rate+ option: the
        # defaults without one, else one rate per LFO.  With several LFOs
        # (:lush), +rate+ is an Array of one per LFO, or a number of Hz for
        # the first, the others keeping their ratios to it.
        def self.rates(defaults, rate)
          return defaults if rate.nil?
          return [rate] if defaults.length == 1 && !rate.is_a?(Array)

          if rate.is_a?(Array)
            raise ArgumentError, "Give #{defaults.length} rates for this mode (got #{rate.length})" unless rate.length == defaults.length
            rate
          elsif rate.is_a?(Numeric)
            defaults.map { |r| rate * r / defaults[0] }
          else
            raise ArgumentError, "This mode has #{defaults.length} LFOs: give an Array of rates or a number of Hz (got #{rate.inspect})"
          end
        end

        # The dry and wet gains for the +dry+, +wet+, and +mix+ options: +mix+
        # (0 = dry only, 1 = wet only; a number or node) multiplies +dry+ by
        # 1 - mix and +wet+ by mix.  Without +mix+, +dry+ and +wet+ as given.
        def self.mix_gains(dry, wet, mix)
          return [dry, wet] if mix.nil?

          if mix.is_a?(Numeric)
            raise ArgumentError, "mix: must be within 0..1 (got #{mix})" unless (0..1).cover?(mix)
            [product(dry, 1 - mix), product(wet, mix)]
          else
            mix = mix.aclip(0, 1).get_sampler
            [product(dry, 1 - mix), product(wet, mix)]
          end
        end

        # +a+ times +b+ (numbers or nodes), skipping unity factors.
        def self.product(a, b)
          return a * b if a.is_a?(Numeric) && b.is_a?(Numeric)
          return b if a == 1
          return a if b == 1
          a.is_a?(Numeric) ? b * a : a * b
        end

        # Nodes upstream of +input+ that report when a finite source has
        # ended while the graph keeps sounding: GraphNode::Ringdown (effect
        # script file inputs) and Synths (MIDI files).
        def self.ending_nodes(input)
          [input, *input.outputs, *input.graph].select { |n|
            n.is_a?(Ringdown) || n.is_a?(MB::Sound::Synth)
          }.uniq(&:__id__)
        end

        # The delay time node in seconds for one side (+h+ positive for the
        # left side, negative for the inverted right side).
        def self.delay_node(rate, center, h, depth, sample_rate)
          lfo = lfo_tone(rate).at_rate(sample_rate)
          if depth.is_a?(Numeric)
            a = h * depth
            lfo.at((center - a)..(center + a))
          else
            (lfo * (depth * h) + center).aclip(0, nil)
          end
        end

        # A triangle Tone LFO at +rate+: Hz (Numeric), a Pitch (`0.5.hz`), a
        # Duration (`1.bar`, follows the tempo), or a graph node of Hz.
        def self.lfo_tone(rate)
          tone = case rate
                 when Numeric then rate.hz.lfo
                 when MB::Sound::Sequence::Duration, MB::Sound::Pitch then rate.lfo
                 when MB::Sound::GraphNode then rate.tone.lfo
                 else
                   raise ArgumentError, "Chorus rate must be Hz, a Pitch, a Duration, or a graph node (got #{rate.inspect})"
                 end
          tone.triangle
        end

        # +node+ through a cascade of lowpasses for +poles+ (see
        # BBD_PRE_POLES), every frequency multiplied by +scale+ (a number or
        # a node).  A real pole is a FirstOrder lowpass, or with a node
        # scale (FirstOrder has no cutoff input) a Q 0.5 SVF 1.554 times as
        # high, which has the same -3 dB frequency.
        def self.bbd_filter(node, poles, scale)
          poles.each do |f, q|
            if q
              node = node.filter(:lowpass, cutoff: scale * f, quality: q)
            elsif scale.is_a?(Numeric)
              rate = node.sample_rate
              node = node.filter(MB::Sound::Filter::FirstOrder.new(:lowpass, rate, [f * scale, 0.45 * rate].min))
            else
              node = node.filter(:lowpass, cutoff: scale * (f / Math.sqrt(Math.sqrt(2) - 1)), quality: 0.5)
            end
          end
          node
        end

        # dry * dry_gain + wet * wet_gain, skipping unity gains and zeros.
        def self.mix(d, w, dry, wet)
          d = scale(d, dry)
          w = scale(w, wet)
          return w if d.nil?
          return d if w.nil?
          d + w
        end

        # +node+ times +gain+, the node itself for 1, nil for 0.
        def self.scale(node, gain)
          return node * gain unless gain.is_a?(Numeric)
          return nil if gain == 0
          return node if gain == 1
          node * gain
        end
      end

      # The #chorus DSL method, included in GraphNode and Channels.  Not run
      # per channel (see ChannelDispatch::EXCLUDED): a stereo input is
      # chorused as one.
      module ChorusMethods
        # Appends a Juno-60-style stereo chorus (see Chorus), returning a
        # stereo Channels bundle: left = dry + a delay swept by a triangle
        # LFO, right = dry + the same delay swept the opposite way.
        #
        # +mode+ is :juno1 (alias :juno, :juno_i; 0.513 Hz over 1.66-5.35
        # ms), :juno2 (:juno_ii; 0.863 Hz, same range), or :juno12
        # (:juno_i_ii; 9.75 Hz over 3.3-3.7 ms), the Juno-60's buttons as
        # measured by Pendragon (see Chorus::MODES), or :lush (:juno3,
        # :stacked), which the hardware doesn't have: modes I and II at once,
        # four taps (each LFO sweeps a left tap and an inverted right tap),
        # the two taps on each side mixed at equal power (each times
        # sqrt(1/2)).
        #
        # Like the Juno, the chorus is mono in: a stereo input's channels are
        # averaged for the delay line, while the dry signal keeps its sides
        # (left dry + left wet, right dry + right wet).  Inputs with more
        # than two channels raise an error.
        #
        # Options (numbers or nodes where noted):
        # +:rate+ - LFO rate overriding the mode's: Hz, a Pitch (`0.5.hz`),
        #           a Duration that follows the tempo (`1.bar`, `1.n16`),
        #           or a node of Hz.  For :lush, an Array of two rates, or
        #           a number of Hz for the first LFO (the second keeps the
        #           0.863/0.513 ratio).
        # +:depth+ - Sweep width as a fraction of the mode's (1 = the
        #            Juno's; a number or node; 0 is a fixed delay).
        # +:delay+ - A Range of delay lengths overriding the mode's sweep
        #            (`2.ms..8.ms`, seconds as plain numbers).
        # +:dry+, +:wet+ - Levels (numbers or nodes), 1 and 1 like the Juno,
        #                  so a mono-compatible sum has up to +6 dB peaks.
        # +:mix+ - A dry/wet crossfade from 0 (dry only) to 1 (wet only), a
        #          number or node (clamped to 0..1), multiplying the levels:
        #          dry gain = dry * (1 - mix), wet gain = wet * mix (linear,
        #          so mix 0.5 is the Juno's balance at -6 dB).  Default
        #          nil: dry and wet as given.
        # +:bbd+ - true adds the bucket-brigade flavour: the Juno-60's
        #          fifth-order lowpasses before and after the delay
        #          (Chorus::BBD_PRE_POLES; wet path -3 dB at 5.4 kHz) and hiss
        #          (Chorus::BBD_HISS dBFS).  Off by default (clean).
        # +:cutoff+ - The wet path's -3 dB frequency in Hz through the BBD
        #             filters (Chorus::BBD_CUTOFF, 5420, the Juno's; all
        #             poles scale with it); also turns the filters on
        #             without bbd: true; may be a node.
        # +:hiss+ - Hiss level in dBFS (also without bbd: true).
        # +:seed+ - Hiss seed (default: sub-seeds from MB::Sound.seed).
        # +:interpolation+ - Delay reads (:sinc default, :cubic, :linear;
        #                    see MB::Sound::DelayLine).
        #
        # Both outputs must be read in turn every buffer (as a Session does)
        # since they share one delay line.
        #
        # When the input ends (returns nil), the chorus plays on for the
        # delay tail (longest delay + Chorus::TAIL_EXTRA), then ends.  The
        # hiss fades out over that tail once the input ended, or once every
        # GraphNode::Ringdown and Synth upstream (file inputs in effect
        # scripts, MIDI files) ended, so renders stop after the input.
        #
        # Examples (bin/sound.rb):
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus                # mode I
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno2)        # mode II
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno12)       # I+II warble
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(:lush)         # I and II at once
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno2, bbd: true)  # darker, hissy
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(mix: 0.3)      # 70% dry, 30% wet
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(rate: 1.bar, depth: 1.5)  # tempo-synced sweep
        def chorus(mode = :juno1, **options)
          MB::Sound::GraphNode::Chorus.build(self, mode, **options)
        end
        alias juno_chorus chorus
      end
    end
  end
end

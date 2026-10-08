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
      # Kept self-contained (this file, the include lines in graph_node.rb
      # and channels.rb, and the ChannelDispatch::EXCLUDED entry) so it can
      # move into a later effects project.
      #
      # Use GraphNode#chorus (ChorusMethods#chorus) to build one.
      module Chorus
        # Juno-60 chorus modes: triangle LFO rate (Hz) and the delay sweep's
        # shortest and longest times (seconds), as measured by Andy Harman
        # (pendragon-andyh) on a Juno-60:
        # https://github.com/pendragon-andyh/Juno60/blob/master/Chorus/README.md
        #   - I: 0.513 Hz, 1.66-5.35 ms
        #   - II: 0.863 Hz, 1.66-5.35 ms
        #   - I+II: 9.75 Hz, 3.3-3.7 ms (a fast, shallow vibrato-like warble)
        MODES = {
          juno1: { rate: 0.513, min: 0.00166, max: 0.00535 }.freeze,
          juno2: { rate: 0.863, min: 0.00166, max: 0.00535 }.freeze,
          juno12: { rate: 9.75, min: 0.0033, max: 0.0037 }.freeze,
        }.freeze

        # Other names for MODES.
        ALIASES = {
          juno: :juno1,
          juno_i: :juno1,
          juno_ii: :juno2,
          juno_i_ii: :juno12,
          juno_both: :juno12,
        }.freeze

        # The BBD flavour's lowpass cutoff (Hz) before and after the delay
        # line (two 12 dB/octave filters).  An estimate: Pendragon's notes
        # mention a 12 dB lowpass before the BBD (MN3009, 256 stages,
        # sampling at about 70 kHz) but no cutoff; 9 kHz darkens the wet
        # path audibly, as on recordings.  UNVERIFIED.
        BBD_CUTOFF = 9000

        # The BBD flavour's hiss level in dBFS per channel (white noise
        # through the post filter).  An estimate (the Juno-60's chorus hiss
        # is well known but unmeasured here).  UNVERIFIED.
        BBD_HISS = -72

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
        def self.build(input, mode = :juno1, rate: nil, depth: 1, delay: nil, dry: 1, wet: 1, bbd: false, cutoff: nil, hiss: nil, seed: nil, interpolation: :sinc)
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

          rate ||= settings[:rate]
          times = [half, -half].map { |h| delay_node(rate, center, h, depth, sample_rate) }

          cutoff = BBD_CUTOFF if cutoff.nil? && bbd
          hiss = BBD_HISS if hiss.nil? && bbd

          dry_inputs = input.outputs.map(&:get_sampler)
          mono = count == 1 ? dry_inputs[0] : Channels.new(dry_inputs).mono
          mono = mono.get_sampler
          wet_input = cutoff ? lowpass(mono, cutoff) : mono

          seeds = [seed, seed && seed + 1]
          taps = wet_input.multitap(*times, interpolation: interpolation).to_a
          wets = taps.map.with_index { |tap, idx|
            tap = tap + MB::Sound.noise(seed: seeds[idx]).at(hiss.db).at_rate(sample_rate) if hiss
            tap = lowpass(tap, cutoff) if cutoff
            tap
          }

          dry_l, dry_r = count == 1 ? [mono, mono] : dry_inputs

          outputs = [[dry_l, wets[0], 'L'], [dry_r, wets[1], 'R']].map { |d, w, side|
            mix(d, w, dry, wet).named("Juno chorus #{side}")
          }

          Channels.new(outputs)
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

        # A 12 dB/octave Butterworth lowpass (the BBD's anti-aliasing and
        # reconstruction filters).
        def self.lowpass(node, cutoff)
          node.filter(:lowpass, cutoff: cutoff, quality: Math.sqrt(0.5))
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
        # (:juno_i_ii, :juno_both; 9.75 Hz over 3.3-3.7 ms), the Juno-60's
        # buttons as measured by Pendragon (see Chorus::MODES).
        #
        # Like the Juno, the chorus is mono in: a stereo input's channels are
        # averaged for the delay line, while the dry signal keeps its sides
        # (left dry + left wet, right dry + right wet).  Inputs with more
        # than two channels raise an error.
        #
        # Options (numbers or nodes where noted):
        # +:rate+ - LFO rate overriding the mode's: Hz, a Pitch (`0.5.hz`),
        #           a Duration that follows the tempo (`1.bar`, `1.n16`),
        #           or a node of Hz.
        # +:depth+ - Sweep width as a fraction of the mode's (1 = the
        #            Juno's; a number or node; 0 is a fixed delay).
        # +:delay+ - A Range of delay lengths overriding the mode's sweep
        #            (`2.ms..8.ms`, seconds as plain numbers).
        # +:dry+, +:wet+ - Levels (numbers or nodes), 1 and 1 like the Juno,
        #                  so a mono-compatible sum has up to +6 dB peaks.
        # +:bbd+ - true adds the bucket-brigade flavour: 12 dB/octave
        #          lowpasses before and after the delay (Chorus::BBD_CUTOFF)
        #          and hiss (Chorus::BBD_HISS dBFS).  Off by default (clean).
        # +:cutoff+ - The BBD lowpass cutoff in Hz (also turns the filters on
        #             without bbd: true; may be a node).
        # +:hiss+ - Hiss level in dBFS (also without bbd: true).
        # +:seed+ - Hiss seed (default: sub-seeds from MB::Sound.seed).
        # +:interpolation+ - Delay reads (:sinc default, :cubic, :linear;
        #                    see MB::Sound::DelayLine).
        #
        # Both outputs must be read in turn every buffer (as a Session does)
        # since they share one delay line.
        #
        # Examples (bin/sound.rb):
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus                # mode I
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno2)        # mode II
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno12)       # I+II warble
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno2, bbd: true)  # darker, hissy
        #     bg :pad, 110.hz.ramp.at(-12.db).chorus(rate: 1.bar, depth: 1.5)  # tempo-synced sweep
        def chorus(mode = :juno1, **options)
          MB::Sound::GraphNode::Chorus.build(self, mode, **options)
        end
        alias juno_chorus chorus
      end
    end
  end
end

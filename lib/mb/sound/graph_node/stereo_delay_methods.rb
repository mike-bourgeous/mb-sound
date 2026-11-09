module MB
  module Sound
    module GraphNode
      # Stereo delay effects that take the whole input at once (not run per
      # channel; see ChannelDispatch::EXCLUDED): #ping_pong, #dual_delay,
      # and #haas.
      # Included in GraphNode and Channels.
      module StereoDelayMethods
        # Where #ping_pong sends its input (see #ping_pong).
        PING_PONG_INPUTS = %i[mono stereo].freeze

        # Sides #haas can delay.
        HAAS_SIDES = %i[left right].freeze

        # The quality of the loop cuts (#dual_delay, #ping_pong): 2-pole
        # Butterworth highpass and lowpass.
        CUT_QUALITY = Math.sqrt(0.5)

        # A ping-pong delay: echoes alternate left and right
        # (GraphNode::DelayNetwork).  Two lines feed each other: echoes
        # alternate left, right, left, ..., +time+ apart, each +feedback+ times
        # the one before.  Returns a stereo bundle of the dry signal plus the
        # echoes.
        #
        # +time+ is any delay time (seconds, `250.ms`, `1.n8.dotted` following
        # the tempo, a node); +:feedback+ a number or node (-1..1 decays;
        # negative flips every other echo's polarity).
        #
        # +:input+ :mono (default) sums a stereo input's sides into the left
        # line (the first echo is on the left, as on most hardware), :stereo
        # sends left into the left line and right into the right one (each
        # side's echoes bounce across).  The dry signal keeps its sides.
        #
        # +:spread+ is the echoes' stereo width: 1 (default) hard left and
        # right, 0 every echo in the middle, between them a narrower bounce
        # (ChannelMixer::Width; a number or node).
        #
        # +:dry+ and +:wet+ are levels (default 1 and 1); +:mix+ crossfades
        # them at equal power (dry * sqrt(1 - mix), wet * sqrt(mix), as
        # #delay's +:mix+ and `blend(curve: :power)`; delays-2, the
        # maintainer's "Equal power", 2026-10-30).  Numbers or nodes.
        # +:smooth+ and +:interpolation+ are as for #delay.
        #
        # +:low_cut+ and +:high_cut+ (Hz, numbers; nil for none) put a 2-pole
        # highpass and lowpass in the loop, so each echo is thinner and
        # darker than the last (delay-dual-1; DelayNetwork's +:filters+).
        #
        # The echoes ring out after the input ends (see DelayNetwork).
        #
        # Examples (bin/sound.rb):
        #     play file_input('sounds/drums.flac').ping_pong(1.n8, feedback: 0.6)
        #     play keys.ping_pong(3.n16, feedback: 0.5, spread: 0.7, mix: 0.3)
        #     play pad.ping_pong(1.n4, feedback: 0.4, input: :stereo)
        #     play keys.ping_pong(3.n16, feedback: 0.7, low_cut: 300, high_cut: 2500)
        def ping_pong(time = 1.n8, feedback: 0.5, spread: 1, dry: 1, wet: 1, mix: nil, input: :mono, low_cut: nil, high_cut: nil, smooth: true, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION)
          unless PING_PONG_INPUTS.include?(input)
            raise ArgumentError, "ping_pong input: is #{PING_PONG_INPUTS.map(&:inspect).join(' or ')} (got #{input.inspect})"
          end
          DelayMethods.check_plain_time(time)

          l, r = StereoDelayMethods.sides(self, 'ping_pong')
          smoothing = DelayMethods.smooth_keyword(smooth, nil, true)
          cuts = StereoDelayMethods.cut_filters(low_cut, high_cut, l.sample_rate, 'ping_pong')

          if input == :stereo && !l.equal?(r)
            inputs = [l, r]
          else
            inputs = [l.equal?(r) ? l : (l + r) * 0.5, nil]
          end

          # Each line gets the other's echo times +feedback+: the mono form
          # bounces the left echo across (each echo +feedback+ times the one
          # before), the stereo form also feeds the right input in
          net = DelayNetwork.new(
            inputs: inputs,
            taps: [[0, time], [1, time]],
            gains: [[nil, feedback], [feedback, nil]],
            filters: cuts && [cuts, cuts.map(&:dup)],
            smoothing: smoothing, interpolation: interpolation, initial_buffer: 0.5
          )

          echoes = Channels.new(net.taps)
          echoes = echoes.width(spread) unless spread.is_a?(Numeric) && spread == 1

          StereoDelayMethods.wet_dry([l, r], echoes.outputs, dry: dry, wet: wet, mix: mix)
        end
        alias pingpong ping_pong

        # A dual delay: two delay lines with their own times, feedback, and cuts.
        # (The dB-T tempo delay's form; delay-dual-1.)  Each line has its
        # own time, feedback, level, cuts in the loop, and pan.  A form of
        # GraphNode::DelayNetwork (two lines, each tap feeding its own line,
        # loop filters on the taps), not a second delay engine.  Returns a
        # stereo bundle of the dry signal plus the echoes.
        #
        # +left+ and +right+ are the two delay times (seconds, `250.ms`,
        # `3.n16` following the tempo, a node).  Options taking one value
        # for both sides or `[left, right]`:
        # +:feedback+ - each line's repeat gain (a number or node; -1..1
        #   decays)
        # +:level+ - each side's echo level (a number or node)
        # +:low_cut+, +:high_cut+ - Hz (numbers, nil for none): a 2-pole
        #   Butterworth highpass and lowpass each trip around the loop
        #   passes once, so repeats get thinner and darker
        #
        # +:pan+ is `[left position, right position]` (-1..1 each, numbers
        # or nodes; default hard left and right) with +:pan_law+ (a stereo
        # law of Channels#balance; default :balance_0db, the dB-T's: the
        # near side at full level, the far side at 1 - |position|).
        #
        # +:input+ :mono (default) feeds both lines the input (a stereo
        # input's average), :stereo the left input into the left line and
        # the right into the right one.  The dry signal keeps its sides.
        #
        # +:dry+ and +:wet+ are levels (default 1 and 1); +:mix+ (0..1)
        # crossfades them by +:mix_law+: :power (default, equal power, as
        # every delay's +:mix+), :linear, or :balance (both at full level
        # at 0.5, the other side falling to 0 toward each end: the dB-T's
        # one mix knob, its -100..100 read as mix = (knob + 100) / 200).
        # +:smooth+ and +:interpolation+ are as for #delay.
        #
        # The echoes ring out after the input ends (see DelayNetwork).
        #
        # Examples (bin/sound.rb):
        #     play keys.dual_delay(3.n16, 5.n16, feedback: 0.4, low_cut: 80, high_cut: 10_000)
        #     play gtr.dual_delay(1.n8.dotted, 1.n4, feedback: [0.5, 0.3], level: [1, 0.7], pan: [-0.6, 0.6], mix: 0.35)
        #     play pad.dual_delay(0.31, 0.47, input: :stereo, high_cut: 3000, mix: 0.5, mix_law: :balance)
        def dual_delay(left = 3.n16, right = 5.n16, feedback: 0.4, level: 1, low_cut: nil, high_cut: nil, pan: [-1, 1], pan_law: :balance_0db,
                       dry: 1, wet: 1, mix: nil, mix_law: :power, input: :mono, smooth: true, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION)
          unless PING_PONG_INPUTS.include?(input)
            raise ArgumentError, "dual_delay input: is #{PING_PONG_INPUTS.map(&:inspect).join(' or ')} (got #{input.inspect})"
          end
          unless BlendMethods::CURVES.include?(mix_law)
            raise ArgumentError, "dual_delay mix_law: is #{BlendMethods::CURVES.map(&:inspect).join(', ')} (got #{mix_law.inspect})"
          end
          unless ChannelMixer::PanLaws::STEREO_LAWS.include?(pan_law)
            raise ArgumentError, "dual_delay pan_law: is #{ChannelMixer::PanLaws::STEREO_LAWS.map(&:inspect).join(', ')} (got #{pan_law.inspect})"
          end
          unless pan.is_a?(Array) && pan.length == 2
            raise ArgumentError, "dual_delay pan: is [left position, right position] (got #{pan.inspect})"
          end
          DelayMethods.check_plain_time(left)
          DelayMethods.check_plain_time(right)

          fbs = StereoDelayMethods.per_side(feedback, :feedback)
          levels = StereoDelayMethods.per_side(level, :level)
          lows = StereoDelayMethods.per_side(low_cut, :low_cut)
          highs = StereoDelayMethods.per_side(high_cut, :high_cut)

          l, r = StereoDelayMethods.sides(self, 'dual_delay')
          smoothing = DelayMethods.smooth_keyword(smooth, nil, true)
          inputs = input == :stereo && !l.equal?(r) ? [l, r] : [l.equal?(r) ? l : (l + r) * 0.5] * 2
          filters = 2.times.map { |t| StereoDelayMethods.cut_filters(lows[t], highs[t], l.sample_rate, 'dual_delay') }

          net = DelayNetwork.new(
            inputs: inputs,
            taps: [[0, left], [1, right]],
            gains: [[fbs[0], nil], [nil, fbs[1]]],
            filters: filters,
            smoothing: smoothing, interpolation: interpolation, initial_buffer: 0.5
          )

          wet_sides = StereoDelayMethods.pan_echoes(net.taps, levels, pan, pan_law)
          StereoDelayMethods.wet_dry([l, r], wet_sides, dry: dry, wet: wet, mix: mix, law: mix_law)
        end
        alias stereo_delay dual_delay

        # A Haas (precedence effect) widener: one side delayed a few
        # milliseconds.  A mono sound spreads out while it still seems to come
        # from the undelayed side.  Returns a stereo bundle (a stereo input
        # keeps its other side as it is).
        #
        # +time+ is the delay (default 15 ms; about 1-35 ms fuses into one
        # sound, longer ones are heard as an echo), +:side+ :right (default)
        # or :left, +:level+ the delayed side's gain (a number or node).
        #
        # Check mono compatibility: the sum of the two sides is a comb filter.
        #
        # Example (bin/sound.rb):
        #     play 220.hz.saw.at(-20.db).filter(:lowpass, cutoff: 2000).haas(12.ms)
        def haas(time = 15.ms, side: :right, level: 1)
          raise ArgumentError, "haas side: is :left or :right (got #{side.inspect})" unless HAAS_SIDES.include?(side)
          DelayMethods.check_plain_time(time)

          l, r = StereoDelayMethods.sides(self, 'haas')
          # (the undelayed side reads through its own branch, since a mono
          # input feeds both sides)
          if side == :right
            r = r.delay(time)
            r = r * level unless level.is_a?(Numeric) && level == 1
            l = l.get_sampler
          else
            l = l.delay(time)
            l = l * level unless level.is_a?(Numeric) && level == 1
            r = r.get_sampler
          end
          Channels.new([l, r])
        end

        # A tape echo (GraphNode::TapeEcho): repeats run through a tape sim each
        # pass.  Wow and flutter, a highpass and a lowpass, and saturation on
        # every pass, one sample at a time in a feedback loop.  +preset+ is
        # :reel (default; warm 3/16 echoes), :slapback (one 110 ms slap),
        # :ping_pong (repeats bouncing left and right; stereo out), or :dub
        # (dark, saturated dotted quarters ringing on), or a :delay preset from
        # a library shelf (`L.fx.delay`); options override it:
        #
        # +:time+ - echo time (seconds, `250.ms`, `1.n8.dotted`, a node)
        # +:feedback+ - repeat gain (above 1 the saturation holds it up)
        # +:mix+ - dry/wet crossfade, 0..1 (as #chorus)
        # +:tone+ - the loop's lowpass cutoff in Hz (darker below)
        # +:low_cut+ - the loop's highpass cutoff in Hz
        # +:drive+ - saturation drive (0 clean)
        # +:wow+, +:flutter+ - delay wobble depths in ms (slow random drift,
        #   6.5 Hz sine)
        # +:stereo+ - :mono (one tape per input channel) or :ping_pong
        # +:spread+ - the ping-pong's echo width (1 hard left and right)
        # +:seed+ - the wow drift's seed (default: drawn from MB::Sound.seed)
        #
        # Every value setting (+:time+, +:feedback+, +:mix+, +:tone+,
        # +:low_cut+, +:drive+, +:wow+, +:flutter+) also takes a node, so a
        # bound knob turns it without a rebuild (delays-2; a +:drive+ node
        # at 0 is nearly clean, see TapeEcho::MIN_LIVE_DRIVE).
        #
        # Examples (bin/sound.rb):
        #     play keys.tape_echo                       # :reel
        #     play keys.tape_echo(:dub, feedback: 0.8)
        #     play drums.tape_echo(:ping_pong, time: 3.n16, mix: 0.25)
        #     play vox.tape_echo(:slapback)
        def tape_echo(preset = :reel, seed: nil, **options)
          TapeEcho.build(self, preset, seed: seed, **options)
        end

        # [left, right] of +node+ (a mono node or one-channel bundle twice,
        # a stereo bundle's channels); raises for more channels.
        def self.sides(node, method)
          outs = node.is_a?(Channels) ? node.outputs : (node.respond_to?(:outputs) && node.channel_count > 1 ? node.outputs : [node])
          case outs.length
          when 1 then [outs[0], outs[0]]
          when 2 then outs
          else
            raise ArgumentError, "#{method} takes a mono or stereo input (got #{outs.length} channels)"
          end
        end

        # Stereo dry + wet: +dry_sides+ and +wet_sides+ (two nodes each),
        # with +dry+/+wet+ levels and an optional +mix+ crossfade (see
        # #ping_pong and DelayMethods.mix_levels).  The sums ring on after
        # the dry signal ends.
        def self.wet_dry(dry_sides, wet_sides, dry:, wet:, mix:, law: :power)
          dg, wg = DelayMethods.mix_levels(dry, wet, mix, law: law)

          outs = dry_sides.zip(wet_sides).map { |d, w|
            dd = Chorus.scale(d, dg)
            ww = Chorus.scale(w, wg)
            if dd.nil?
              ww ? (ww.equal?(w) ? w.get_sampler : ww) : w * 0
            elsif ww.nil?
              dd.equal?(d) ? d.get_sampler : dd
            else
              DelayMethods.ring_sum(ww, dd)
            end
          }
          Channels.new(outs)
        end

        # [left, right] of a #dual_delay option: one value for both sides
        # or a two-element Array.
        def self.per_side(value, name)
          return [value, value] unless value.is_a?(Array)
          raise ArgumentError, "dual_delay #{name}: is one value or [left, right] (got #{value.inspect})" unless value.length == 2

          value
        end

        # The loop cuts for +low_cut+ and +high_cut+ (Hz or nil) at +rate+:
        # nil for neither, else an Array of Filter::Cookbook biquads (a
        # 2-pole Butterworth highpass, then lowpass) for DelayNetwork's
        # +:filters+.  Cutoffs are fixed numbers (the network's filters have
        # fixed coefficients).
        def self.cut_filters(low_cut, high_cut, rate, method)
          list = []
          { highpass: [low_cut, :low_cut], lowpass: [high_cut, :high_cut] }.each do |type, (hz, name)|
            next if hz.nil?

            hz = hz.frequency if hz.respond_to?(:frequency) && !hz.respond_to?(:sample)
            unless hz.is_a?(Numeric) && hz.real? && hz > 0 && hz < rate / 2.0
              raise ArgumentError, "#{method} #{name}: is a frequency in Hz between 0 and #{rate / 2.0} (a number, or nil for none; got #{hz.inspect})"
            end
            list << MB::Sound::Filter::Cookbook.new(type, rate, hz.to_f, quality: CUT_QUALITY)
          end
          list.empty? ? nil : list
        end

        # [left, right] wet nodes of #dual_delay: each tap (a mono echo)
        # times its level, placed by its +pan+ position with +law+ (a mono
        # echo on both channels of a stereo law's matrix).  Number positions
        # make one ChannelMixer::Matrix reading both taps (none for hard
        # left and right at level 1), node positions a Balance per echo.
        def self.pan_echoes(taps, levels, pan, law)
          if pan.all? { |p| p.is_a?(Numeric) }
            echoes = taps
            if levels.all? { |v| v.is_a?(Numeric) }
              gains = levels
            else
              echoes = taps.each_with_index.map { |tap, t| Chorus.scale(tap, levels[t]) || tap * 0 }
              gains = [1, 1]
            end
            cols = pan.each_with_index.map { |p, t|
              m = ChannelMixer::PanLaws.stereo(law, p.to_f)
              [(m[0][0] + m[0][1]) * gains[t], (m[1][0] + m[1][1]) * gains[t]]
            }
            matrix = [[cols[0][0], cols[1][0]], [cols[0][1], cols[1][1]]]
            return echoes if matrix == [[1, 0], [0, 1]]

            Channels.new(echoes).matrix(matrix).outputs
          else
            bundles = taps.each_with_index.map { |tap, t|
              e = Chorus.scale(tap, levels[t]) || tap * 0
              e.stereo.balance(pan[t], law: law)
            }
            2.times.map { |side| DelayMethods.ring_sum(bundles[0].outputs[side], bundles[1].outputs[side]) }
          end
        end

        # +level+ times +factor+ (numbers multiply; nodes make a product).
        def self.level_product(level, factor)
          return level * factor if level.is_a?(Numeric) && factor.is_a?(Numeric)
          return factor if level.is_a?(Numeric) && level == 1
          return factor * level if level.is_a?(Numeric)
          level * factor
        end
      end
    end
  end
end

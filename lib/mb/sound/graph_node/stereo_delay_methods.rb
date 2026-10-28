module MB
  module Sound
    module GraphNode
      # Stereo delay effects that take the whole input at once (not run per
      # channel; see ChannelDispatch::EXCLUDED): #ping_pong and #haas.
      # Included in GraphNode and Channels.
      module StereoDelayMethods
        # Where #ping_pong sends its input (see #ping_pong).
        PING_PONG_INPUTS = %i[mono stereo].freeze

        # Sides #haas can delay.
        HAAS_SIDES = %i[left right].freeze

        # A ping-pong delay (a GraphNode::DelayNetwork of two lines feeding
        # each other): echoes alternate left, right, left, ..., +time+
        # apart, each +feedback+ times the one before.  Returns a stereo
        # bundle of the dry signal plus the echoes.
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
        # them as for #chorus (dry * (1 - mix), wet * mix; linear).  Numbers
        # or nodes.  +:smooth+ and +:interpolation+ are as for #delay.
        #
        # The echoes ring out after the input ends (see DelayNetwork).
        #
        # Examples (bin/sound.rb):
        #     play file_input('sounds/drums.flac').ping_pong(1.n8, feedback: 0.6)
        #     play keys.ping_pong(3.n16, feedback: 0.5, spread: 0.7, mix: 0.3)
        #     play pad.ping_pong(1.n4, feedback: 0.4, input: :stereo)
        def ping_pong(time = 1.n8, feedback: 0.5, spread: 1, dry: 1, wet: 1, mix: nil, input: :mono, smooth: true, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION)
          unless PING_PONG_INPUTS.include?(input)
            raise ArgumentError, "ping_pong input: is #{PING_PONG_INPUTS.map(&:inspect).join(' or ')} (got #{input.inspect})"
          end
          DelayMethods.check_plain_time(time)

          l, r = StereoDelayMethods.sides(self, 'ping_pong')
          smoothing = DelayMethods.smooth_keyword(smooth, nil, true)

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
            smoothing: smoothing, interpolation: interpolation, initial_buffer: 0.5
          )

          echoes = Channels.new(net.taps)
          echoes = echoes.width(spread) unless spread.is_a?(Numeric) && spread == 1

          StereoDelayMethods.wet_dry([l, r], echoes.outputs, dry: dry, wet: wet, mix: mix)
        end
        alias pingpong ping_pong

        # A Haas (precedence effect) widener: one side delayed by a few
        # milliseconds, so a mono sound spreads out while it still seems to
        # come from the undelayed side.  Returns a stereo bundle (a stereo
        # input keeps its other side as it is).
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
        # #ping_pong).  The sums ring on after the dry signal ends.
        def self.wet_dry(dry_sides, wet_sides, dry:, wet:, mix:)
          dg = dry
          wg = wet
          unless mix.nil?
            mix = mix.is_a?(Numeric) ? mix.to_f.clamp(0.0, 1.0) : mix.clip(0, 1)
            dg = level_product(dry, 1 - mix)
            wg = level_product(wet, mix)
          end

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

        # +level+ times +factor+ (numbers multiply; nodes make a product).
        def self.level_product(level, factor)
          return level * factor if level.is_a?(Numeric) && factor.is_a?(Numeric)
          return factor * level if level.is_a?(Numeric)
          level * factor
        end
      end
    end
  end
end

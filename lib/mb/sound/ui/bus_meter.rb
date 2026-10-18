module MB
  module Sound
    module UI
      # Levels of one signal over a snapshot's buffers: +peak+ and +rms+
      # (Arrays, dBFS per channel) and +short+ (dBFS: the channels' mean
      # power over about the last BusMeter::SHORT_SECONDS, a VU-like
      # short-term level).
      Levels = Data.define(:peak, :rms, :short) do
        # Levels of silence for +channels+ channels.
        def self.silent(channels)
          inf = Array.new(channels, -Float::INFINITY).freeze
          new(peak: inf, rms: inf, short: -Float::INFINITY)
        end

        # The loudest channel's peak (dBFS).
        def max_peak = peak.max || -Float::INFINITY
      end

      # A bus's levels: what reached it (+input+: main outs routed to it
      # plus sends) and what it gives on (+output+: after its chain and
      # mute).  Both Levels.
      BusLevels = Data.define(:input, :output)

      # One send of a player into a bus: its +gain+ this buffer (dB; minus
      # infinity at 0, nil while it follows a node) and the +level+ of the
      # signal sent (Levels, post-fader and after the send gain).
      SendLevel = Data.define(:player, :bus, :gain, :level)

      # Bus and send meters on the render thread (contract in
      # design/notes/terminal_ui.md, "UI round 4"): Session::Buses calls
      # #bus_input, #bus_output, and #send_signal with buffers it has
      # already computed, #end_span after each span, and the Feed #take's
      # the levels into each snapshot.  One pass over each buffer (a peak
      # and a sum of squares per channel); nothing here allocates per
      # sample beyond Numo's temporaries.  Only used while a visible pane
      # needs :buses.
      class BusMeter
        # Seconds of the short-term level's exponential window.
        SHORT_SECONDS = 0.3

        # Accumulates one signal (see BusMeter).
        class Acc
          attr_reader :channels

          def initialize(channels)
            @channels = channels
            @short = 0.0
            @gain = nil
            reset
          end

          # The latest send gain (linear, or nil while it follows a node).
          attr_accessor :gain

          # The meter's frame count when this signal was last seen.
          attr_accessor :seen

          # Adds +x+ (one channel's SFloat) to channel +c+.
          def add(c, x)
            return if x.nil? || x.empty?
            x = Numo::SFloat.cast(x) unless x.is_a?(Numo::SFloat)
            peak, sumsq = BusMeter.native ? FastLoudness.peak_sumsq(x, 1.0) : BusMeter.peak_sumsq_ruby(x, 1.0)
            @peak[c] = peak if peak > @peak[c]
            @sumsq[c] += sumsq
            @frames[c] += x.length
          end

          # Folds this span's power into the short-term level (+decay+ the
          # window's factor for the span, +count+ frames).
          def end_span(decay, count)
            p = 0.0
            @channels.times { |c| p += @sumsq[c] - @span_sumsq[c] }
            p /= (count * @channels).to_f if count > 0
            @short = @short * decay + p * (1 - decay)
            @span_sumsq = @sumsq.dup
          end

          # The Levels since the last take, starting a new interval.
          def take(frames)
            n = frames.to_f
            levels = Levels.new(
              peak: @peak.map { |v| v > 0 ? 20 * Math.log10(v) : -Float::INFINITY }.freeze,
              rms: @sumsq.map { |s| s > 0 && n > 0 ? 10 * Math.log10(s / n) : -Float::INFINITY }.freeze,
              short: @short > 1e-20 ? 10 * Math.log10(@short) : -Float::INFINITY
            )
            reset
            levels
          end

          private

          def reset
            @peak = Array.new(@channels, 0.0)
            @sumsq = Array.new(@channels, 0.0)
            @span_sumsq = Array.new(@channels, 0.0)
            @frames = Array.new(@channels, 0)
          end
        end

        class << self
          # False to use the Ruby mirror (.peak_sumsq_ruby) instead of
          # FastLoudness.peak_sumsq.
          attr_accessor :native
        end
        self.native = true

        # The exact Ruby mirror of FastLoudness.peak_sumsq: the peak and
        # the sum of squares of SFloat +x+ times +gain+, in double
        # precision, added in order.
        def self.peak_sumsq_ruby(x, gain)
          peak = 0.0
          sumsq = 0.0
          g = gain.to_f
          x.each do |v|
            y = v * g
            a = y.abs
            peak = a if a > peak
            sumsq += y * y
          end
          [peak, sumsq]
        end

        # Signals not seen for this many seconds (a bus removed, a send
        # turned off or gone) are dropped from the snapshots.
        FORGET_SECONDS = 1.0

        attr_reader :channels

        def initialize(channels, sample_rate)
          @channels = channels
          @rate = sample_rate.to_f
          @inputs = {}
          @outputs = {}
          @sends = {}
          @frames = 0
          @clock = 0
        end

        # Bus +name+'s input for the span (an Array of SFloat per channel,
        # or nil when nothing reached it).
        def bus_input(name, input)
          bus_seen(name)
          acc = @inputs[name]
          input&.each_with_index { |x, c| acc.add(c % @channels, x) }
        end

        # Part of bus +name+'s output (after its mute): channel +c+'s
        # samples +x+.
        def bus_output(name, c, x)
          bus_seen(name)
          @outputs[name].add(c % @channels, x)
        end

        # Notes that bus +name+ exists this span (so a sleeping bus reads
        # silence instead of vanishing).
        def bus_seen(name)
          (@inputs[name] ||= Acc.new(@channels)).seen = @clock
          (@outputs[name] ||= Acc.new(@channels)).seen = @clock
        end

        # Part of what +player+ sends into +bus+: channel +c+'s samples +x+,
        # sent with +gain+ (linear, or a node's per-sample values).
        def send_signal(player, bus, c, x, gain)
          send_seen(player, bus, gain).add(c % @channels, x)
        end

        # Notes a send from +player+ into +bus+ at +gain+ (linear, or a
        # node's per-sample values) in this span, also when nothing is sent
        # (gain 0).  Returns its accumulator.
        def send_seen(player, bus, gain)
          acc = ((@sends[player] ||= {})[bus] ||= Acc.new(@channels))
          acc.seen = @clock
          acc.gain = gain.is_a?(Numeric) ? gain.to_f : (gain.respond_to?(:[]) && gain.length > 0 ? gain[-1].to_f : nil)
          acc
        end

        # Ends a span of +count+ frames: folds every signal's power into its
        # short-term level (silent ones decay).
        def end_span(count)
          return if count <= 0
          @frames += count
          @clock += count
          decay = Math.exp(-count / (SHORT_SECONDS * @rate))
          @inputs.each_value { |a| a.end_span(decay, count) }
          @outputs.each_value { |a| a.end_span(decay, count) }
          @sends.each_value { |h| h.each_value { |a| a.end_span(decay, count) } }
        end

        # The levels since the last take: [{ bus => BusLevels }, { [player,
        # bus] => SendLevel }], frozen.  Signals not seen for
        # FORGET_SECONDS (a bus removed, a send gone or at 0) are dropped.
        def take
          n = @frames
          @frames = 0
          old = @clock - FORGET_SECONDS * @rate
          [@inputs, @outputs, *@sends.values].each { |h| h.delete_if { |_, a| a.seen.nil? || a.seen < old } }
          @sends.delete_if { |_, h| h.empty? }

          names = (@inputs.keys | @outputs.keys)
          levels = names.to_h { |name|
            i = @inputs[name] ||= Acc.new(@channels)
            o = @outputs[name] ||= Acc.new(@channels)
            [name, BusLevels.new(input: i.take(n), output: o.take(n))]
          }.freeze
          send_levels = {}
          @sends.each do |player, h|
            h.each do |bus, a|
              g = a.gain
              db = g.nil? ? nil : (g > 0 ? 20 * Math.log10(g) : -Float::INFINITY)
              send_levels[[player, bus].freeze] = SendLevel.new(player: player, bus: bus, gain: db, level: a.take(n))
            end
          end
          send_levels.freeze
          [levels, send_levels]
        end
      end
    end
  end
end

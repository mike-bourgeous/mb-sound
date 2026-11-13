module MB
  module Sound
    # Methods for building multichannel signals, available in bin/sound.rb.
    # See GraphNode::Channels and GraphNode::ChannelDispatch.
    module MultichannelMethods
      # Given graph nodes, returns a bundle of them as separate channels.
      # Given other values (numbers, Durations, ...), returns per-channel
      # values for a DSL method, which then runs once per channel.
      #
      # Examples (bin/sound.rb):
      #     play channels(220.hz.at(0.2), 330.hz.at(0.2), 440.hz.at(0.2))  # Ctrl-C stops
      #     bg 220.hz.saw.at(0.3).delay(channels(0.010, 0.013))   # mono in, stereo out
      def channels(*items)
        items = items[0] if items.length == 1 && items[0].is_a?(Array)
        nodes = items.count { |i| i.is_a?(GraphNode) || i.is_a?(GraphNode::MultiOutput) }

        if nodes == items.length
          GraphNode::Channels.new(items)
        elsif nodes == 0
          GraphNode::ChannelValues.new(items)
        else
          raise ArgumentError, 'Pass either graph nodes (a channel bundle) or plain values (per-channel values), not both'
        end
      end

      # Returns a stereo bundle of +left+ and +right+.
      #
      # Example (bin/sound.rb):
      #     play stereo(220.hz.at(0.2), 221.hz.at(0.2))
      def stereo(left, right)
        GraphNode::Channels.new([left, right])
      end

      # Returns values spread evenly across the channels of a multichannel
      # DSL call (see GraphNode::ChannelSpread).
      #
      # Example (bin/sound.rb):
      #     bg 110.hz.saw.at(0.3).stereo.filter(:lowpass, cutoff: spread(500..900))
      def spread(range)
        GraphNode::ChannelSpread.new(range)
      end

      # Per-channel arguments for a DSL method: a Range spreads evenly across
      # the channels (like #spread), a list of values gives one value per
      # channel (like #channels with plain values), and graph nodes make a
      # bundle (like #channels).  The channel-level sibling of
      # MidiMethods#per_voice.
      #
      # Examples (bin/sound.rb):
      #     bg 110.hz.saw.at(0.3).stereo.filter(:lowpass, cutoff: per_channel(500..900))
      #     bg 220.hz.saw.at(0.3).delay(per_channel(10.ms, 13.ms))   # mono in, stereo out
      def per_channel(*items)
        items = items[0] if items.length == 1 && items[0].is_a?(Array)
        return spread(items[0]) if items.length == 1 && items[0].is_a?(Range)

        channels(*items)
      end

      # Per-band values for a filter bank's band settings (`width:`,
      # `gain:`, `pan:`, ... of #filter_bank, #bandpass_series,
      # #peq_series): a Range spreads across the bands along +curve+ (any
      # MB::Sound::Curve: `:linear`, the default, `:exp`, `:smooth`,
      # `Curve.power(2)`, ...; band i of N gets a + (b - a) curve(i / (N -
      # 1)), or curve(i / N) for an exclusive Range such as `0...1`), and a
      # list gives one value per band, repeating.  Endpoints may be
      # Intervals, Pitches, Decibels, or numbers.  A bare Range given to a
      # band setting is per_harmonic with the linear curve.
      #
      # A tone with +phase:+ and/or +rate:+ gives every band its own copy of
      # the tone (an LFO, e.g. `0.2.hz.lfo` or `4.bars.lfo`), its starting
      # phase moved by +phase+ cycles and its frequency multiplied by +rate+
      # (fixed frequencies only), each one value or per band (a Range, a
      # list, a per_harmonic value), so each band moves on its own: a moving
      # pan across the harmonics.  The band-level sibling of #per_channel and
      # #per_voice (MB::Sound::PerHarmonic).
      #
      # Examples (bin/sound.rb):
      #     play 0.5.hz.saw.at(20).bandpass_series(110, count: 24, width: per_harmonic(15.cents..90.cents, curve: :exp)).softclip(0.9)
      #     play noise.at(0.3).bandpass_series(220, count: 12, width: 20.cents, pan: per_harmonic(-1, 1), normalize: true)
      #     # each band panned by its own LFO, phases spread around the cycle, rates 0.15-0.3 Hz
      #     play noise.at(0.3).bandpass_series(110, count: 24, width: 20.cents, pan: per_harmonic(0.15.hz.lfo, phase: 0...1, rate: 1..2), normalize: true)
      def per_harmonic(*items, curve: nil, phase: nil, rate: nil)
        PerHarmonic.new(*items, curve: curve, phase: phase, rate: rate)
      end
    end
  end
end

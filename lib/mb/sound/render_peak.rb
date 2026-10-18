module MB
  module Sound
    # An output wrapper for PlaybackMethods#render that keeps the highest
    # sample written to the mix file, so a render whose mix went over full
    # scale (clipped in integer formats such as FLAC and WAV, before any
    # loudness: normalization, which can't undo it) can say so, as stems do
    # (Session::Stems::Writer#close).  Everything else goes to the wrapped
    # output.
    #
    # (filters-1, 2026-10-17: a Bench render of lp4 at resonance 0.9 peaked
    # at +10 dBFS, clipped silently in its FLAC, and was then normalized to
    # -18 LUFS with its flat tops.)
    class RenderPeak
      # The wrapped output.
      attr_reader :output

      # The highest absolute sample written so far (linear).
      attr_reader :peak

      def initialize(output)
        @output = output
        @peak = 0.0
      end

      def write(data)
        p = data.map { |c| c.length > 0 ? c.abs.max.to_f : 0.0 }.max || 0.0
        @peak = p if p > @peak || p.nan?
        @output.write(data)
      end

      def sample_rate
        @output.sample_rate
      end

      def close
        @output.close
      end

      # True if a written sample went over full scale.
      def over?
        @peak > 1.0 || @peak.nan?
      end

      # The warning for #over? renders of +name+ at +gain+ (the master gain
      # the render used, linear), or nil: how far over, and the gain: that
      # would leave headroom.
      def warning(name, gain)
        return nil unless over?
        return "Render #{name} has non-finite samples (written as full scale or zero)" if @peak.nan? || @peak.infinite?

        over = 20 * Math.log10(@peak)
        fix = (20 * Math.log10(gain) - over).floor
        "Render #{name} went #{format('%.1f', over)} dB over full scale (clipped in integer formats such as FLAC and WAV, " \
          "before any loudness: normalization); render with gain: #{fix}.db for headroom"
      end

      def respond_to_missing?(name, include_private = false)
        @output.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **kwargs, &block)
        return super unless @output.respond_to?(name)
        @output.public_send(name, *args, **kwargs, &block)
      end
    end
  end
end

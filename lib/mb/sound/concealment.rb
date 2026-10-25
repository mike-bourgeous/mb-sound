module MB
  module Sound
    # Underrun concealment settings for DeviceOutput, and the Ruby reference
    # of the device thread's kernel (ext/mb/sound/fast_audio/mb_conceal.h).
    #
    # When the writer misses a deadline and the output queue runs dry, the
    # device thread plays grains of the last audio it played instead of
    # silence: Hann-like (equal-power) crossfaded grains of jittered lengths
    # (20-60 ms) from jittered positions in the last 120 ms, so there is no
    # fixed repetition period to buzz at, falling 60 dB over a second, then
    # crossfades back (5 ms) when audio arrives.  Late audio is played, not
    # dropped, so the queue and the device clock move as before, and
    # underruns are counted as before (stats[:underruns]); stats[:concealed]
    # and [:concealed_gaps] count what was filled.
    #
    # Settings (DeviceOutput's +:conceal+, or AUDIO_CONCEAL):
    #   :repeat  - the default (DEFAULTS)
    #   :silence - silence while the queue is dry (the old behavior)
    #   :fixed   - loop the latest grain (one fixed length; comparisons only:
    #              it buzzes at rate / length)
    #   { mode: :repeat, grain: 0.02..0.06, history: 0.12, fade: 1.0, ... }
    # AUDIO_CONCEAL is one of the names, optionally with a grain in ms
    # (`repeat:20-60`, `fixed:30`).  Times take seconds or Lengths (`20.ms`).
    module Concealment
      # Seconds, except :seed.  :fade is the time to fall 60 dB (nil: no
      # decay), :quiet_fade the same once the writer marked the end of its
      # audio (DeviceOutput#end_stream), :return_fade the crossfade back to
      # real audio, :match and :search the window and lag range compared when
      # choosing the first grain.
      DEFAULTS = {
        mode: :repeat,
        fixed: false,
        history: 0.12,
        grain_min: 0.02,
        grain_max: 0.06,
        fade: 1.0,
        quiet_fade: 0.02,
        return_fade: 0.005,
        match: 0.001,
        search: 0.01,
        seed: 0x6d62_736f_756e_64,
      }.freeze

      NAMES = %i[repeat silence fixed].freeze

      # Raised for unknown settings.
      class Error < ArgumentError; end

      # The settings Hash (every key of DEFAULTS) for +spec+ (nil for
      # AUDIO_CONCEAL or :repeat; a name from NAMES; a String like
      # AUDIO_CONCEAL's; or a Hash of overrides, with +:grain+ a Range or one
      # length).
      def self.settings(spec = nil)
        spec = ENV['AUDIO_CONCEAL'] if spec.nil? && ENV['AUDIO_CONCEAL'] && !ENV['AUDIO_CONCEAL'].empty?
        spec = parse_string(spec) if spec.is_a?(String)
        spec = :repeat if spec.nil? || spec == true
        spec = :silence if spec == false
        spec = { mode: spec } if spec.is_a?(Symbol)
        raise Error, "Concealment settings must be a name (#{NAMES.join(', ')}) or a Hash (got #{spec.inspect})" unless spec.is_a?(Hash)

        spec = spec.dup
        mode = spec.delete(:mode) || :repeat
        raise Error, "Unknown concealment #{mode.inspect} (#{NAMES.join(', ')})" unless NAMES.include?(mode)

        s = DEFAULTS.dup
        s[:fixed] = true if mode == :fixed
        s[:mode] = mode == :silence ? :silence : :repeat
        if spec.key?(:grain)
          g = spec.delete(:grain)
          lo, hi = g.is_a?(Range) ? [g.begin, g.end] : [g, g]
          s[:grain_min] = seconds(lo)
          s[:grain_max] = seconds(hi)
        end
        spec.each do |k, v|
          raise Error, "Unknown concealment setting #{k.inspect} (#{(DEFAULTS.keys + [:grain]).join(', ')})" unless DEFAULTS.key?(k)
          s[k] = %i[fixed seed].include?(k) || v.nil? ? v : seconds(v)
        end
        s[:grain_max] = s[:grain_min] if s[:fixed]
        check(s)
        s.freeze
      end

      # Seconds from a number or a Length.
      def self.seconds(v)
        return v.to_samples(sample_rate: 48000) / 48000.0 if v.is_a?(Length::Samples)
        Float(v)
      end

      def self.parse_string(str)
        name, grain = str.strip.split(':', 2)
        h = { mode: name.delete_prefix(':').to_sym }
        if grain
          lo, hi = grain.split('-', 2).map { |x| Float(x) / 1000 }
          h[:grain] = hi ? lo..hi : lo
        end
        h
      end

      def self.check(s)
        return if s[:mode] == :silence
        problems = []
        problems << 'grain must be positive' unless s[:grain_min] > 0
        problems << 'grain range must not run backwards' unless s[:grain_max] >= s[:grain_min]
        problems << 'history must hold the longest grain plus :match' unless s[:history] >= s[:grain_max] + s[:match]
        problems << 'history must be at most 2 seconds' unless s[:history] <= 2
        problems << ':return_fade must be positive and at most the history' unless s[:return_fade] > 0 && s[:return_fade] <= s[:history]
        problems << ':match must be positive' unless s[:match] > 0
        problems << ':search must not be negative' unless s[:search] >= 0
        problems << ':fade must be positive or nil' unless s[:fade].nil? || s[:fade] > 0
        raise Error, "Bad concealment settings: #{problems.join('; ')}" unless problems.empty?
      end
      private_class_method :parse_string, :check

      # Plays +audio+ (an Array of channels, or anything Playable through
      # MB::Sound.read-style arrays) through the device thread's concealment
      # with forced gaps, as a sound card would play it: +gaps+ are
      # [start, length] pairs in seconds (of the input) where the writer is
      # late by +length+, so the output is longer by the gaps (late audio is
      # played, not dropped).  +period+ is the device's pull size.  Returns
      # an Array of SFloat channels; for listening to settings, e.g.
      #     play Concealment.simulate(read('x.flac'), gaps: [[1, 0.08]], conceal: :fixed)
      def self.simulate(audio, gaps:, conceal: :repeat, rate: 48000, period: 128)
        audio = Array(audio).map { |c| Numo::SFloat.cast(c) }
        ch = audio.length
        k = FastAudio::Concealer.new(ch, rate, settings(conceal))
        gaps = gaps.map { |at, len| [(seconds(at) * rate).round, (seconds(len) * rate).round] }.sort
        length = audio[0].length
        out = []
        pos = 0
        until pos >= length && gaps.empty?
          if gaps.any? && gaps[0][0] <= pos
            left = gaps[0][1]
            gaps.shift
            while left > 0
              n = [period, left].min
              out << Numo::SFloat.from_binary(k.process('', n, false))
              left -= n
            end
            next
          end

          n = [period, length - pos].min
          n = [n, gaps[0][0] - pos].min if gaps.any?
          m = Numo::SFloat.zeros(n, ch)
          ch.times { |c| m[true, c] = audio[c][pos...(pos + n)] }
          out << Numo::SFloat.from_binary(k.process(m.to_binary, n, false))
          pos += n
        end

        joined = out.empty? ? Numo::SFloat[] : Numo::SFloat.zeros(out.sum(&:length)).tap { |j|
          i = 0
          out.each { |o| j[i...(i + o.length)] = o; i += o.length }
        }
        frames = joined.reshape(true, ch)
        ch.times.map { |c| frames[true, c].dup }
      end

      # The Ruby reference of mb_conceal.h, step for step (same splitmix64
      # draws, same recurrences, float32 history and output), for specs.
      # #process takes one device pull: the real frames the ring had (an
      # Array of per-channel SFloats, possibly empty) and the pull's length,
      # returning an Array of per-channel SFloats.
      class Reference
        MASK = 0xffff_ffff_ffff_ffff
        GOLDEN = 0x9E37_79B9_7F4A_7C15

        Grain = Struct.new(:src, :len, :i)

        attr_reader :frames, :events, :total, :draws

        def initialize(channels, rate, settings)
          s = settings
          @ch = channels
          @mode = s[:mode]
          @fixed = s[:fixed] ? true : false
          @history = to_frames(s[:history], rate)
          @grain_min = [to_frames(s[:grain_min], rate), 2].max
          @grain_max = [to_frames(s[:grain_max], rate), @grain_min].max
          @match_window = to_frames(s[:match], rate)
          @match_search = to_frames(s[:search], rate)
          @exit_frames = to_frames(s[:return_fade], rate)
          fade = s[:fade].to_f
          @decay = fade > 0 ? 10.0**(-3.0 / (fade * rate)) : 1.0
          qf = s[:quiet_fade].to_f
          @quiet_decay = 10.0**(-3.0 / ((qf > 0 ? qf : 1e-3) * rate))
          @floor_gain = 1e-3
          @offset_decay = Math.exp(-1.0 / (0.002 * rate))
          @cur_decay = @decay
          @seed = s[:seed] & MASK
          @draws = 0
          @total = 0
          @frames = 0
          @events = 0

          @active = false
          @faded = false
          @in_exit = false
          @t0 = 0
          @avail = 0
          @gain = 0.0
          @peak = 0.0
          @offset = Array.new(channels, 0.0)
          @cur = Grain.new(0, 0, 0)
          @nxt = Grain.new(0, 0, 0)
          @h = 0
          @h_in = 0
          @in_seam = false
          @j = 0
          @sc = @ss = @scd = @ssd = 0.0
          @xj = 0
          @xc = @xs = @xcd = @xsd = 0.0
          @x = Numo::SFloat.zeros(channels)

          return unless @mode == :repeat

          need = [2 * @history, @history + @exit_frames + 1].max
          @cap = 16
          @cap <<= 1 while @cap < need
          @hist = Numo::SFloat.zeros(@cap, channels)
        end

        def state
          {
            active: @active, faded: @faded, returning: @in_exit, gain: @gain, total: @total, draws: @draws,
            frames: @frames, events: @events, grain: @active ? [@t0 - @cur.src, @cur.len, @cur.i] : nil,
          }
        end

        # See mb_conceal_process.
        def process(real, frames, quiet: false)
          count = real.empty? ? 0 : real[0].length
          raise ArgumentError, 'More real frames than the pull' if count > frames

          out = Numo::SFloat.zeros(frames, @ch)
          @ch.times { |k| out[0...count, k] = real[k] } if count > 0
          return split(out) unless @mode == :repeat

          @cur_decay = quiet ? @quiet_decay : @decay

          if count > 0
            push(out[0...count, true])

            if @active && @total - @t0 > @cap - @history
              @active = false
              @in_exit = false
            end

            i = 0
            while i < count && @active
              unless @in_exit
                d = Math::PI / (2.0 * @exit_frames)
                @in_exit = true
                @xj = 0
                @xc = Math.cos(0.5 * d)
                @xs = Math.sin(0.5 * d)
                @xcd = Math.cos(d)
                @xsd = Math.sin(d)
              end

              frame(@x)
              @ch.times do |k|
                r = out[i, k]
                y = r * @xs + @x[k] * @xc
                lim = r.abs > @peak ? r.abs : @peak
                y = lim if y > lim
                y = -lim if y < -lim
                out[i, k] = y
              end

              @xc, @xs = rotate(@xc, @xs, @xcd, @xsd)
              @xj += 1
              if @xj >= @exit_frames
                @active = false
                @in_exit = false
              end
              i += 1
            end
          end

          return split(out) if count >= frames

          if @active
            @in_exit = false
          elsif quiet || !enter
            return split(out)
          end

          (count...frames).each do |i|
            frame(@x)
            out[i, true] = @x
          end
          @frames += frames - count
          split(out)
        end

        private

        def split(out)
          @ch.times.map { |k| out[true, k].dup }
        end

        def to_frames(seconds, rate)
          f = (seconds * rate).round
          f < 1 ? 1 : f
        end

        def at(pos, k)
          @hist[pos & (@cap - 1), k]
        end

        def push(frames)
          n = frames.shape[0]
          if n > @cap
            frames = frames[(n - @cap)..., true]
            @total += n - @cap
            n = @cap
          end
          n.times do |i|
            @hist[(@total + i) & (@cap - 1), true] = frames[i, true]
          end
          @total += n
        end

        def pick(lo, hi)
          @draws += 1
          z = (@seed + @draws * GOLDEN) & MASK
          z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
          z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
          z ^= z >> 31
          return lo if hi <= lo
          lo + z % (hi - lo + 1)
        end

        def choose_next
          g = @nxt
          if @fixed
            g.len = [@grain_min, @avail].min
            g.src = @t0 - g.len
          else
            max = [@grain_max, @avail].min
            g.len = pick(@grain_min, max)
            g.src = @t0 - pick(g.len, @avail)
          end
          g.i = 0

          room = @cur.len - @h_in
          half = g.len / 2
          h = [room, half].min
          @h = h < 1 ? 1 : h
          @in_seam = false
        end

        def rotate(c, s, cd, sd)
          [c * cd - s * sd, s * cd + c * sd]
        end

        def frame(out)
          if @faded
            out.fill(0)
            return
          end

          if !@in_seam && @cur.i + @h >= @cur.len
            d = Math::PI / (2.0 * @h)
            @in_seam = true
            @j = 0
            @sc = Math.cos(0.5 * d)
            @ss = Math.sin(0.5 * d)
            @scd = Math.cos(d)
            @ssd = Math.sin(d)
          end

          @ch.times do |k|
            v = at(@cur.src + @cur.i, k)
            v = v * @sc + at(@nxt.src + @nxt.i, k) * @ss if @in_seam
            y = @gain * v + @offset[k]
            y = @peak if y > @peak
            y = -@peak if y < -@peak
            out[k] = y
            @offset[k] *= @offset_decay
          end

          @cur.i += 1
          if @in_seam
            @nxt.i += 1
            @j += 1
            @sc, @ss = rotate(@sc, @ss, @scd, @ssd)
            if @j >= @h
              @cur, @nxt = @nxt, @cur
              @h_in = @h
              choose_next
            end
          end

          @gain *= @cur_decay
          if @gain < @floor_gain
            @gain = 0.0
            @faded = true
          end
        end

        def enter
          avail = [@total, @history].min
          w = @match_window
          return false if avail < @grain_min + w

          @t0 = @total
          @avail = avail

          if @fixed
            len = @grain_min
            d = len
          else
            lo = @grain_min
            hi = [lo + @match_search, avail - w].min
            best = lo
            best_err = Float::INFINITY
            (lo..hi).each do |dd|
              e = 0.0
              jj = 1
              while jj <= w && e < best_err
                @ch.times do |k|
                  a = at(@t0 - jj, k) - at(@t0 - dd - jj, k)
                  e += a * a
                end
                jj += 1
              end
              if e < best_err
                best_err = e
                best = dd
              end
            end
            d = best
            len = pick(@grain_min, [@grain_max, d].min)
          end

          @cur.src = @t0 - d
          @cur.len = len
          @cur.i = 0
          @h_in = 0
          @ch.times do |k|
            @offset[k] = at(@t0 - 1, k) - at(@cur.src - 1, k)
          end
          @peak = 0.0
          (@t0 - avail...@t0).each do |pos|
            @ch.times do |k|
              a = at(pos, k).abs
              @peak = a if a > @peak
            end
          end
          @gain = 1.0
          @faded = false
          @active = true
          @in_exit = false
          @events += 1
          choose_next
          true
        end
      end
    end
  end
end

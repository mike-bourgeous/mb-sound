module MB
  module Sound
    # Underrun concealment settings for DeviceOutput, and the Ruby reference
    # of the device thread's kernel (ext/mb/sound/fast_audio/mb_conceal.h).
    #
    # When the writer misses a deadline and the output queue runs dry, the
    # device thread plays grains of the last audio it played instead of
    # silence: crossfaded grains of jittered lengths (20-60 ms) from jittered
    # positions in the last 120 ms, so there is no fixed repetition period to
    # buzz at, each moved a little to cross the one before it in phase, no
    # louder than 6 dB over the 20 ms before the gap, holding their level for
    # 100 ms (:hold) and then falling 60 dB over a second.  When audio
    # arrives, the grains land on it: they cross (5 ms) into a last grain
    # ending where the late audio starts, which then continues it sample
    # for sample (audio-safety-2: crossfading straight into the late audio
    # met it at an unrelated phase, and pops and chirps came from that and
    # from returns cut short).  Late audio is played, not dropped, so the
    # device clock moves as before, the queued audio plays in order (5-17 ms
    # later for the landing), and underruns are counted as before
    # (stats[:underruns]); stats[:concealed] and [:concealed_gaps] count what
    # was filled.
    #
    # Settings (DeviceOutput's +:conceal+, or AUDIO_CONCEAL):
    #   :repeat  - grains (DEFAULTS; the default, see DEFAULT)
    #   :silence - silence while the queue is dry (the old behavior)
    #   :fixed   - loop the latest grain (one fixed length; comparisons only:
    #              it buzzes at rate / length)
    #   { mode: :repeat, grain: 0.02..0.06, history: 0.12, hold: 0.1, fade: 1.0, ... }
    # AUDIO_CONCEAL is one of the names, optionally with a grain in ms
    # (`repeat:20-60`, `fixed:30`).  Times take seconds or Lengths (`20.ms`).
    module Concealment
      # Seconds, except :seed.  :hold is the time at full level before the
      # decay, :fade the time to fall 60 dB after it (nil: no decay),
      # :quiet_fade the same (without the hold) once the writer marked the
      # end of its audio (DeviceOutput#end_stream), :return_fade the seam
      # into the last grain of the landing (at most the shortest grain), :match and :search the window and lag range compared when
      # choosing the first grain, :align how far each later grain may move
      # to cross the one before it in phase (0: not at all), :level the dB a
      # grain may be over the level of the 20 ms before the gap (nil: no
      # cap; audio-safety-2).
      DEFAULTS = {
        mode: :repeat,
        fixed: false,
        history: 0.12,
        grain_min: 0.02,
        grain_max: 0.06,
        hold: 0.1,
        fade: 1.0,
        quiet_fade: 0.02,
        return_fade: 0.005,
        match: 0.001,
        search: 0.01,
        align: 0.006,
        level: 6.0,
        seed: 0x6d62_736f_756e_64,
      }.freeze

      NAMES = %i[repeat silence fixed].freeze

      # What DeviceOutput plays in an underrun without +:conceal+ or
      # AUDIO_CONCEAL: jittered grains (the maintainer's Bench verdict on
      # audio-safety-1, 2026-10-25: they won for house, ambient, and acid).
      # Specs counting frames through underruns pass conceal: :silence.
      DEFAULT = :repeat

      # Raised for unknown settings.
      class Error < ArgumentError; end

      # The settings Hash (every key of DEFAULTS) for +spec+ (nil for
      # AUDIO_CONCEAL or DEFAULT; true for :repeat; a name from NAMES; a String like
      # AUDIO_CONCEAL's; or a Hash of overrides, with +:grain+ a Range or one
      # length).
      def self.settings(spec = nil)
        spec = ENV['AUDIO_CONCEAL'] if spec.nil? && ENV['AUDIO_CONCEAL'] && !ENV['AUDIO_CONCEAL'].empty?
        spec = parse_string(spec) if spec.is_a?(String)
        spec = DEFAULT if spec.nil?
        spec = :repeat if spec == true
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
          s[k] = %i[fixed seed].include?(k) || v.nil? ? v : k == :level ? Float(v) : seconds(v)
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
        problems << ':hold must not be negative' unless s[:hold] >= 0
        problems << ':align must be 0 to 50 ms' unless s[:align] && s[:align] >= 0 && s[:align] <= 0.05
        problems << ':level must be a number of dB or nil' unless s[:level].nil? || s[:level].finite?
        raise Error, "Bad concealment settings: #{problems.join('; ')}" unless problems.empty?
      end
      private_class_method :parse_string, :check

      # Plays +audio+ (an Array of channels, or anything Playable through
      # MB::Sound.read-style arrays) through the device thread's concealment
      # with forced gaps, as a sound card would play it: +gaps+ are
      # [start, length] pairs in seconds (of the input) where the writer is
      # late by +length+, so the output is longer by the gaps (late audio is
      # played, not dropped), and then catches up.  +period+ is the
      # device's pull size.  Returns an Array of SFloat channels; for
      # listening to settings, e.g.
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
              out << Numo::SFloat.from_binary(k.pull('', n, false)[0])
              left -= n
            end
            next
          end

          # What the queue holds: up to the next gap (the writer caught up)
          n = [period, length - pos].min
          n = [n, gaps[0][0] - pos].min if gaps.any?
          q = [length - pos, period + 4800].min
          q = [q, gaps[0][0] - pos].min if gaps.any?
          m = Numo::SFloat.zeros(q, ch)
          ch.times { |c| m[true, c] = audio[c][pos...(pos + q)] }
          played, taken = k.pull(m.to_binary, n, false)
          out << Numo::SFloat.from_binary(played)
          pos += taken
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
      # #pull takes one device pull as Playback makes it: everything the
      # ring holds (an Array of per-channel SFloats, possibly empty) and the
      # pull's length, returning the pull's channels and how many queued
      # frames it took.
      class Reference
        MASK = 0xffff_ffff_ffff_ffff
        GOLDEN = 0x9E37_79B9_7F4A_7C15

        Grain = Struct.new(:src, :len, :i, :g)

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
          @land_frames = [to_frames(s[:return_fade], rate), @grain_min].min
          @align_search = s[:align].to_f > 0 ? (s[:align] * rate).round : 0
          @align_window = to_frames(0.001, rate)
          @level_ratio = s[:level].nil? ? 0 : 10.0**(s[:level] / 20.0)
          @ref_rms = 0.0
          @hold_frames = s[:hold].to_f > 0 ? (s[:hold] * rate).round : 0
          @held = 0
          @quiet = false
          fade = s[:fade].to_f
          @decay = fade > 0 ? 10.0**(-3.0 / (fade * rate)) : 1.0
          qf = s[:quiet_fade].to_f
          @quiet_decay = 10.0**(-3.0 / ((qf > 0 ? qf : 1e-3) * rate))
          @floor_gain = 1e-3
          @offset_decay = Math.exp(-1.0 / (0.002 * rate))
          @bend_decay = Math.exp(-1.0 / (0.00025 * rate))
          @cur_decay = @decay
          @seed = s[:seed] & MASK
          @draws = 0
          @total = 0
          @frames = 0
          @events = 0

          @active = false
          @faded = false
          @landing = 0
          @land_left = 0
          @t0 = 0
          @avail = 0
          @gain = 0.0
          @peak = 0.0
          @offset = Array.new(channels, 0.0)
          @bend = Array.new(channels, 0.0)
          @bend_u = Array.new(channels, 0.0)
          @cur = Grain.new(0, 0, 0, 1.0)
          @nxt = Grain.new(0, 0, 0, 1.0)
          @fin = Grain.new(0, 0, 0, 1.0)
          @fin_rho = 0.0
          @h = 0
          @h_in = 0
          @in_seam = false
          @j = 0
          @sc = @ss = @scd = @ssd = 0.0
          @rho = 0.0
          @x = Numo::SFloat.zeros(channels)

          return unless @mode == :repeat

          @cap = 16
          @cap <<= 1 while @cap < 2 * @history
          @hist = Numo::SFloat.zeros(@cap, channels)
        end

        def state
          {
            active: @active, faded: @faded, landing: @landing, land_left: @land_left, gain: @gain, total: @total, draws: @draws,
            frames: @frames, events: @events, grain: @active ? [@t0 - @cur.src, @cur.len, @cur.i] : nil,
          }
        end

        # See mb_conceal_take.
        def take(available, frames)
          return [available, frames].min if @mode != :repeat || !@active
          if @landing == LAND_NONE
            return 0 if available == 0
            land
          end
          return 0 if @land_left >= frames
          [available, frames - @land_left].min
        end

        # One pull (see FastAudio::Concealer#pull): +queued+ is everything
        # the ring holds.  Returns the pull's channels and the frames taken.
        def pull(queued, frames, quiet: false)
          available = queued.empty? ? 0 : queued[0].length
          count = take(available, frames)
          [process(count > 0 ? queued.map { |c| c[0...count] } : [], frames, quiet: quiet), count]
        end

        # See mb_conceal_process (+real+: what #take took).
        def process(real, frames, quiet: false)
          count = real.empty? ? 0 : real[0].length
          raise ArgumentError, 'More real frames than the pull' if count > frames

          out = Numo::SFloat.zeros(frames, @ch)
          return split_real(out, real, 0, count) unless @mode == :repeat

          @cur_decay = quiet ? @quiet_decay : @decay
          @quiet = quiet ? true : false

          @active = false if @active && @landing == LAND_NONE && count > 0

          done = 0
          if @active && @landing != LAND_NONE
            r = [@land_left, frames].min
            while done < r
              frame(@x)
              out[done, true] = @x
              done += 1
            end
          end
          concealed = done

          if count > 0
            @ch.times { |k| out[done...(done + count), k] = real[k] }
            push(out[done...(done + count), true])
            done += count
          end

          if done < frames && (@active || (!quiet && enter))
            (done...frames).each do |i|
              frame(@x)
              out[i, true] = @x
            end
            concealed += frames - done
          end
          @frames += concealed
          split(out)
        end

        LAND_NONE = 0
        LAND_NEXT = 1
        LAND_LAST = 2
        LAND_AFTER = 3

        private

        def split_real(out, real, at, count)
          @ch.times { |k| out[at...(at + count), k] = real[k] } if count > 0
          split(out)
        end

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

        # See mb_conceal_gain.
        def grain_gain(g)
          return 1.0 if @level_ratio <= 0
          step = (g.len + 255) / 256
          sum = 0.0
          n = 0
          j = 0
          while j < g.len
            @ch.times do |k|
              a = at(g.src + j, k)
              sum += a * a
            end
            n += 1
            j += step
          end
          rms = Math.sqrt(sum / (n * @ch))
          cap = @ref_rms * @level_ratio
          rms > cap ? cap / rms : 1.0
        end

        # See mb_conceal_err.
        def err(a, b, w, limit)
          e = 0.0
          jj = 0
          while jj < w && e < limit
            @ch.times do |k|
              d = at(a + jj, k) - at(b + jj, k)
              e += d * d
            end
            jj += 1
          end
          e
        end

        # See mb_conceal_best.
        def best(at_cur, from, to, off, w)
          best = from
          best_err = Float::INFINITY
          (from..to).step(2) do |src|
            e = err(at_cur, src + off, w, best_err)
            if e < best_err
              best_err = e
              best = src
            end
          end
          coarse = best
          [-1, 1].each do |side|
            next if (side < 0 && coarse == from) || (side > 0 && coarse == to)
            src = coarse + side
            e = err(at_cur, src + off, w, best_err)
            if e < best_err
              best_err = e
              best = src
            end
          end
          best
        end

        # See mb_conceal_align.
        def align
          g = @nxt
          w = [@align_window, @h].min
          off = (@h - w) / 2
          at_cur = @cur.src + (@cur.len - @h) + off
          lo = @t0 - @avail
          hi = @t0 - g.len
          s = @align_search
          from = g.src > lo + s ? g.src - s : lo
          to = g.src + s < hi ? g.src + s : hi
          g.src = best(at_cur, from, to, off, w)
        end

        # See mb_conceal_seam_rho.
        def seam_rho
          rho_at(@cur.src + (@cur.len - @h), @nxt.src, @h)
        end

        # See mb_conceal_rho.
        def rho_at(a0, b0, h)
          step = (h + 255) / 256
          sxy = sxx = syy = 0.0
          j = 0
          while j < h
            @ch.times do |k|
              a = at(a0 + j, k)
              b = at(b0 + j, k)
              sxy += a * b
              sxx += a * a
              syy += b * b
            end
            j += step
          end
          return 0.0 unless sxx > 0 && syy > 0
          (sxy / Math.sqrt(sxx * syy)).clamp(0.0, 1.0)
        end

        # See mb_conceal_seam.
        def seam(half)
          room = @cur.len - @h_in
          h = [room, half].min
          @h = h < 1 ? 1 : h
          @in_seam = false
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
          seam(g.len / 2)

          if @fixed
            g.g = 1.0
            @rho = 0.0
            return
          end
          align if @align_search > 0
          @rho = seam_rho
          g.g = grain_gain(g)
        end

        CEILING = 1.1220184543019633

        # See mb_conceal_limit.
        def limit(y, peak)
          a = y.abs
          return y if a <= peak
          top = peak * CEILING
          top = peak > 1.0 ? peak : 1.0 if top > 1.0
          room = top - peak
          return y < 0 ? -peak : peak unless room > 0
          l = peak + room * Math.tanh((a - peak) / room)
          y < 0 ? -l : l
        end

        def rotate(c, s, cd, sd)
          [c * cd - s * sd, s * cd + c * sd]
        end

        def frame(out)
          if @faded
            out.fill(0)
            return
          end

          if @landing != LAND_NONE
            f = @landing == LAND_LAST ? @cur : @landing == LAND_NEXT ? @nxt : @fin
            if @land_left <= 1
              @gain = 1.0
              f.g = 1.0
              @ch.times { |k| @offset[k] = @bend[k] = @bend_u[k] = 0.0 }
            else
              n = @land_left.to_f
              @gain += (1 - @gain) / n
              f.g += (1 - f.g) / n
              @ch.times do |k|
                @offset[k] -= @offset[k] / n
                @bend[k] -= @bend[k] / n
                @bend_u[k] -= @bend_u[k] / n
              end
            end
          end

          if !@in_seam && @landing != LAND_LAST && @cur.i + @h >= @cur.len
            d = Math::PI / (2.0 * @h)
            @in_seam = true
            @j = 0
            @sc = Math.cos(0.5 * d)
            @ss = Math.sin(0.5 * d)
            @scd = Math.cos(d)
            @ssd = Math.sin(d)
          end

          sg = @in_seam ? 1.0 / Math.sqrt(1.0 + 2.0 * @rho * @sc * @ss) : 1.0
          @ch.times do |k|
            v = at(@cur.src + @cur.i, k) * @cur.g
            v = (v * @sc + at(@nxt.src + @nxt.i, k) * @nxt.g * @ss) * sg if @in_seam
            out[k] = limit(@gain * v + @offset[k] + @bend[k], @peak)
            @offset[k] *= @offset_decay
            @bend[k] = (@bend[k] + @bend_u[k]) * @bend_decay
            @bend_u[k] *= @bend_decay
          end

          @cur.i += 1
          if @in_seam
            @nxt.i += 1
            @j += 1
            @sc, @ss = rotate(@sc, @ss, @scd, @ssd)
            if @j >= @h
              @cur, @nxt = @nxt, @cur
              @h_in = @h
              @in_seam = false
              if @landing == LAND_NEXT
                @landing = LAND_LAST
              elsif @landing == LAND_AFTER
                @cur.len = @cur.i + @land_frames
                @nxt.src, @nxt.len, @nxt.i, @nxt.g = @fin.src, @fin.len, @fin.i, @fin.g
                @h = @land_frames
                @rho = @fin_rho
                @landing = LAND_NEXT
              else
                choose_next
              end
            end
          end

          if @landing != LAND_NONE
            @land_left -= 1
            if @land_left == 0
              @active = false
              @landing = LAND_NONE
            end
            return
          end

          if @held < @hold_frames && !@quiet
            @held += 1
          else
            @gain *= @cur_decay
          end
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

          sum = 0.0
          (@t0 - @grain_min...@t0).each do |pos|
            @ch.times do |k|
              a = at(pos, k)
              sum += a * a
            end
          end
          @ref_rms = Math.sqrt(sum / (@grain_min * @ch))
          @cur.g = @fixed ? 1.0 : grain_gain(@cur)

          @ch.times do |k|
            x1 = at(@t0 - 1, k)
            x2 = at(@t0 - 2, k)
            h0 = at(@cur.src, k)
            h1 = at(@cur.src - 1, k)
            @offset[k] = x1 - h1 * @cur.g
            ds = (x1 - x2) - (h0 - h1) * @cur.g
            sq = 0.0
            (1..w).each do |jj|
              d = at(@t0 - jj, k) - 2.0 * at(@t0 - jj - 1, k) + at(@t0 - jj - 2, k)
              sq += d * d
            end
            excess = ds.abs - 2.0 * Math.sqrt(sq / w)
            b = excess > 0 ? (ds < 0 ? -excess : excess) : 0.0
            @bend[k] = b
            @bend_u[k] = b
          end
          @peak = 0.0
          (@t0 - avail...@t0).each do |pos|
            @ch.times do |k|
              a = at(pos, k).abs
              @peak = a if a > @peak
            end
          end
          @gain = 1.0
          @held = 0
          @faded = false
          @active = true
          @landing = LAND_NONE
          @events += 1
          choose_next
          true
        end

        # See mb_conceal_last_grain: [grain, rho].
        def last_grain(pos)
          hs = @land_frames
          to = @t0 - hs - 1
          lo = @t0 - @avail
          span = 2 * @align_search
          from = to > lo + span ? to - span : lo
          w = [@align_window, hs].min
          off = (hs - w) / 2
          src = @align_search > 0 && !@fixed ? best(pos + off, from, to, off, w) : to
          g = Grain.new(src, @t0 - src, 0, 1.0)
          [g, @fixed ? 0.0 : rho_at(pos, g.src, hs)]
        end

        # See mb_conceal_land.
        def land
          hs = @land_frames
          if @faded
            @faded = false
            @gain = 0.0
            @in_seam = false
          end

          if @in_seam
            pos = @nxt.src + @h
            if pos + hs >= @t0
              @nxt.len = @t0 - @nxt.src
              @landing = LAND_NEXT
              @land_left = @nxt.len - @nxt.i
              return
            end
            @fin, @fin_rho = last_grain(pos)
            @landing = LAND_AFTER
            @land_left = (@h - @j) + @fin.len
            return
          end

          pos = @cur.src + @cur.i
          if pos + hs >= @t0
            @cur.len = @t0 - @cur.src
            @landing = LAND_LAST
            @land_left = @cur.len - @cur.i
            return
          end

          @cur.len = @cur.i + hs
          g, @rho = last_grain(pos)
          @nxt.src, @nxt.len, @nxt.i, @nxt.g = g.src, g.len, g.i, g.g
          @h = hs
          @landing = LAND_NEXT
          @land_left = @nxt.len
        end
      end
    end
  end
end

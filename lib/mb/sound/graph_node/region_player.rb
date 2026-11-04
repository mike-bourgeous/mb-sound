require_relative '../sequence/timeline_node'

module MB
  module Sound
    module GraphNode
      # One channel of a lane of audio regions on the timeline (regions-1;
      # made by SamplerMethods#regions; see MB::Sound::Region and
      # design/notes/regions.md): each region plays its sample's channel
      # from its offset (source time) when the timeline reaches its start,
      # for its length, at its gain and speed (+transpose+ semitones,
      # varispeed), through its fades; overlapping regions add (an overlap
      # with fades is a crossfade).
      #
      # Positions follow the transport (whole notes; Lengths in seconds
      # convert at the tempo where the player starts); a region's audio
      # plays at its own rate, and its length in frames is fixed when it
      # starts.  A seek or launch landing inside a region (#start_at) starts
      # it on the source sample an uninterrupted run plays there.  +align+
      # :timeline (default) places regions from bar 1; :launch from the
      # graph's launch.  Silent while the timeline is paused; never ends
      # (like a looping clip: `until`).
      #
      # The same samples at any buffer size: each started region keeps an
      # integer frame count and the exact fraction of a frame its start
      # fell after a frame (a Rational), so every frame's source position
      # is computed the same way whatever buffer holds it.  Speed-1 regions
      # of samples at the output rate read whole source samples (the
      # region's first source sample on the first frame at or after its
      # start; offsets rounded to whole samples, as ACID's renderer does);
      # other speeds read Catmull-Rom interpolated positions (no
      # band-limiting; transposing up aliases a little).  Fades follow
      # ACID's renderer (research/acd-format/acd/audio_render.rb): frame e
      # of a fade-in of n frames has gain curve((e + 0.5) / n), and a
      # fade-out's frames before the end gain 1 - curve(x) the same way.
      #
      # A plan boundary.
      class RegionPlayer
        include GraphNode
        include SampleRateHelper
        include Sequence::TimelineNode
        node_traits memory: :short, timeline: true, fresh: 'it finds its place in every region from the timeline in a rebuilt graph'

        ALIGNS = [:timeline, :launch].freeze

        # Zeros around each source's data, so interpolated reads near and
        # past its ends read silence.
        PAD = 4

        # A region resolved for playing (see #resolve): start and length
        # (whole notes; length nil to the source's end), fades (whole notes
        # or nil), source offset (samples), speed (source samples per output
        # frame), gain, curves, and the padded data.
        Resolved = Struct.new(:at, :length, :fade_in, :fade_out, :offset, :ratio, :unit, :gain, :curve_in, :curve_out, :data, :size)

        # A playing region: +k+ whole frames since its first frame, and its
        # frame position then, +f+ (a Rational in 0...1, as a Float +ff+);
        # +n+ its length in frames (Rational; nil to the source's end),
        # +n_int+ and +r_frac+ for frames left (n - k - f = (n_int - k) +
        # r_frac), +frames+ its whole frames (ceil(n - f), nil to the
        # source's end); fade lengths in frames.
        Playing = Struct.new(:k, :f, :ff, :n, :n_int, :r_frac, :frames, :fade_in, :fade_out)

        # The regions (MB::Sound::Region values), in the order given.
        attr_reader :regions

        # The channel of each sample played (modulo its channel count).
        attr_reader :channel

        # :timeline or :launch (see the class description).
        attr_reader :align

        # +regions+ are MB::Sound::Region values or `regions(...)` rows.
        # +data+ may share the samples' channel data between players (a
        # Hash, filled as needed).
        def initialize(regions, channel: 0, align: :timeline, transport: nil, sample_rate: 48000, data: nil)
          raise ArgumentError, "align: is one of #{ALIGNS.inspect} (got #{align.inspect})" unless ALIGNS.include?(align)
          @regions = regions.map { |r| MB::Sound::Region.row(r) }.freeze
          @channel = Integer(channel)
          @align = align
          @transport = transport
          @sample_rate = sample_rate.to_f
          data ||= {}
          @data = @regions.map { |r|
            s = r.sample
            data[[s.audio.object_id, s.start, s.stop, s.reversed?, s.level, @channel % s.channel_count]] ||= padded(s.data(@channel % s.channel_count))
          }.freeze
          @resolved = nil
          @playing = Array.new(@regions.length)
          @pos = nil
          @zero = 0r
          @buf = nil
          @fade = nil
          @timeline_paused = nil
          @timeline_launch = nil
          @node_type_name = 'RegionPlayer'
        end

        def sample_rate=(rate)
          return if rate.to_f == @sample_rate
          @sample_rate = rate.to_f
          @resolved = nil
        end

        def sample(count)
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          BufferHelper.zero(@buf)
          return @buf if timeline_paused?

          resolve if @resolved.nil?
          @pos ||= 0r
          step = transport.whole_notes_per_frame(@sample_rate)
          pos_end = @pos + step * count
          i = 0
          while i < @resolved.length
            r = @resolved[i]
            p = @playing[i]
            if p.nil?
              a = r.at
              if a >= @pos && a < pos_end
                j0 = ((a - @pos) / step).ceil
                if j0 < count
                  p = @playing[i] = playing(r, 0, j0 - (a - @pos) / step, step)
                  render(i, r, p, j0, count)
                end
              end
            elsif p != :done
              render(i, r, p, 0, count)
            end
            i += 1
          end
          @pos = pos_end
          @buf
        end

        def sources
          {}
        end

        def plan_unsupported_reason
          'region players are a plan boundary for now'
        end

        def to_s
          "RegionPlayer (#{@regions.length} region#{'s' unless @regions.length == 1}#{", from launch" if @align == :launch}#{" ch#{@channel}" if @channel > 0})"
        end

        private

        # The resolved regions (see Resolved) at the transport's tempo now.
        def resolve
          t = transport
          @resolved = @regions.each_with_index.map { |r, i|
            s = r.sample
            data = @data[i]
            ratio = 2.0**(r.transpose.to_f / 12) * s.sample_rate / @sample_rate
            unit = ratio == 1.0
            off = r.offset_seconds * s.sample_rate
            Resolved.new(
              MB::Sound::Region.whole_notes(r.at, t, @sample_rate) + @zero, MB::Sound::Region.whole_notes(r.length, t, @sample_rate),
              MB::Sound::Region.whole_notes(r.fade_in, t, @sample_rate), MB::Sound::Region.whole_notes(r.fade_out, t, @sample_rate),
              unit ? off.round.to_f : off.to_f, ratio, unit, r.gain_value, MB::Sound::Curve.from(r.curve_in), MB::Sound::Curve.from(r.curve_out),
              data, data.length - 2 * PAD
            )
          }.freeze
        end

        # A Playing state for region +r+ at +k+ whole frames after its
        # first frame, which fell +f+ (a Rational in 0...1) of a frame after
        # its start, at +step+ whole notes per frame.
        def playing(r, k, f, step)
          n = r.length && r.length / step
          n_int = n&.floor
          # (speed-1 regions read whole samples from their first frame on,
          # so their reads and fade-ins count from that frame: ff 0; their
          # end stays where the timeline says)
          Playing.new(
            k, f, r.unit ? 0.0 : f.to_f, n, n_int, n && (n - n_int - f).to_f, n && (n - f).ceil,
            r.fade_in && (r.fade_in / step).to_f, r.fade_out && (r.fade_out / step).to_f
          )
        end

        # Adds region +i+'s frames from +j0+ to the end of the block (or of
        # the region) to the output.  (Steady regions allocate nothing: the
        # reads and gains go through Kernels.accumulate; fades and
        # interpolated reads make a few arrays.)
        def render(i, r, p, j0, count)
          m = count - j0
          left = p.frames && p.frames - p.k
          m = left if left && left < m
          src = r.offset + (p.k + p.ff) * r.ratio # (ff is 0 for speed-1 reads)
          src_left = ((r.size - src) / r.ratio).ceil
          ended = m >= (left && left < src_left ? left : src_left)
          m = src_left if src_left < m
          if m <= 0
            @playing[i] = :done
            return
          end

          fade = fade_gains(r, p, m)
          if r.unit
            s = (r.offset + p.k).to_i + PAD
            a = s < 0 ? 0 : s
            b = s + m
            b = r.data.length if b > r.data.length
            add(j0 + (a - s), r.data, a, b - a, r.gain, fade, a - s) if b > a
          else
            add(j0, read_cubic(r, p, m), 0, m, r.gain, fade, 0)
          end

          p.k += m
          @playing[i] = :done if ended
        end

        # Adds +length+ samples of +data+ from +doff+, times +gain+ and
        # +fade+ (nil or an SFloat from +foff+), to the output from +oo+.
        def add(oo, data, doff, length, gain, fade, foff)
          return if Kernels.accumulate(@buf, oo, data, doff, length, gain, 0, fade, foff)

          d = data[doff...(doff + length)] * gain
          d = d * fade[foff...(foff + length)] if fade
          @buf[oo...(oo + length)] = @buf[oo...(oo + length)] + d
        end

        # +m+ Catmull-Rom reads at the region's positions (an SFloat).
        def read_cubic(r, p, m)
          pos = ((Numo::DFloat.new(m).seq + p.k) + p.ff) * r.ratio + (r.offset + PAD)
          x = r.data
          last = x.length - 1
          i = pos.floor
          t = pos - i
          i = Numo::Int64.cast(i)
          x0 = Numo::DFloat.cast(x[(i - 1).clip(0, last)])
          x1 = Numo::DFloat.cast(x[i.clip(0, last)])
          x2 = Numo::DFloat.cast(x[(i + 1).clip(0, last)])
          x3 = Numo::DFloat.cast(x[(i + 2).clip(0, last)])
          a = -0.5 * x0 + 1.5 * x1 - 1.5 * x2 + 0.5 * x3
          b = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3
          c = -0.5 * x0 + 0.5 * x2
          Numo::SFloat.cast(((a * t + b) * t + c) * t + x1)
        end

        # The fades' gains over the region's next +m+ frames: nil outside
        # fades, else an SFloat (a scratch buffer reused each block) of at
        # least +m+.  Only the frames inside a fade are computed, each from
        # its exact frame count since the region's start (so the same
        # gains whatever block holds a frame).
        def fade_gains(r, p, m)
          jin = 0
          if p.fade_in && p.k + p.ff < p.fade_in
            # (frames j with ((k + j) + ff + 0.5) / fade_in < 1)
            jin = (p.fade_in - 0.5 - p.ff - p.k).ceil
            jin = m if jin > m
            jin = 0 if jin < 0
          end
          jout = m
          if p.fade_out
            # (frames left at block frame j: r_end - j; the fade-out covers
            # those with left <= fade_out)
            r_end = p.n ? (p.n_int - p.k) + p.r_frac : (r.size - (r.offset + (p.k + p.ff) * r.ratio)) / r.ratio
            jout = (r_end - p.fade_out).ceil
            jout = m if jout > m
            jout = 0 if jout < 0
          end
          return nil if jin == 0 && jout >= m

          @fade = Numo::SFloat.zeros(m) if @fade.nil? || @fade.length < m
          g = @fade
          Kernels.fill_range(g, 0, m, 1.0) or g[0...m] = 1.0
          if jin > 0
            x = Numo::DFloat.new(jin).seq(p.k)
            x.inplace + (p.ff + 0.5)
            x.inplace / p.fade_in
            g[0...jin] = r.curve_in.map(x)
          end
          if jout < m
            n = m - jout
            if p.n
              left = Numo::DFloat.new(n).seq(p.n_int - p.k - jout, -1)
              left.inplace + p.r_frac
            else
              left = Numo::DFloat.new(n).seq(p.k + jout)
              left.inplace + p.ff
              left.inplace * r.ratio
              left.inplace + r.offset
              left = (r.size - left) / r.ratio
            end
            x = (p.fade_out - left + 0.5) / p.fade_out
            x.inplace.clip(0.0, 1.0)
            fo = r.curve_out.map(x)
            g[jout...m] = g[jout...m] * (1.0 - fo)
          end
          g
        end

        # +d+ with PAD zeros on both sides.
        def padded(d)
          out = Numo::SFloat.zeros(d.length + 2 * PAD)
          out[PAD...(PAD + d.length)] = d
          out
        end

        def timeline_start(time, _origin)
          @pos = time
          @zero = @align == :launch ? (timeline_launch || time) : 0r
          resolve
          step = transport.whole_notes_per_frame(@sample_rate)
          @resolved.each_with_index do |r, i|
            @playing[i] = nil
            next if r.at > time
            if r.length && time >= r.at + r.length
              @playing[i] = :done
              next
            end

            e = (time - r.at) / step
            k = e.floor
            @playing[i] = playing(r, k, e - k, step)
          end
        end
      end
    end
  end
end

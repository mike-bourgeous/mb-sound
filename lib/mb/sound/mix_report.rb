module MB
  module Sound
    # A per-track mix report of a render (`render(report: :tracks)`; see
    # PlaybackMethods#render): for each track (its stem: the part as it
    # enters the master chain, times the master gain, with its share of any
    # buses; see Session::Stems) and for the mix (after the master chain),
    # the integrated loudness (LUFS), short-term maximum (LUFS), true peak
    # (dBTP), and peak-to-loudness ratio (PLR, LU: the true peak minus the
    # integrated loudness, EBU R 128 s2's measure of short-scale dynamics;
    # the integrated loudness is BS.1770-gated, so silence and quiet
    # stretches don't count), measured with Loudness::Analyzer; and, when a song form played, the integrated
    # loudness of each track and the mix in every section pass (from the
    # frame where the pass starts, as launches land), with the mix's sample
    # peak.
    #
    #     render 'song.flac', bars: 64, report: :tracks { my_song }
    #     MB::Sound::MixReport.last.tracks[:bass].integrated
    class MixReport
      # One row: +name+ (a track's stem name, or :mix), +integrated+ and
      # +short_term_max+ (LUFS), +true_peak+ (dBTP), +plr+ (LU, the true
      # peak minus the integrated loudness; nil for silence), and +seconds+
      # measured.
      Row = Data.define(:name, :integrated, :short_term_max, :true_peak, :plr, :seconds)

      # One section pass: +label+ (the section's name, with the pass number
      # after the first), +start+ (seconds from the start of the report),
      # +seconds+, and the integrated loudness (LUFS) by name (tracks and
      # :mix) in +loudness+, and the mix's sample +peak+ (dBFS).
      Section = Data.define(:label, :start, :seconds, :loudness, :peak)

      class << self
        # The report of the last render made with +report:+ (nil before).
        attr_accessor :last
      end

      # The track rows by name (Symbols of the stem names), in the order
      # tracks first played.
      attr_reader :tracks

      # The mix's Row.
      attr_reader :mix

      # The Sections (empty without a song form).
      attr_reader :sections

      # Decoded true peaks of lossy encodes of the rendered file ({ codec
      # => dBTP }; see Mastering.codec_peaks), when the render wrote a file.
      attr_accessor :codec_peaks

      # The render's Mastering::Targeting::Result, when a mastering preset
      # set its loudness.
      attr_accessor :mastering

      def initialize(tracks, mix, sections)
        @tracks = tracks.freeze
        @mix = mix
        @sections = sections.freeze
        @codec_peaks = nil
        @mastering = nil
      end

      # The report as plain-text tables.
      def to_s
        lines = []
        rows = @tracks.values + [@mix]
        width = [rows.map { |r| r.name.to_s.length }.max, 5].max
        lines << format("%-#{width}s  %9s  %9s  %8s  %6s", 'Track', 'LUFS', 'ST max', 'dBTP', 'PLR')
        rows.each do |r|
          lines << '' if r.equal?(@mix)
          lines << format("%-#{width}s  %9s  %9s  %8s  %6s", r.name, num(r.integrated), num(r.short_term_max), num(r.true_peak), num(r.plr))
        end

        unless @sections.empty?
          names = @tracks.keys
          label_width = [@sections.map { |s| s.label.length }.max, 7].max
          cols = names.map { |n| [n.to_s.length, 7].max }
          lines << ''
          head = format("%-#{label_width}s  %7s  %7s  %7s", 'Section', 'Start', 'Mix', 'Peak')
          names.each_with_index { |n, i| head << format("  %#{cols[i]}s", n) }
          lines << head
          @sections.each do |s|
            line = format("%-#{label_width}s  %7s  %7s  %7s", s.label, format('%.1f', s.start), num(s.loudness[:mix]), num(s.peak))
            names.each_with_index { |n, i| line << format("  %#{cols[i]}s", num(s.loudness[n])) }
            lines << line
          end
        end

        if @mastering
          lines << ''
          lines << @mastering.to_s
        elsif @codec_peaks
          lines << ''
          lines << "Decoded true peaks: #{@codec_peaks.map { |c, tp| format('%s %.2f', c, tp) }.join(', ')} dBTP"
          overs = @codec_peaks.select { |_c, tp| tp > Mastering::Targeting::CODEC_LIMIT }
          unless overs.empty?
            lines << format('  over %.1f dBTP: players clip them; lower the true-peak ceiling by about %.1f dB', Mastering::Targeting::CODEC_LIMIT, overs.values.max - Mastering::Targeting::CODEC_LIMIT + 0.1)
          end
        end

        lines.join("\n")
      end

      def inspect
        "#<#{self.class.name} #{@tracks.length} tracks, #{@sections.length} sections, mix #{num(@mix.integrated)} LUFS>"
      end

      # A Hash of the report (Floats rounded to 0.01, silence as nil).
      def to_h
        fix = ->(v) { v.is_a?(Float) ? (v.finite? ? v.round(2) : nil) : v }
        row = ->(r) { r.to_h.transform_values(&fix) }
        {
          tracks: @tracks.transform_values(&row),
          mix: row.(@mix),
          sections: @sections.map { |s| s.to_h.merge(loudness: s.loudness.transform_values(&fix), peak: fix.(s.peak)) },
          codec_peaks: @codec_peaks&.transform_values(&fix),
          mastering: @mastering && @mastering.to_h.except(:target, :trim, :ceiling).merge(
            target: @mastering.target.lufs, trim: @mastering.trim.db_value, ceiling: @mastering.ceiling.db_value
          ).transform_values(&fix),
        }
      end

      private

      def num(v)
        return '-' if v.nil?
        v.finite? ? format('%.1f', v) : '-inf'
      end

      # The stem sink a report renders through (Session#stems=): measures
      # every track's part of each span and, through #mix_tap, the mix,
      # passing parts on to a Stems::Writer when stems are written too.
      class Meter
        # The Stems::Writer also receiving the parts, or nil.
        attr_reader :writer

        # +session+ is the rendering Session (for its sample rate, transport,
        # and song form), +writer+ a Stems::Writer or nil.
        def initialize(session, writer: nil)
          @session = session
          @writer = writer
          @origin = 0
          @rate = session.output.sample_rate.to_f
          @tracks = {}
          @boundaries = [] # [frame, label]
          @seen = nil
          @passes = Hash.new(0)
          @section_meters = {}
          @mix = nil
          @mix_section = nil
        end

        # Writes bus returns too (the writer's setting; see Stems::Writer).
        def buses
          @writer ? @writer.buses : false
        end

        # The session frame where measuring (and writing stems) starts.
        attr_reader :origin

        def origin=(frame)
          @origin = frame
          @writer.origin = frame if @writer
        end

        # A track's part of a span (see Stems::Writer#add).
        def add(name, data, frame)
          @writer&.add(name, data, frame)
          note_sections(frame, data[0].length)
          data, frame = trim(data, frame)
          return unless data

          (@tracks[name.to_sym] ||= Track.new(name.to_sym, data.length, @rate)).add(data)
          each_section_piece(data, frame) { |piece, idx| section_meter(idx, name.to_sym, data.length).process(piece) }
        end

        # The mix of a buffer (a Session tap; +frame+ is its first frame).
        def mix_tap(mix, frame)
          data, frame = trim(mix, frame)
          return unless data

          (@mix ||= Track.new(:mix, data.length, @rate)).add(data)
          each_section_piece(data, frame) do |piece, idx|
            section_meter(idx, :mix, data.length).process(piece)
            peak = piece.map { |c| c.abs.max }.max.to_f
            @section_peaks ||= Hash.new(0.0)
            @section_peaks[idx] = peak if peak > @section_peaks[idx]
          end
        end

        def close(frames)
          @writer&.close(frames)
        end

        # The MixReport.
        def report
          mix = (@mix || Track.new(:mix, 1, @rate)).row
          sections = @boundaries.each_with_index.filter_map { |(frame, label), idx|
            nxt = @boundaries[idx + 1]&.first
            stop = nxt || @end_frame || frame
            next if stop <= @origin
            start = [frame, @origin].max
            loud = (@section_meters[idx] || {}).transform_values(&:integrated)
            Section.new(label: label, start: (start - @origin) / @rate, seconds: (stop - start) / @rate, loudness: loud,
                        peak: @section_peaks&.key?(idx) ? 20 * Math.log10(@section_peaks[idx]) : -Float::INFINITY)
          }
          MixReport.new(@tracks.transform_values(&:row), mix, sections)
        end

        # Notes where the render ended (for the last section's length).
        def finish(frame)
          @end_frame = frame
        end

        private

        # Drops the part of +data+ before #origin.  Returns [data, frame],
        # or nil when nothing is left.
        def trim(data, frame)
          return [data, frame] if frame >= @origin
          skip = @origin - frame
          return nil if skip >= data[0].length
          [data.map { |d| d[skip..] }, @origin]
        end

        # Looks for a new section pass of the song form (known half a bar
        # before it starts) and notes the frame where it starts in the span
        # at +frame+ (the frame holding its position, where launches land).
        def note_sections(frame, count)
          pb = @session.arrangement.playback
          return unless pb && pb.section && pb.pass_start

          key = [pb.section, pb.pass_start]
          if key != @seen
            @seen = key
            @pending = key
          end
          return unless @pending

          name, pos = @pending
          t = @session.transport
          per_sample = t.whole_notes_per_second / @rate.to_r
          k = ((pos - t.position) / per_sample).floor
          return if k >= count # (not in this span yet)

          @pending = nil
          @passes[name] += 1
          label = @passes[name] == 1 ? name.to_s : "#{name} #{@passes[name]}"
          @boundaries << [frame + [k, 0].max, label]
        end

        # Yields the pieces of +data+ (at +frame+) in each section pass,
        # with the pass's index.
        def each_section_piece(data, frame)
          return if @boundaries.empty?

          n = data[0].length
          idx = @boundaries.rindex { |f, _| f <= frame }
          pos = 0
          loop do
            nxt = @boundaries[(idx || -1) + 1]&.first
            stop = nxt && nxt < frame + n ? nxt - frame : n
            yield data.map { |d| d[pos...stop] }, idx if idx && stop > pos
            break if stop >= n
            pos = stop
            idx = (idx || -1) + 1
          end
        end

        def section_meter(idx, name, channels)
          (@section_meters[idx] ||= {})[name] ||= Loudness::Analyzer.new(channels: channels, sample_rate: @rate, true_peak: false)
        end
      end

      # The measurements of one track or the mix (see Meter).
      class Track
        def initialize(name, channels, rate)
          @name = name
          @rate = rate
          @analyzer = Loudness::Analyzer.new(channels: channels, sample_rate: rate)
          @samples = 0
        end

        def add(data)
          @analyzer.process(data)
          @samples += data[0].length
        end

        def row
          r = @analyzer.result
          plr = r.integrated.finite? && r.true_peak&.finite? ? r.true_peak - r.integrated : nil
          Row.new(name: @name, integrated: r.integrated, short_term_max: r.short_term_max, true_peak: r.true_peak, plr: plr, seconds: @samples / @rate)
        end
      end
    end
  end
end

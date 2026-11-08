require 'prism'

module MB
  module Sound
    module BarStats
      # The sidecar file of a Report: readable Ruby beside the audio file
      # ("song.flac" -> "song.flac.bar_stats.rb"), one call per line, read
      # back by walking its Prism tree (RubyValue.literal), never run.
      #
      #     # mb-sound bar statistics of song.flac (BarStats.load reads it; never run)
      #     bar_stats 1, file: "song.flac", digest: "sha256:...", bytes: 31415926, mb_sound: "0.0.1", made: "2026-11-08T12:00:00Z"
      #     settings sample_rate: 48000.0, bands: [150.0, 2000.0], octaves: [31.5, ...], ...
      #     grid :render, tempo: 140.0, duration: 180.2
      #     bar 1, 0.0, 4, 1.714286
      #     section "A", 1, 8, 0.0, 13.714286
      #     loudness integrated: -14.2, range: 5.1, true_peak: -1.0, ..., targets: { ebu_r128: false, ... }
      #     table :beats, [:bar, :beat, :seconds, :length, :onset_low, ...]
      #     row 1, 1, 0.0, 0.428571, -0.31, ...
      #     table :bars, [...]
      #     ...
      #     stem :drums, "song_stems/drums.flac"
      #
      # Staleness: a sidecar is fresh for a file while its +digest+ (the
      # file's SHA-256) and +bar_stats+ format number match and its
      # settings answer the same request (grid options, sections, window);
      # BarStats.analyze(path, cache: true) reads a fresh one instead of
      # measuring again.
      module Sidecar
        # The sidecar format number (bump on any change to what's written).
        FORMAT = 1

        # The extension added to the audio file's name.
        EXTENSION = '.bar_stats.rb'

        module_function

        # The sidecar path of audio file +file+.
        def path(file) = "#{file}#{EXTENSION}"

        # "sha256:<hex>" of +file+'s bytes.
        def digest(file) = "sha256:#{Digest::SHA256.file(file).hexdigest}"

        # The text of +report+'s sidecar (+base+: the directory paths are
        # written relative to).
        def write(report, base: nil)
          v = ->(x) { RubyValue.to_ruby(x) }
          rel = ->(f) { base && f ? relative(f, base) : f }
          src = report.source
          out = []
          out << "# mb-sound bar statistics of #{src[:file] ? File.basename(src[:file]) : 'audio data'} (MB::Sound::BarStats.load reads it; never run)"
          head = { file: rel.(src[:file]), digest: src[:digest], bytes: src[:bytes], mb_sound: MB::Sound::VERSION, made: src[:made] || Time.now.utc.iso8601 }
          out << "bar_stats #{FORMAT}, #{RubyValue.kwargs(head.compact) { |x| v.(x) }}"
          out << "settings #{RubyValue.kwargs(report.settings) { |x| v.(x) }}"
          g = report.grid
          out << "grid #{v.(g.source)}, tempo: #{v.(g.tempo)}, duration: #{v.(g.duration)}"
          g.bars.each { |b| out << "bar #{[b.number, b.seconds.round(6), b.beats, b.end_seconds.round(6)].map(&v).join(', ')}" }
          g.sections.each { |s| out << "section #{[s.label, s.first_bar, s.bars, s.seconds.round(6), s.end_seconds.round(6)].map(&v).join(', ')}" }
          out << "loudness #{RubyValue.kwargs(report.broadcast.to_h) { |x| v.(x) }}" if report.broadcast
          [report.beats, report.bars, report.sections, report.song].each do |t|
            next if t.level == :song && t.length == 0
            key_names = { beats: %i[bar beat], bars: %i[bar], sections: %i[section], song: [] }.fetch(t.level)
            out << "table #{v.(t.level)}, #{v.(key_names + t.names)}"
            t.length.times do |i|
              key = t.keys[i]
              keys = t.level == :beats ? key : t.level == :song ? [] : [key]
              cells = keys + t.names.map { |name| Table.value(t[name], i) }
              out << (cells.empty? ? 'row' : "row #{cells.map(&v).join(', ')}")
            end
          end
          report.stems.each { |name, r| out << "stem #{v.(name.to_sym)}, #{v.(rel.(r.file))}" }
          out.join("\n") + "\n"
        end

        # +file+ relative to +base+ when it's inside it, else absolute.
        def relative(file, base)
          f = File.expand_path(file)
          b = File.expand_path(base)
          f.start_with?("#{b}/") ? f.delete_prefix("#{b}/") : f
        end

        # Reads sidecar +path+ into a Report (stems read from their own
        # sidecars when fresh, else left out).  Raises ArgumentError for
        # anything but the calls above with plain values.
        def read(path)
          text = File.read(path)
          tree = Prism.parse(text)
          raise ArgumentError, "#{path}: #{tree.errors.first.message}" unless tree.errors.empty?

          base = File.dirname(path)
          head = nil
          settings = {}
          grid = nil
          bars = []
          sections = []
          loud = nil
          tables = {}
          current = nil
          stems = {}
          tree.value.statements.body.each do |st|
            raise ArgumentError, "#{path}: not a sidecar line: #{st.slice[0, 60]}" unless st.is_a?(Prism::CallNode) && st.receiver.nil? && st.block.nil?
            args = (st.arguments&.arguments || []).map { |a| RubyValue.literal(a) }
            kw = args.last.is_a?(Hash) && st.arguments.arguments.last.is_a?(Prism::KeywordHashNode) ? args.pop : {}
            case st.name
            when :bar_stats
              raise ArgumentError, "#{path}: sidecar format #{args[0].inspect}, not #{FORMAT}" unless args[0] == FORMAT
              head = kw
            when :settings then settings = kw
            when :grid then grid = { source: args[0], tempo: kw[:tempo], duration: kw[:duration] }
            when :bar then bars << args
            when :section then sections << args
            when :loudness then loud = kw
            when :table
              current = tables[args[0]] = { names: args[1], rows: [] }
            when :row
              raise ArgumentError, "#{path}: row before a table" unless current
              current[:rows] << args
            when :stem then stems[args[0]] = args[1] && File.expand_path(args[1], base)
            else
              raise ArgumentError, "#{path}: unknown sidecar call #{st.name}"
            end
          end
          raise ArgumentError, "#{path}: not a bar statistics sidecar" unless head && grid

          made = tables.to_h { |level, t| [level, table(level, t[:names], t[:rows])] }
          beat_table = made[:beats] || Table.new(:beats, [], {})
          beat_list = beat_table.keys.each_with_index.map { |(b, bt), i| [beat_table[:seconds][i], b, bt] }
          g = Grid.from_h(grid.merge(beats: beat_list, bars: bars, sections: sections))
          broadcast = loud && Broadcast.new(**loud.except(:targets), targets: (loud[:targets] || {}).keys)
          file = head[:file] && File.expand_path(head[:file], base)
          stem_reports = stems.filter_map { |name, f|
            sp = f && path(f)
            [name, read(sp)] if sp && File.file?(sp)
          }.to_h
          Report.new(grid: g, beats: beat_table, bars: made[:bars] || Table.new(:bars, [], {}),
                     sections: made[:sections] || Table.new(:sections, [], {}), song: made[:song] || Table.new(:song, [], {}),
                     broadcast: broadcast, settings: settings,
                     source: { file: file, digest: head[:digest], bytes: head[:bytes], made: head[:made], mb_sound: head[:mb_sound] }, stems: stem_reports)
        end

        # A Table from a sidecar's column names (keys first) and rows.
        def table(level, names, rows)
          nkeys = { beats: 2, bars: 1, sections: 1, song: 0 }.fetch(level)
          keys = rows.map { |r| level == :beats ? r[0, 2] : level == :song ? :song : r[0] }
          data = rows.map { |r| names[nkeys..].zip(r[nkeys..]).to_h }
          Table.from_rows(level, keys, data)
        end

        # True if +path+ is a sidecar of +file+ as it is now (format,
        # digest), made with +settings+ (the keys given; nil to skip).
        def fresh?(path, file, settings = nil)
          return false unless File.file?(path) && File.file?(file)
          head = nil
          saved = nil
          Prism.parse(File.read(path)).value.statements.body.each do |st|
            next unless st.is_a?(Prism::CallNode) && st.receiver.nil?
            if st.name == :bar_stats
              args = (st.arguments&.arguments || []).map { |a| RubyValue.literal(a) }
              return false unless args[0] == FORMAT
              head = args.last
            elsif st.name == :settings
              saved = RubyValue.literal(st.arguments.arguments.last)
              break
            end
          end
          return false unless head.is_a?(Hash) && head[:digest] == digest(file)
          settings.nil? || (saved.is_a?(Hash) && settings.all? { |k, val| saved[k] == val })
        rescue ArgumentError
          false
        end
      end
    end
  end
end

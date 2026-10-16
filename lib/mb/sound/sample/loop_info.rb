module MB
  module Sound
    class Sample
      # Loop metadata of a sound file without decoding its audio: ACID and
      # sampler chunks of WAV files (Sample::Riff), FLAC tags and the RIFF
      # chunks `flac --keep-foreign-metadata` keeps, AIFF lengths, and
      # tempo and key words in the file and folder names ("funk_98bpm",
      # "98 BPM", "Am_120", "Loops/Funk 98 BPM/hat.wav").
      #
      # Used by Sample.from_file (Sample['loop.wav'].bpm) and the console's
      # `loops` listing.  Positions are frames at the file's own sample
      # rate (Sample.from_file scales them to the sample's).
      #
      #     LoopInfo.read('Funk/drums_98bpm.wav')   # => #<data Entry bpm=98.0, beats=8, ..., sources={bpm: :acid, ...}>
      module LoopInfo
        # What LoopInfo.read found about a file.  Every field may be nil.
        # +bpm+ (Float), +beats+ (Integer when the file says so, else a
        # Float estimate from bpm and length), +meter+ ([numerator,
        # denominator]), +key+ (a Symbol like :Am, :"F#", :Eb), +root+ (a
        # MIDI note number, Float), +one_shot+ (true for one-shots, false
        # for loops, nil if nothing says; see .classify), +loop+ ([start,
        # stop, mode] frames, from `smpl`, never for ACID loops, which loop
        # the whole file), +smpl_loops+ (every `smpl` loop, as metadata),
        # +markers+ ([[frame, label or nil], ...] from cue points),
        # +seconds+, +sample_rate+, +format+ (:wav, :flac, :aiff, or
        # :other), +sources+ ({ bpm: :acid | :tags | :name, one_shot: :acid
        # | :smpl | :name | :length | :tempo, ... } saying where each field
        # came from), and +why+ ({ bpm: "name 98 (fits 8 beats)", one_shot:
        # "name 'kick'" } in words, for listings).
        Entry = Data.define(:path, :format, :bpm, :beats, :meter, :key, :root, :one_shot, :loop, :smpl_loops, :markers, :seconds, :sample_rate, :sources, :why) do
          # +beats+ / beats per bar (the meter's numerator, else 4).
          def bars
            return nil unless beats
            b = beats.to_r / (meter ? meter[0] : 4)
            b.denominator == 1 ? b.to_i : b.to_f
          end

          # The file as a Sample (decodes the audio; see Sample.from_file).
          def sample(**options)
            Sample[path, **options]
          end

          # A short label for listings, e.g. "98 BPM, 8 beats, Am".
          def to_s
            parts = []
            parts << "#{bpm == bpm.round ? bpm.round : bpm.round(2)} BPM" if bpm
            parts << "#{beats.is_a?(Integer) ? beats : Kernel.format('~%.1f', beats)} beats" if beats
            parts << key.to_s if key
            parts << 'one-shot' if one_shot
            "#{File.basename(path.to_s)}: #{parts.empty? ? 'no loop info' : parts.join(', ')}"
          end

          # Why the tempo and loop/one-shot call are what they are, in a few
          # words (the listing's "why" column), e.g. "acid", "name 98 (fits 8
          # beats)", "one-shot: name 'kick'".
          def reason
            parts = []
            parts << (why[:bpm] || sources[:bpm]&.to_s) if bpm || why[:bpm]
            kind = why[:one_shot] || sources[:one_shot]&.to_s
            parts << "#{one_shot ? 'one-shot' : 'loop'}: #{kind}" if kind && !one_shot.nil? && sources[:one_shot] != :tempo
            parts.compact.join('; ')
          end
        end

        # File name words that give a tempo (BPM) and their range.
        BPM_RANGE = 40..300

        # Bare numbers in names read as a tempo only in this range (and only
        # without an explicit "bpm" word anywhere).
        BARE_BPM_RANGE = 60..200

        # Beats from bpm and length count as whole when within this
        # fraction of a whole number.
        BEAT_TOLERANCE = 0.02

        # A name-derived tempo counts only when the file's length is a
        # whole number of its beats within this many seconds, or this
        # fraction of a beat, whichever is larger (a trimmed tail or a
        # padded end of a few ms still fits).
        FIT_SECONDS = 0.005
        FIT_BEAT = 0.015

        # Beat counts that read as a loop length (1/2/4/8/16 bars of 4/4 and
        # the halves; any whole number of bars fits too, a bit less well).
        NICE_BEATS = [1, 2, 4, 8, 16, 32, 64].freeze

        # Files shorter than this (seconds) are one-shots unless ACID, smpl,
        # a loop word, or a fitting name tempo says otherwise: one beat at 80
        # BPM, the slowest common loop tempo, so a sound shorter than that
        # with no tempo that fits is a hit, not a groove.
        SHORT = 0.75

        # Files shorter than this are always one-shots unless ACID or smpl
        # says otherwise: one beat at 240 BPM.
        TINY = 0.25

        # Name words that say one-shot or loop (a loop word wins in the same
        # name: "Kick Loop"; the file name decides before its folders, so
        # "One Shots/Loop 3.wav" is a loop).
        ONE_SHOT_WORDS = %w[
          oneshot oneshots kick kicks kik bd snare snares snr sd clap claps clp rim rimshot tom toms cowbell crash cymbal
          hit hits shot shots stab stabs fx sfx impact impacts zap
        ].freeze
        LOOP_WORDS = %w[loop loops looped groove grooves break breaks breakbeat breakbeats beat beats pattern patterns phrase riff riffs top tops fill fills].freeze

        # Extensions read as sound files by LoopInfo.scan.
        EXTENSIONS = %w[.wav .wave .flac .aif .aiff .aifc .mp3 .ogg .m4a].freeze

        module_function

        # The Entry of the file at +path+ (no audio is decoded).  Chunks
        # first, then tags, then the file and folder names (up to
        # +folders+ levels; name tempos only when the length fits, see
        # .fit_tempo), then .classify's loop/one-shot call.  +seconds+
        # gives the length when the caller knows it (Sample.from_file, for
        # formats whose headers aren't read).
        def read(path, folders: 3, seconds: nil, root: nil)
          path = path.to_s
          ext = File.extname(path).downcase
          f = {}
          sources = {}
          format = :other

          if %w[.wav .wave .bwf .rf64].include?(ext) || sniff(path) == :wav
            format = :wav
            from_riff(Riff.read(path), f, sources)
          elsif ext == '.flac' || sniff(path) == :flac
            format = :flac
            from_flac(path, f, sources)
          elsif %w[.aif .aiff .aifc].include?(ext) || sniff(path) == :aiff
            format = :aiff
            from_aiff(path, f, sources)
          end

          f[:seconds] = seconds.to_f if seconds
          why = {}
          names = names_of(path, folders: folders, root: root)
          if !f[:key] && (k = names.lazy.map { |n| parse_name(n)[:key] }.find(&:itself))
            f[:key] = k
            sources[:key] = :name
          end
          classify(names, f, sources, why)

          if f[:bpm] && f[:seconds] && !f[:beats]
            b = f[:seconds] * f[:bpm] / 60.0
            f[:beats] = (b - b.round).abs <= BEAT_TOLERANCE * b && b.round > 0 ? b.round : b
            sources[:beats] = sources[:bpm] == :name ? :name : :length
          end

          Entry.new(
            path: path, format: format, bpm: f[:bpm], beats: f[:beats], meter: f[:meter], key: f[:key], root: f[:root],
            one_shot: f[:one_shot], loop: f[:loop], smpl_loops: (f[:smpl_loops] || []).freeze, markers: (f[:markers] || []).freeze,
            seconds: f[:seconds], sample_rate: f[:sample_rate], sources: sources.freeze, why: why.freeze
          )
        end

        # The name tempo and the loop/one-shot call for +f+ (fields so far)
        # from +names+ (file name first, then folders), in this order:
        # 1. ACID's one-shot flag (already in +f+), always.
        # 2. A `smpl` loop: a loop.
        # 3. A one-shot or loop word in the nearest name that has one.
        # 4. Shorter than TINY: a one-shot.
        # 5. A name tempo whose beats fit the length (.fit_tempo): a loop at
        #    that tempo.  One-shots keep no name tempo.
        # 6. Shorter than SHORT: a one-shot.
        # Otherwise nil.  Writes +f+, +sources+, and +why+.
        def classify(names, f, sources, why)
          secs = f[:seconds]
          unless sources[:one_shot]
            if f[:loop]
              set_kind(f, sources, why, false, :smpl, 'smpl loop')
            elsif (kind = names.each_with_index.lazy.map { |n, i| (k = name_kind(n)) && [*k, i] }.find(&:itself)) &&
                  !(kind[0] == :loop && kind[2] > 0 && secs && secs < SHORT) # a short file in a "Loops" folder
              where = kind[2] == 0 ? 'name' : 'folder'
              set_kind(f, sources, why, kind[0] == :one_shot, :name, "#{where} '#{kind[1]}'")
            elsif secs && secs < TINY
              set_kind(f, sources, why, true, :length, format('%.2f s', secs))
            end
          end

          unless f[:bpm] || f[:one_shot]
            fit = fit_tempo(names, secs, f[:meter] ? f[:meter][0] : 4)
            if fit
              f[:bpm] = fit[:bpm]
              sources[:bpm] = :name
              why[:bpm] = fit[:why]
              if fit[:beats]
                f[:beats] = fit[:beats]
                sources[:beats] = :name
              end
              set_kind(f, sources, why, false, :tempo, fit[:why]) if f[:one_shot].nil? && fit[:beats]
            elsif (c = names.flat_map { |n| name_tempos(n) }.first)
              why[:bpm] = "name #{num(c[0])} (no fit to #{format('%.3f', secs)} s)" if secs
            end
          end

          set_kind(f, sources, why, true, :length, "short (#{format('%.2f', secs)} s)") if f[:one_shot].nil? && secs && secs < SHORT
        end

        def set_kind(f, sources, why, one_shot, source, reason)
          f[:one_shot] = one_shot
          sources[:one_shot] = source
          why[:one_shot] = reason
        end

        # The best name tempo for a file +seconds+ long: every tempo in
        # +names+ (.name_tempos; the file name first) and its double and
        # half (double- and half-time names), counting only those whose
        # beats fit the length within FIT_SECONDS or FIT_BEAT of a beat,
        # preferring the tempo as written, NICE_BEATS or whole bars of
        # +per_bar+, the closest fit, explicit "bpm" words, and nearer
        # names.  Returns { bpm:, beats:, why: } or nil.  Without a length
        # the first explicit tempo (or the only bare number) counts,
        # unchecked.
        def fit_tempo(names, seconds, per_bar = 4)
          cands = names.each_with_index.flat_map { |n, i| name_tempos(n).map { |b, explicit| [b, explicit, i] } }
          return nil if cands.empty?
          unless seconds && seconds > 0
            b, = cands.find { |_, e, _| e } || (cands.length == 1 ? cands[0] : nil)
            return b && { bpm: b, beats: nil, why: "name #{num(b)} (length unknown)" }
          end

          best = nil
          cands.each do |b, explicit, i|
            [[b, 0, nil], [b * 2, 0.75, 'double time'], [b / 2.0, 0.75, 'half time']].each do |bpm, alt, label|
              next unless BPM_RANGE.cover?(bpm)
              beat = 60.0 / bpm
              k = (seconds / beat).round
              next if k < 1
              err = (seconds - k * beat).abs
              tol = [FIT_SECONDS, FIT_BEAT * beat].max
              next if err > tol
              nice = NICE_BEATS.include?(k) || k % per_bar == 0
              score = err / tol + alt + (nice ? 0 : 0.5) + (explicit ? 0 : 0.25) + 0.1 * i
              next if best && best[0] <= score
              lead = label ? " as #{num(bpm)} (#{label}, " : ' ('
              text = "name #{num(b)}#{lead}fits #{k} beat#{'s' if k != 1})"
              best = [score, { bpm: bpm.to_f, beats: k, why: text }]
            end
          end
          best&.last
        end

        def num(x)
          x == x.round ? x.round.to_s : x.round(2).to_s
        end

        # The file name (without extension) and up to +folders+ folder
        # names above it, stopping at +root+ (a listing's folder: names
        # above what was listed say nothing about one file).
        def names_of(path, folders: 3, root: nil)
          names = [File.basename(path.to_s, '.*')]
          dir = File.dirname(path.to_s)
          root = root && File.expand_path(root)
          folders.times do
            base = File.basename(dir)
            break if base.empty? || base == '.' || base == '/' || base == dir
            break if root && !File.expand_path(dir).start_with?("#{root}/")
            names << base
            dir = File.dirname(dir)
          end
          names
        end

        # Tempo candidates in a name: [[bpm, explicit], ...], every number
        # next to a "bpm" word, else every bare 60-200 number.
        def name_tempos(name)
          s = name.to_s.unicode_normalize(:nfkc)
          found = s.scan(/(?<![\d.])(\d{2,3}(?:\.\d+)?)\s*[-_ ]?\s*bpm(?![a-z])/i).flatten +
            s.scan(/(?<![a-z])bpm\s*[-_ ]?\s*(\d{2,3}(?:\.\d+)?)(?![\d.])/i).flatten
          found = found.map(&:to_f).select { |v| BPM_RANGE.cover?(v) }.uniq
          return found.map { |v| [v, true] } unless found.empty?
          return [] if s =~ /bpm/i
          s.split(/[\s_\-.,()\[\]{}+]+/).select { |w| w =~ /\A\d{2,3}\z/ && BARE_BPM_RANGE.cover?(w.to_i) }.map { |w| [w.to_f, false] }.uniq
        end

        # [:one_shot or :loop, the word] from a name's words (LOOP_WORDS
        # win over ONE_SHOT_WORDS), or nil.
        def name_kind(name)
          s = name.to_s.unicode_normalize(:nfkc).gsub(/([a-z])([A-Z])/, '\\1 \\2').downcase.gsub(/one[\s_-]*shots?/, 'oneshot')
          words = s.split(/[^a-z]+/).reject(&:empty?)
          w = words.find { |x| LOOP_WORDS.include?(x) }
          return [:loop, w] if w
          w = words.find { |x| ONE_SHOT_WORDS.include?(x) }
          w && [:one_shot, w]
        end

        # :wav, :flac, :aiff, or nil from the first bytes of the file.
        def sniff(path)
          head = File.binread(path, 12)
          return nil unless head
          if head.start_with?('fLaC') then :flac
          elsif head[8, 4] == 'WAVE' then :wav
          elsif head.start_with?('FORM') && %w[AIFF AIFC].include?(head[8, 4]) then :aiff
          end
        rescue SystemCallError
          nil
        end

        def from_riff(info, f, sources)
          return unless info
          f[:sample_rate] = info.sample_rate if info.sample_rate&.positive?
          f[:seconds] = info.seconds
          if (a = info.acid)
            if a.tempo.finite? && BPM_RANGE.cover?(a.tempo) && !a.one_shot?
              f[:bpm] = a.tempo.to_f
              sources[:bpm] = :acid
            end
            if a.beats > 0 && !a.one_shot?
              f[:beats] = a.beats
              sources[:beats] = :acid
            end
            if a.meter.all? { |m| m > 0 && m <= 64 }
              f[:meter] = a.meter
              sources[:meter] = :acid
            end
            if a.root_set? && a.root <= 127
              f[:root] = a.root.to_f
              sources[:root] = :acid
            end
            f[:one_shot] = a.one_shot?
            sources[:one_shot] = :acid
          end
          if (s = info.smpl)
            if !f[:root] && s.unity_note <= 127 && (s.unity_note != 60 || s.pitch_fraction != 0 || !s.loops.empty?)
              f[:root] = s.unity_note - s.pitch_fraction
              sources[:root] = :smpl
            end
            valid = s.loops.select { |lp| lp.stop > lp.start && (!info.frames || lp.stop <= info.frames) }
            f[:smpl_loops] = valid.map { |lp| [lp.start, lp.stop, lp.type == :ping_pong ? :ping_pong : :forward].freeze }
            l = valid.first
            acid_loop = sources[:one_shot] == :acid && f[:one_shot] == false # ACID loops loop the whole file
            if l && !acid_loop
              f[:loop] = [l.start, l.stop, l.type == :ping_pong ? :ping_pong : :forward].freeze
              sources[:loop] = :smpl
            end
          end
          unless info.cues.empty?
            f[:markers] = info.cues.select { |c| !info.frames || c.position <= info.frames }.map { |c| [c.position, c.label].freeze }
            sources[:markers] = :cue
          end
        end

        # FLAC: STREAMINFO (length), VORBIS_COMMENT (BPM/TEMPO, KEY/
        # INITIALKEY), and APPLICATION "riff" blocks (WAV chunks kept by
        # `flac --keep-foreign-metadata`).
        def from_flac(path, f, sources)
          File.open(path, 'rb') do |io|
            return unless io.read(4) == 'fLaC'
            size = io.size
            riff = { format: nil, data_offset: nil, data_size: nil, acid: nil, smpl: nil, cue: [], labels: {}, lengths: {}, info: {}, chunks: [], ds64_data: nil }
            tags = {}
            100.times do
              h = io.read(4)
              break unless h && h.bytesize == 4
              last = h.getbyte(0) & 0x80 != 0
              type = h.getbyte(0) & 0x7f
              len = h.unpack1('N') & 0xFFFFFF
              break if io.pos + len > size
              if [0, 2, 4].include?(type) && len <= Riff::MAX_CHUNK
                body = io.read(len)
                case type
                when 0 # STREAMINFO
                  if body.bytesize >= 18
                    bits = body.byteslice(10, 8).unpack1('Q>')
                    rate = bits >> 44
                    total = bits & 0xFFFFFFFFF
                    f[:sample_rate] = rate if rate > 0
                    f[:seconds] = total.to_f / rate if rate > 0 && total > 0
                  end
                when 2 # APPLICATION
                  if body.start_with?('riff') && body.bytesize >= 12
                    id = body.byteslice(4, 4)
                    Riff.chunk(id, body.byteslice(12..), riff) if Riff.fourcc?(id) && id != 'data'
                  end
                when 4
                  vorbis_comments(body, tags)
                end
              else
                io.seek(len, IO::SEEK_CUR)
              end
              break if last
            end

            if riff[:acid] || riff[:smpl] || !riff[:cue].empty?
              frames = f[:seconds] && f[:sample_rate] ? (f[:seconds] * f[:sample_rate]).round : nil
              cues = riff[:cue].map { |id, pos| Riff::Cue.new(id: id, position: pos, label: riff[:labels][id], length: nil) }.sort_by(&:position)
              info = Riff::Info.new(path: path, container: :flac, format: nil, frames: frames, data_offset: nil, data_size: nil,
                acid: riff[:acid], smpl: riff[:smpl], cues: cues, info: {}, chunks: [])
              seconds = f[:seconds]
              rate = f[:sample_rate]
              from_riff(info, f, sources)
              f[:seconds] = seconds
              f[:sample_rate] = rate
            end
            from_tags(tags, f, sources)
          end
        rescue SystemCallError, IOError
          nil
        end

        def vorbis_comments(body, tags)
          return if body.bytesize < 8
          vlen = body.unpack1('V')
          pos = 4 + vlen
          return if pos + 4 > body.bytesize
          count = body.unpack1("@#{pos}V")
          pos += 4
          [count, 1000].min.times do
            break if pos + 4 > body.bytesize
            len = body.unpack1("@#{pos}V")
            s = body.byteslice(pos + 4, len).to_s.force_encoding(Encoding::UTF_8)
            pos += 4 + len
            k, v = s.split('=', 2)
            tags[k.upcase] = v.to_s.strip if v && s.valid_encoding?
          end
        end

        # Tempo and key from tags (Vorbis comments or ffmpeg metadata).
        def from_tags(tags, f, sources)
          t = tags.to_h { |k, v| [k.to_s.upcase, v.to_s] }
          if !f[:bpm] && (v = t['BPM'] || t['TBPM'] || t['TEMPO']) && v =~ /\A\s*(\d+(?:\.\d+)?)/ && BPM_RANGE.cover?($1.to_f)
            f[:bpm] = $1.to_f
            sources[:bpm] = :tags
          end
          if !f[:key] && (v = t['KEY'] || t['INITIALKEY'] || t['TKEY']) && (k = key_of(v.strip.delete(' ')))
            f[:key] = k
            sources[:key] = :tags
          end
        end

        # AIFF: the length from COMM (no loop chunks are read yet).
        def from_aiff(path, f, _sources)
          File.open(path, 'rb') do |io|
            head = io.read(12)
            return unless head && head.start_with?('FORM') && %w[AIFF AIFC].include?(head[8, 4])
            size = io.size
            pos = 12
            200.times do
              break if pos + 8 > size
              io.seek(pos)
              h = io.read(8)
              id = h[0, 4]
              len = h.unpack1('@4N')
              if id == 'COMM' && len >= 18
                b = io.read(18)
                frames = b.unpack1('@2N')
                rate = extended_float(b.byteslice(8, 10))
                if rate && rate > 0
                  f[:sample_rate] = rate.round
                  f[:seconds] = frames.to_f / rate
                end
                break
              end
              pos += 8 + len + (len.odd? ? 1 : 0)
            end
          end
        rescue SystemCallError, IOError
          nil
        end

        # An 80-bit IEEE extended float (AIFF sample rates).
        def extended_float(b)
          return nil unless b && b.bytesize == 10
          exp = b.unpack1('n')
          mant = b.byteslice(2, 8).unpack1('Q>')
          sign = exp & 0x8000 != 0 ? -1 : 1
          exp &= 0x7FFF
          return 0.0 if exp == 0 && mant == 0
          sign * mant * 2.0**(exp - 16383 - 63)
        end

        # The first tempo and the key of one name (keys: see .key_of; a
        # lone letter only next to a tempo).  LoopInfo.read takes keys
        # from here and tempos from .fit_tempo.
        def parse_name(name)
          s = name.to_s.unicode_normalize(:nfkc).tr('♯♭', '#b')
          bpm = nil
          if (m = s.match(/(?<![\d.])(\d{2,3}(?:\.\d+)?)\s*[-_ ]?\s*bpm(?![a-z])/i) || s.match(/(?<![a-z])bpm\s*[-_ ]?\s*(\d{2,3}(?:\.\d+)?)(?![\d.])/i))
            v = m[1].to_f
            bpm = v if BPM_RANGE.cover?(v)
          end
          words = s.split(/[\s_\-.,()\[\]{}+]+/).reject(&:empty?)
          if bpm.nil? && s !~ /bpm/i
            bare = words.select { |w| w =~ /\A\d{2,3}\z/ && BARE_BPM_RANGE.cover?(w.to_i) }
            bpm = bare.first.to_f if bare.length == 1
          end
          key = nil
          words.each_with_index do |w, i|
            w = w.sub(/\A(?:key|in)(?=[A-G])/i, '')
            w += words[i + 1].downcase if w =~ /\A[A-G](#|b)?\z/ && words[i + 1] =~ /\A(minor|major|min|maj|moll|dur)\z/i
            k = key_of(w, bare_letter: !bpm.nil?)
            if k
              key = k
              break
            end
          end
          { bpm: bpm, key: key }
        end

        # A key Symbol (:Am, :"F#", :Eb) for a word like "Am", "F#min",
        # "Ebmaj", "C#m", or nil (capital letters only: "am" and "a" are
        # words).  A lone letter counts only if +bare_letter+.
        def key_of(word, bare_letter: true)
          m = word.match(/\A([A-G])(#|b|s|sharp|flat)?(m|min|minor|maj|major|M|mi|dur|moll)?(?:(?<=[mjMr])\d{1,2})?\z/)
          return nil unless m
          letter, acc, mode = m.captures
          return nil if acc.nil? && mode.nil? && !bare_letter
          acc = { 's' => '#', 'sharp' => '#', 'flat' => 'b' }.fetch(acc, acc)
          minor = %w[m min minor mi moll].include?(mode)
          :"#{letter.upcase}#{acc}#{'m' if minor}"
        end

        # A listing of loop files (MB::Sound#loops): Entries that print as a
        # table.  `list[3]` is an Entry (`list[3].sample.follow`),
        # `list.sample(3)` its Sample; Enumerable for the rest.
        class List
          include Enumerable

          # The folder listed, and its Entries.
          attr_reader :dir, :entries

          def initialize(dir, entries)
            @dir = dir
            @entries = entries.freeze
          end

          def each(&block)
            @entries.each(&block)
          end

          def [](i)
            @entries[i]
          end

          def length
            @entries.length
          end
          alias size length
          alias count length

          def empty?
            @entries.empty?
          end

          # Entry +i+'s Sample.
          def sample(i, **options)
            @entries.fetch(i).sample(**options)
          end

          # A table: index, file (relative to #dir), BPM, beats, key,
          # loop or one-shot, and why (Entry#reason).
          def to_s
            return "No loop files in #{@dir}" if @entries.empty?
            rows = @entries.each_with_index.map { |e, i|
              [
                i.to_s, e.path.delete_prefix("#{@dir}/"),
                e.bpm ? (e.bpm == e.bpm.round ? e.bpm.round.to_s : format('%.2f', e.bpm)) : '-',
                e.beats ? (e.beats.is_a?(Integer) ? e.beats.to_s : format('~%.1f', e.beats)) : '-',
                e.key&.to_s || '-',
                e.one_shot.nil? ? '-' : (e.one_shot ? 'one-shot' : 'loop'),
                e.reason,
              ]
            }
            head = ['#', 'file', 'bpm', 'beats', 'key', 'kind', 'why']
            widths = head.each_index.map { |c| ([head] + rows).map { |r| r[c].length }.max }
            line = ->(r) { r.each_with_index.map { |v, c| c == 1 || c >= 5 ? v.ljust(widths[c]) : v.rjust(widths[c]) }.join('  ').rstrip }
            (["#{@entries.length} loop file#{'s' if @entries.length != 1} in #{@dir}", line.(head)] + rows.map(&line)).join("\n")
          end

          def inspect
            to_s
          end

          def pretty_print(q)
            q.text(to_s)
          end
        end

        # A List of the sound files in +dir+ whose metadata matches: +bpm+
        # (a number, within 1%, or a Range), +key+ (a key Symbol or an
        # Array of them; :Am, :"F#"), +beats+ (a number or Range).  Reads
        # headers and names only.
        def list(dir = '.', bpm: nil, key: nil, beats: nil, recursive: true)
          entries = scan(dir, recursive: recursive)
          entries = entries.select { |e| e.bpm && (bpm.is_a?(Range) ? bpm.cover?(e.bpm) : (e.bpm - bpm).abs <= bpm * 0.01) } if bpm
          keys = Array(key).map { |k| k.to_s.tr('♯♭', '#b').to_sym } if key
          entries = entries.select { |e| keys.include?(e.key) } if key
          entries = entries.select { |e| e.beats && (beats.is_a?(Range) ? beats.cover?(e.beats) : e.beats == beats) } if beats
          List.new(File.expand_path(dir.to_s), entries)
        end

        # Every sound file under +dir+ (recursively), as Entries, sorted by
        # path.
        def scan(dir, recursive: true)
          dir = File.expand_path(dir.to_s)
          raise ArgumentError, "#{dir} is not a directory" unless File.directory?(dir)
          pattern = recursive ? File.join(dir, '**', '*') : File.join(dir, '*')
          Dir.glob(pattern).select { |p| EXTENSIONS.include?(File.extname(p).downcase) && File.file?(p) }.sort.map { |p| read(p, root: dir) }
        end
      end
    end
  end
end

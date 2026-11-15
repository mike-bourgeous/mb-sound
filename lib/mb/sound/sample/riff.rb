module MB
  module Sound
    class Sample
      # Reads (and, for test fixtures, writes) the RIFF chunks of WAV files
      # that ffmpeg ignores: ACID loop info (`acid`), sampler info (`smpl`:
      # unity note, loops), cue points (`cue `) and their labels
      # (`LIST`/`adtl`), and `LIST`/`INFO` text.  Only the headers are read;
      # the audio is skipped (Riff.read of a 1 GB file reads a few kB).
      #
      # Robust to what loop libraries contain: odd chunk sizes with or
      # without the pad byte, RF64/BW64 (`ds64` sizes), WAVE_FORMAT_EXTENSIBLE,
      # unknown chunks (skipped), truncated files (sizes are never trusted
      # beyond the end of the file), and chunks too short for their layout
      # (ignored).  Nothing is ever written to a file that is read.
      #
      # Layouts (little-endian):
      # - `acid` (24 bytes; libsndfile's wav_read_acid_chunk, and the
      #   Sony/Magix ACID format notes): uint32 flags (0x01 one-shot, 0x02
      #   root note set, 0x04 stretch, 0x08 disk-based, 0x10 a high-octave
      #   flag), uint16 root note (MIDI, 60 = C4), uint16 and float32
      #   unknown, uint32 beats, uint16 meter denominator, uint16 meter
      #   numerator, float32 tempo (BPM).
      # - `smpl` (36 bytes + 24 per loop; the Microsoft multimedia
      #   registration): manufacturer, product, sample period, MIDI unity
      #   note, pitch fraction, SMPTE format, SMPTE offset, loop count,
      #   sampler data size, then per loop: cue id, type (0 forward, 1
      #   ping-pong, 2 backward), start, end (inclusive frames), fraction,
      #   play count (0 = forever).
      # - `cue ` (4 + 24 per point): count, then id, position, data chunk
      #   id, chunk start, block start, sample offset (frames).
      # - `LIST` `adtl`: `labl`/`note` (cue id, text), `ltxt` (cue id,
      #   sample length, purpose, country, language, dialect, code page,
      #   text).
      #
      # - `strc` (ACID's stretch markers; Sony published no layout, so this
      #   one was worked out from loop libraries, 2026-11-10, see Strc and
      #   design/notes/loops.md for what is verified and what is assumed):
      #   a 28-byte header (uint32 28, uint32 entry count, five uint32
      #   settings), then 32-byte entries: uint32 flags (0x01 disabled, 0x02
      #   automatic), uint32 unused, uint64 sample position (frames at the
      #   file's rate), uint64 pin (the position again, 0, or the grid time
      #   in frames the marker is pinned to), uint32 value, uint32 unused.
      module Riff
        # The audio format from `fmt `: +tag+ (1 PCM, 3 float, 0xFFFE
        # extensible), +subformat+ (the extensible GUID's format code, else
        # +tag+), +channels+, +sample_rate+, +bits+, +block_align+.
        Format = Data.define(:tag, :subformat, :channels, :sample_rate, :bits, :block_align)

        # The `acid` chunk (see the module description).  +meter+ is
        # [numerator, denominator].
        Acid = Data.define(:flags, :root, :beats, :meter, :tempo) do
          def one_shot? = flags & 0x01 != 0
          def root_set? = flags & 0x02 != 0
          def stretch? = flags & 0x04 != 0
          def disk_based? = flags & 0x08 != 0
          def high_octave? = flags & 0x10 != 0
        end

        # A `smpl` loop: +type+ (:forward, :ping_pong, :backward, or the
        # number), +start+ and +stop+ (frames; stop exclusive, the chunk's
        # end + 1), +play_count+ (0 forever).
        SmplLoop = Data.define(:id, :type, :start, :stop, :fraction, :play_count)

        # The `smpl` chunk: +unity_note+ (MIDI), +pitch_fraction+ (0..1 of
        # a semitone up), +period+ (ns per sample), +loops+.
        Smpl = Data.define(:unity_note, :pitch_fraction, :period, :loops)

        # A cue point at frame +position+ (its sample offset), with its
        # `labl` text (or nil) and `ltxt` length (frames, or nil).
        Cue = Data.define(:id, :position, :label, :length)

        # One entry of the `strc` chunk: +flags+, +position+ (frames at the
        # file's rate), +pin+ (see Strc), and +value+ (the raw uint32).
        StrcEntry = Data.define(:flags, :position, :pin, :value) do
          # A marker ACID keeps but doesn't use (never among the stretch
          # markers ACID projects hold for the same file).
          def disabled? = flags & 0x01 != 0

          # Placed by ACID (a detected transient or a grid division), not
          # moved or added by hand.
          def automatic? = flags & 0x02 != 0

          # A detected transient with its #strength: a candidate ACID
          # keeps beside the markers, not a marker.
          def hint? = automatic? && pin == 0 && value != 0

          # A hint's strength (+value+ as a float32; 1.2 to several
          # hundred), else nil.
          def strength = hint? ? [value].pack('V').unpack1('e') : nil

          # True if the marker is pinned to another time than its own
          # position (see Strc: the audio at #position belongs at #pin
          # on the grid).
          def pinned? = pin != 0 && pin != position
        end

        # The `strc` chunk, ACID's stretch markers: +count+ (the header's
        # entry count, at most the entries present), +settings+ (the
        # header's five other words, not decoded), and +entries+ (every
        # StrcEntry in the chunk, in file order).
        #
        # Worked out from the 13385 chunks of a loop library (many packs
        # and ACID versions) and from the stretch markers 864 ACID
        # projects hold for the same files (1641 takes; 2026-11-10).
        # Verified there: the header is 28 bytes and says so in its first
        # word; entries are 32 bytes; the sample position (the entry's
        # uint64 at +8, frames at the file's own rate) is the source sample
        # of the projects' markers (84% of 83333 markers are among them
        # as they are; projects move and drop markers by their own
        # settings) and is where the audio rises (by over 6 dB at 36% of
        # 13482 markers in 400 loops, against 2% of the points halfway
        # between markers); flag 0x01 markers are not among the projects'
        # (1 of 1318); the header's fourth word is the stretching method
        # and its sixth the stretch spacing (they match the projects'
        # settings in 1572 of 1609 and 514 of 521 takes).  Likely: a pin
        # that differs from its position is the marker's time on the grid
        # in frames (the projects pin 543 of 1734 such markers there).
        # Assumed: how the entries divide into lists (#lists) and which
        # list holds the markers (#markers); flag 0x02 as "automatic"; the
        # header's count as the end of what its writer meant (the oldest
        # files carry more entries after it, appended by later ACID
        # versions; projects agree with the counted ones more often).  Not
        # decoded: the header's other settings, the fraction some ACID
        # versions keep in +value+, and the pin of the first marker in the
        # oldest files (an offset of the audio's first hit).
        Strc = Data.define(:count, :settings, :entries) do
          # The counted entries as lists: ACID writes several lists one
          # after the other, each sorted by position (detected transients
          # with strengths, automatic markers, often several copies, then
          # the markers with their pins), so a new list starts wherever
          # the position goes down.
          def lists
            out = []
            entries.first(count).each do |e|
              out << [] if out.empty? || e.position < out.last.last.position
              out.last << e
            end
            out
          end

          # The stretch markers' positions (frames at the file's rate,
          # rising, 0 included when the file has it): the last list that
          # isn't transient hints, without its disabled markers; when that
          # list holds only markers set by hand (ACID then keeps the
          # automatic ones in the list before it), both.
          def markers
            ls = lists.reject { |l| l.count(&:hint?) * 2 > l.length }
            return [].freeze if ls.empty?
            final = ls.last
            final = ls[-2] + final if ls.length > 1 && final.none?(&:automatic?)
            final.reject { |e| e.disabled? || e.hint? }.map(&:position).uniq.sort.freeze
          end

          # The stretching method of ACID's Stretch tab (the header's
          # fourth word): :looping or :nonlooping segments, or nil.
          def stretch_method = STRC_METHODS[settings[2]]

          # The stretch spacing ("force divisions at"; the header's sixth
          # word) as divisions per whole note: 8 for eighth notes, 16 for
          # sixteenths, nil when the file sets none.
          def spacing = settings[4].between?(1, 8) ? 1 << settings[4] : nil

          # The forced divisions ACID adds when it plays a file of the
          # older generations (one list of markers; newer versions write
          # the divisions into the list): the #spacing grid over +beats+
          # quarter-note beats of +frames+ frames, each division that has
          # no marker within a quarter of a division of it (ACID keeps a
          # division unless a marker is within about 2 ms; slices that
          # short are no use to a slice stretch).  Rising positions; empty
          # for newer files, files without a spacing, and unknown lengths.
          # +marks+ are #markers, for a caller that has them.
          def forced(frames, beats, marks = nil)
            return [].freeze unless spacing && frames && beats && frames > 0 && beats > 0
            step = frames * 4.0 / (beats * spacing)
            return [].freeze if step < 64 || entries.first(count).each_cons(2).any? { |a, b| b.position < a.position }
            marks ||= markers
            k = 0
            out = []
            (1...(frames / step).ceil).each do |i|
              g = (i * step).round
              k += 1 while k < marks.length - 1 && (marks[k + 1] - g).abs <= (marks[k] - g).abs
              out << g if g < frames && (marks.empty? || (marks[k] - g).abs >= step / 4)
            end
            out.freeze
          end
        end

        # Strc#stretch_method's names.
        STRC_METHODS = { 1 => :looping, 2 => :nonlooping }.freeze

        # Everything Riff.read found.  +container+ is :riff, :rf64, or
        # :bw64; +frames+ the audio length (from the data chunk, clamped to
        # the file); +chunks+ [id, offset, size] for every chunk (sizes as
        # declared); +info+ the LIST/INFO texts by id (e.g. "INAM"); +strc+
        # ACID's stretch markers (a Strc) or nil.
        Info = Data.define(:path, :container, :format, :frames, :data_offset, :data_size, :acid, :smpl, :cues, :info, :chunks, :strc) do
          def sample_rate = format&.sample_rate
          def channels = format&.channels

          # The audio length in seconds, or nil.
          def seconds
            frames && sample_rate && sample_rate > 0 ? frames.to_f / sample_rate : nil
          end
        end

        # Raised by .read! for files that aren't RIFF WAVE files.
        class NotWave < ArgumentError; end

        # Metadata chunks larger than this are skipped (no loop file has
        # them; a broken size field shouldn't make us read megabytes).
        MAX_CHUNK = 4 << 20

        # The most chunks read from one file.
        MAX_CHUNKS = 10_000

        LOOP_TYPES = { 0 => :forward, 1 => :ping_pong, 2 => :backward }.freeze

        module_function

        # The Info of the WAV file at +path+, or nil if it isn't a RIFF
        # WAVE (or RF64/BW64) file.
        def read(path)
          read!(path)
        rescue NotWave
          nil
        end

        # Like .read, but raises NotWave for other files.
        def read!(path)
          File.open(path, 'rb') { |f| parse(f, path.to_s) }
        end

        # The Info of RIFF chunks in +io+ (a WAVE file).
        def parse(io, path = nil)
          head = io.read(12)
          raise NotWave, "#{path || 'input'} is not a WAV file" unless head && head.bytesize == 12 && head[8, 4] == 'WAVE'

          container = { 'RIFF' => :riff, 'RF64' => :rf64, 'BW64' => :bw64 }[head[0, 4]]
          raise NotWave, "#{path || 'input'} is not a RIFF WAVE file (#{head[0, 4].inspect})" unless container

          file_size = io.size
          state = { format: nil, data_offset: nil, data_size: nil, acid: nil, smpl: nil, strc: nil, cue: [], labels: {}, lengths: {}, info: {}, chunks: [], ds64_data: nil }

          pos = 12
          while pos + 8 <= file_size && state[:chunks].length < MAX_CHUNKS
            io.seek(pos)
            h = io.read(8)
            break unless h && h.bytesize == 8

            id = h[0, 4]
            size = h.unpack1('@4V')
            break unless fourcc?(id)

            state[:chunks] << [id, pos, size]
            body = pos + 8
            if id == 'data'
              size = state[:ds64_data] if size == 0xFFFFFFFF && state[:ds64_data]
              state[:data_offset] = body
              state[:data_size] = [size, file_size - body].min
            elsif size <= MAX_CHUNK
              avail = [size, file_size - body].min
              chunk(id, io.read(avail) || ''.b, state) if avail > 0
            end

            nxt = body + size
            nxt += 1 if size.odd? && !unpadded?(io, nxt, file_size)
            break if nxt <= pos

            pos = nxt
          end

          format = state[:format]
          frames = state[:data_size] && format && format.block_align > 0 ? state[:data_size] / format.block_align : nil
          cues = state[:cue].map { |id, position|
            Cue.new(id: id, position: position, label: state[:labels][id], length: state[:lengths][id])
          }.sort_by(&:position).freeze

          Info.new(
            path: path, container: container, format: format, frames: frames, data_offset: state[:data_offset], data_size: state[:data_size],
            acid: state[:acid], smpl: state[:smpl], cues: cues, info: state[:info].freeze, chunks: state[:chunks].freeze, strc: state[:strc]
          )
        end

        # True if +id+ looks like a chunk id (four printable ASCII bytes).
        def fourcc?(id)
          id.bytesize == 4 && id.each_byte.all? { |b| b >= 0x20 && b <= 0x7e }
        end

        # True if an odd-sized chunk ending at +nxt+ was written without its
        # pad byte: a chunk id starts right there, and none starts a byte
        # later.
        def unpadded?(io, nxt, file_size)
          return false if nxt + 9 > file_size
          io.seek(nxt)
          s = io.read(5)
          s && s.bytesize == 5 && fourcc?(s[0, 4]) && !fourcc?(s[1, 4])
        end

        # Parses one chunk's +body+ into +state+.
        def chunk(id, body, state)
          case id
          when 'fmt ' then state[:format] = fmt(body)
          when 'ds64'
            state[:ds64_data] = body.unpack1('@8Q<') if body.bytesize >= 16
          when 'acid'
            state[:acid] = acid(body)
          when 'smpl'
            state[:smpl] = smpl(body)
          when 'strc'
            state[:strc] = strc(body)
          when 'cue '
            state[:cue] = cue(body)
          when 'LIST'
            list(body, state)
          end
        end

        def fmt(body)
          return nil if body.bytesize < 16
          tag, channels, rate, _byte_rate, align, bits = body.unpack('vvVVvv')
          sub = tag
          sub = body.unpack1('@24v') if tag == 0xFFFE && body.bytesize >= 26
          Format.new(tag: tag, subformat: sub, channels: channels, sample_rate: rate, bits: bits, block_align: align)
        end

        def acid(body)
          return nil if body.bytesize < 24
          flags, root, _u1, _u2, beats, den, num, tempo = body.unpack('VvveVvve')
          Acid.new(flags: flags, root: root, beats: beats, meter: [num, den].freeze, tempo: tempo)
        end

        def smpl(body)
          return nil if body.bytesize < 36
          _man, _prod, period, unity, fraction, _fmt, _off, count, extra = body.unpack('V9')
          count = [count, (body.bytesize - 36) / 24].min
          loops = Array.new(count) { |i|
            id, type, a, b, frac, plays = body.unpack("@#{36 + 24 * i}V6")
            SmplLoop.new(id: id, type: LOOP_TYPES.fetch(type, type), start: a, stop: b + 1, fraction: frac / 4294967296.0, play_count: plays)
          }
          _ = extra
          Smpl.new(unity_note: unity, pitch_fraction: fraction / 4294967296.0, period: period, loops: loops.freeze)
        end

        # The Strc of a `strc` chunk's +body+ (see Strc), or nil if it is
        # too short for its header.
        def strc(body)
          return nil if body.bytesize < STRC_HEADER
          head, count, *settings = body.unpack('V7')
          return nil unless head >= STRC_HEADER && head <= body.bytesize
          n = (body.bytesize - head) / STRC_ENTRY
          words = body.unpack("@#{head}#{'VVQ<Q<VV' * n}")
          entries = Array.new(n) { |i| StrcEntry.new(words[6 * i], words[6 * i + 2], words[6 * i + 3], words[6 * i + 4]) }
          Strc.new(count: [count, n].min, settings: settings.freeze, entries: entries.freeze)
        end

        # The sizes of the `strc` chunk's header and entries.
        STRC_HEADER = 28
        STRC_ENTRY = 32

        def cue(body)
          return [] if body.bytesize < 4
          count = [body.unpack1('V'), (body.bytesize - 4) / 24].min
          Array.new(count) { |i|
            id, _position, _chunk, _cstart, _bstart, offset = body.unpack("@#{4 + 24 * i}V2a4V3")
            [id, offset]
          }
        end

        def list(body, state)
          return if body.bytesize < 4
          type = body[0, 4]
          pos = 4
          while pos + 8 <= body.bytesize
            id = body[pos, 4]
            size = body.unpack1("@#{pos + 4}V")
            break unless fourcc?(id)
            data = body.byteslice(pos + 8, [size, body.bytesize - pos - 8].min)
            case type
            when 'adtl'
              case id
              when 'labl', 'note'
                if data.bytesize >= 4
                  cid = data.unpack1('V')
                  state[:labels][cid] ||= text(data.byteslice(4..)) if id == 'labl'
                end
              when 'ltxt'
                state[:lengths][data.unpack1('V')] = data.unpack1('@4V') if data.bytesize >= 8
              end
            when 'INFO'
              state[:info][id] = text(data)
            end
            nxt = pos + 8 + size
            nxt += 1 if size.odd? && nxt < body.bytesize && !(fourcc?(body.byteslice(nxt, 4).to_s) && !fourcc?(body.byteslice(nxt + 1, 4).to_s))
            break if nxt <= pos
            pos = nxt
          end
        end

        # A chunk's text: up to the first NUL, as UTF-8 if it is valid,
        # else Latin-1 (old Windows tools).
        def text(data)
          s = data.split("\0", 2).first.to_s.b
          u = s.dup.force_encoding(Encoding::UTF_8)
          (u.valid_encoding? ? u : s.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)).strip
        end

        # Writes a WAV file for test fixtures and in-repo demo loops (never
        # used on files read by .read).  +channels+ is an Array of Numo
        # arrays (or one), written as 16-bit PCM (+bits+ 16), 24-bit PCM,
        # or 32-bit float (+bits+ :float).  Optional chunks: +acid+ (a Hash
        # of flags/one_shot/root/beats/meter/tempo), +smpl+ (a Hash of
        # unity_note/pitch_fraction/loops: [[start, stop, type], ...]),
        # +cues+ (an Array of frames, or of [frame, label] pairs), +strc+
        # (ACID stretch markers: an Array of entries, or a Hash of
        # entries:, count:, settings:, and tail:; see .strc_bytes), +info+
        # (a Hash of INFO ids to text), +extra+ ([[id, bytes], ...] written
        # before the data, e.g. odd-sized unknown chunks), +rf64+ (an RF64
        # header with a ds64 chunk and 0xFFFFFFFF sizes), +extensible+
        # (WAVE_FORMAT_EXTENSIBLE), +pad+ (false leaves out the pad bytes
        # after odd-sized chunks, as some writers do).
        def write(path, channels, sample_rate: 48000, bits: 16, acid: nil, smpl: nil, cues: nil, strc: nil, info: nil, extra: [], rf64: false, extensible: false, pad: true, overwrite: false)
          raise ArgumentError, "#{path} exists" if File.exist?(path) && !overwrite
          channels = [channels] unless channels.is_a?(Array)
          channels = channels.map { |c| Numo::DFloat.cast(c) }
          n = channels[0].length
          nch = channels.length

          data = audio_bytes(channels, bits).b
          bytes_per = bits == :float ? 4 : bits / 8
          tag = bits == :float ? 3 : 1
          align = bytes_per * nch

          chunks = []
          fmt = [extensible ? 0xFFFE : tag, nch, sample_rate, sample_rate * align, align, bytes_per * 8].pack('vvVVvv')
          if extensible
            guid = [tag, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71].pack('VvvC8')
            fmt << [22, bytes_per * 8, (1 << nch) - 1].pack('vvV') << guid
          end
          chunks << ['ds64', [0, data.bytesize, n, 0].pack('Q<Q<Q<V')] if rf64
          chunks << ['fmt ', fmt]
          chunks << ['acid', acid_bytes(acid)] if acid
          chunks << ['smpl', smpl_bytes(smpl)] if smpl
          chunks << ['strc', strc_bytes(strc)] if strc
          if cues && !cues.empty?
            pts = cues.map { |c| c.is_a?(Array) ? c : [c, nil] }
            body = [pts.length].pack('V')
            pts.each_with_index { |(frame, _), i| body << [i + 1, frame, 'data', 0, 0, frame].pack('VVa4VVV') }
            chunks << ['cue ', body]
            labels = pts.each_with_index.select { |(_, l), _| l }
            unless labels.empty?
              adtl = 'adtl'.b
              labels.each { |(_, l), i|
                t = [i + 1].pack('V') + l.to_s.b + "\0".b
                adtl << 'labl' << [t.bytesize].pack('V') << t
                adtl << "\0".b if t.bytesize.odd?
              }
              chunks << ['LIST', adtl]
            end
          end
          if info && !info.empty?
            body = 'INFO'.b
            info.each { |id, t|
              t = t.to_s.b + "\0".b
              body << id.to_s.ljust(4)[0, 4] << [t.bytesize].pack('V') << t
              body << "\0".b if t.bytesize.odd?
            }
            chunks << ['LIST', body]
          end
          chunks.concat(extra)

          out = ''.b
          chunks.each { |id, body|
            out << id.b << [body.bytesize].pack('V') << body.b
            out << "\0".b if body.bytesize.odd? && pad
          }
          out << 'data' << [rf64 ? 0xFFFFFFFF : data.bytesize].pack('V') << data
          out << "\0".b if data.bytesize.odd?

          head = (rf64 ? 'RF64' : 'RIFF').b + [rf64 ? 0xFFFFFFFF : out.bytesize + 4].pack('V') + 'WAVE'.b
          File.binwrite(path, head + out)
          path
        end

        def audio_bytes(channels, bits)
          inter = Numo::DFloat.zeros(channels[0].length, channels.length)
          channels.each_with_index { |c, i| inter[true, i] = c }
          inter = inter.flatten
          case bits
          when :float then Numo::SFloat.cast(inter).to_binary
          when 16 then Numo::Int16.cast((inter.clip(-1, 32767.0 / 32768) * 32768).round).to_binary
          when 24
            ints = Numo::Int32.cast((inter.clip(-1, 8388607.0 / 8388608) * 8388608).round).to_a
            ints.pack('l<*').bytes.each_slice(4).map { |b| b[0, 3].pack('C3') }.join.b
          else raise ArgumentError, "bits is 16, 24, or :float (got #{bits.inspect})"
          end
        end

        def acid_bytes(acid)
          flags = acid.fetch(:flags) {
            (acid[:one_shot] ? 0x01 : 0) | (acid.key?(:root) ? 0x02 : 0) | (acid.fetch(:stretch, true) ? 0x04 : 0)
          }
          num, den = acid.fetch(:meter, [4, 4])
          [flags, acid.fetch(:root, 60), 0x8000, 0.0, acid.fetch(:beats, 0), den, num, acid.fetch(:tempo, 0.0).to_f].pack('VvveVvve')
        end

        # A `strc` chunk for fixtures.  +strc+ is an Array of entries, each
        # a frame (a marker as the oldest ACID versions wrote it: flags 0,
        # pinned to itself) or a Hash of position:, pin: (the position
        # unless given), flags: (or disabled: and automatic:), and value:
        # (or strength:, a hint's float32); or a Hash of entries:, count:
        # (the header's; every entry unless given), settings: (the
        # header's five other words), and tail: (zero bytes after the
        # entries; one ACID generation leaves 8).  Lists (Strc#lists) are
        # entries whose positions start over.
        def strc_bytes(strc)
          strc = { entries: strc } if strc.is_a?(Array)
          entries = strc.fetch(:entries)
          body = [STRC_HEADER, strc.fetch(:count, entries.length), *strc.fetch(:settings, [0, 0, 1, 0, 0])].pack('V7')
          entries.each do |e|
            e = { position: e } unless e.is_a?(Hash)
            flags = e.fetch(:flags) { (e[:disabled] ? 0x01 : 0) | (e[:automatic] ? 0x02 : 0) }
            value = e.key?(:strength) ? [e[:strength]].pack('e').unpack1('V') : e.fetch(:value, 0)
            body << [flags, 0, e.fetch(:position), e.fetch(:pin, e.fetch(:position)), value, 0].pack('VVQ<Q<VV')
          end
          body << ("\0".b * strc.fetch(:tail, 0))
        end

        def smpl_bytes(smpl)
          loops = smpl.fetch(:loops, [])
          fraction = (smpl.fetch(:pitch_fraction, 0).to_f * 4294967296).round.clamp(0, 0xFFFFFFFF)
          body = [0, 0, 20833, smpl.fetch(:unity_note, 60), fraction, 0, 0, loops.length, 0].pack('V9')
          loops.each_with_index { |(a, b, type), i| body << [i, LOOP_TYPES.key(type || :forward) || 0, a, b - 1, 0, 0].pack('V6') }
          body
        end
      end
    end
  end
end

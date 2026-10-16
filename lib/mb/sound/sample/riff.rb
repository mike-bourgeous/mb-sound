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
      # ACID's `strc` chunk (slice/stretch data) is listed in #chunks but not
      # decoded: no public description of its layout could be confirmed
      # (2026-10-15), so slices come from cue points or onsets instead.
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

        # Everything Riff.read found.  +container+ is :riff, :rf64, or
        # :bw64; +frames+ the audio length (from the data chunk, clamped to
        # the file); +chunks+ [id, offset, size] for every chunk (sizes as
        # declared); +info+ the LIST/INFO texts by id (e.g. "INAM").
        Info = Data.define(:path, :container, :format, :frames, :data_offset, :data_size, :acid, :smpl, :cues, :info, :chunks) do
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
          state = { format: nil, data_offset: nil, data_size: nil, acid: nil, smpl: nil, cue: [], labels: {}, lengths: {}, info: {}, chunks: [], ds64_data: nil }

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
            acid: state[:acid], smpl: state[:smpl], cues: cues, info: state[:info].freeze, chunks: state[:chunks].freeze
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
        # +cues+ (an Array of frames, or of [frame, label] pairs), +info+
        # (a Hash of INFO ids to text), +extra+ ([[id, bytes], ...] written
        # before the data, e.g. odd-sized unknown chunks), +rf64+ (an RF64
        # header with a ds64 chunk and 0xFFFFFFFF sizes), +extensible+
        # (WAVE_FORMAT_EXTENSIBLE), +pad+ (false leaves out the pad bytes
        # after odd-sized chunks, as some writers do).
        def write(path, channels, sample_rate: 48000, bits: 16, acid: nil, smpl: nil, cues: nil, info: nil, extra: [], rf64: false, extensible: false, pad: true, overwrite: false)
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

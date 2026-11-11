module MB
  module Sound
    module Meta
      # Metadata in foreign file formats (metadata-2): each format carries
      # the vocabulary in its own tags, for people (any player or DAW shows
      # a WAV's name and comment), and the whole metadata as one namespaced
      # Ruby literal, for agents and for mb-sound (read back by Value.parse,
      # never run).  On read, native tags never override the Ruby text: a
      # file mb-sound wrote reads back exactly, and a foreign file's tags
      # become description (`title:`, `notes:`, ...), never data: a foreign
      # name is never a lookup name, a comment never a setting.  A file with
      # the Ruby text reads back from it alone (mb-sound wrote the native
      # tags from it, plus a title from the object's name), so what was
      # saved comes back exactly; a foreign file's native tags are read.
      #
      # | format | native tags | the whole Hash |
      # |---|---|---|
      # | WAV / RF64 | LIST INFO: INAM title, ICMT notes, IART author, ICOP license, IKEY tags | an `mbmt` chunk |
      # | FLAC, Ogg, MP3 (ffmpeg tags) | TITLE, COMMENT, ARTIST, COPYRIGHT (ID3 TIT2, COMM, TPE1, TCOP) | MB_SOUND_META (ID3 TXXX) |
      # | MIDI files | track name (title), text (notes), copyright (license), markers | a text event `mb-sound meta: {...}` |
      # | SoundFonts (read) | INFO: INAM title, ICMT notes, IENG author, ICOP license | (none) |
      # | anything else | | a sidecar `<file>.meta.rb` holding one `meta` statement |
      #
      # Notes are one comment in native tags (joined with newlines; a
      # comment read from a foreign file is one note per line), tags one
      # keyword list (joined with "; ").
      module Formats
        # The ffmpeg tag and the WAV chunk that hold the whole metadata.
        TAG = 'MB_SOUND_META'
        CHUNK = 'mbmt'

        # The MIDI text event prefix of the whole metadata.
        MIDI_PREFIX = 'mb-sound meta: '

        # The largest Ruby text written or read (bytes; a larger one is
        # left out with a warning when written, ignored when read).
        MAX_TEXT = 65_536

        # The vocabulary in ffmpeg's generic tag names (ffmpeg maps them to
        # each container's own: Vorbis comments, ID3 frames).
        FFMPEG_TAGS = { title: 'title', notes: 'comment', author: 'artist', license: 'copyright' }.freeze

        # The vocabulary in WAV LIST INFO ids.
        RIFF_INFO = { title: 'INAM', notes: 'ICMT', author: 'IART', license: 'ICOP', tags: 'IKEY' }.freeze

        # SoundFont INFO ids read as metadata (sf2 2.04, section 5).
        SF2_INFO = { title: 'INAM', notes: 'ICMT', author: 'IENG', license: 'ICOP' }.freeze

        # The sidecar of a file: `kick.wav.meta.rb`.
        SIDECAR = '.meta.rb'

        # The interpreter of the facts that describe a file for people and
        # agents (Facts.interpret): LIST INFO texts and the `mbmt` chunk, or
        # ffmpeg's title/comment/artist/copyright and MB_SOUND_META (and
        # source-meta-1's mb_sample_source), and sidecar keys; it makes
        # description (.from_riff, .from_tags), never data.
        class TextInterpreter
          include Facts::Interpreter

          def name = 'Meta::Formats'

          def consumes
            @consumes ||= [*RIFF_INFO.values.map { |id| "INFO.#{id}" }, CHUNK, *FFMPEG_TAGS.values.map { |t| "tag.#{t}" },
                           "tag.#{TAG.downcase}", 'tag.mb_sample_source', 'sidecar.*'].freeze
          end

          def interpret(facts)
            mine = facts.select { |f| consumes?(f.key) }
            info = mine.select { |f| f.key.start_with?('INFO.') }.to_h { |f| [f.key.delete_prefix('INFO.'), f.value] }
            text = mine.find { |f| f.key == CHUNK }&.value
            tags = mine.select { |f| f.key.start_with?('tag.') }.to_h { |f| [f.key.delete_prefix('tag.'), f.value] }
            side = mine.select { |f| f.key.start_with?('sidecar.') }.to_h { |f| [f.key.delete_prefix('sidecar.').to_sym, f.value] }
            desc = info.empty? && text.nil? ? Formats.from_tags(tags) : Formats.from_riff(info, text)
            desc = desc.merge(side) unless side.empty?
            Facts::Interpretation.new(interpreter: name, consumed: mine.map(&:key), description: desc)
          end
        end

        # The interpreter of descriptive facts (see TextInterpreter).
        TEXT = TextInterpreter.new

        module_function

        ### Writing

        # The native texts of +meta+ (a Value or Hash) by vocabulary key:
        # { title:, notes:, author:, license:, tags: } (Strings, nil when
        # absent).  +title+ stands in when the metadata has none (a Sample's
        # name).
        def native(meta, title: nil)
          m = Value.of(meta)
          t = m[:title]
          {
            title: (t.is_a?(String) || t.is_a?(Symbol) ? t.to_s : title&.to_s),
            notes: m.notes.empty? ? nil : m.notes.join("\n"),
            author: m.author&.to_s,
            license: m.license&.to_s,
            tags: m.tags.empty? ? nil : m.tags.map(&:to_s).join('; '),
          }.reject { |_, v| v.nil? || v.empty? }
        end

        # +meta+ as Ruby text (Value#to_ruby), or nil when it is empty or
        # longer than MAX_TEXT (with a warning naming +what+).
        def text(meta, what: 'metadata')
          m = Value.of(meta)
          return nil if m.empty?
          t = m.to_ruby
          return t if t.bytesize <= MAX_TEXT
          warn "#{what}: its metadata is #{Meta.bytes_text(t.bytesize)} as text, more than a file holds (#{Meta.bytes_text(MAX_TEXT)}); saved without it"
          nil
        end

        # ffmpeg metadata for +meta+ (MB::Sound.write's metadata:): the
        # vocabulary's tags and TAG with the whole Hash.
        def ffmpeg_tags(meta, title: nil, what: 'metadata')
          out = native(meta, title: title).except(:tags).to_h { |k, v| [FFMPEG_TAGS[k], v] }
          t = text(meta, what: what)
          out[TAG] = t if t
          out
        end

        # LIST INFO texts ({ 'INAM' => ..., ... }) for +meta+.
        def riff_info(meta, title: nil)
          native(meta, title: title).to_h { |k, v| [RIFF_INFO[k], v] }
        end

        # Adds +meta+ to the WAV (or RF64/BW64) file at +path+, which
        # mb-sound just wrote: a LIST INFO chunk with the vocabulary and an
        # `mbmt` chunk with the Ruby text, after the audio, with the RIFF
        # (or ds64) size updated.  Never used on files read from elsewhere.
        def append_wav(path, meta, title: nil, what: 'metadata')
          info = riff_info(meta, title: title)
          t = text(meta, what: what)
          chunks = []
          unless info.empty?
            body = 'INFO'.b
            info.each do |id, s|
              s = s.b + "\0".b
              body << id << [s.bytesize].pack('V') << s
              body << "\0".b if s.bytesize.odd?
            end
            chunks << ['LIST', body]
          end
          chunks << [CHUNK, t.b] if t
          return path if chunks.empty?

          riff = Sample::Riff.read!(path)
          bytes = chunks.map { |id, body| id.b + [body.bytesize].pack('V') + body + (body.bytesize.odd? ? "\0".b : ''.b) }.join
          File.open(path, 'r+b') do |f|
            size = f.size
            # (an odd-sized last chunk written without its pad byte gets one)
            last = riff.chunks.last
            if last && (last[1] + 8 + last[2]) == size && last[2].odd?
              f.seek(size)
              f.write("\0".b)
              size += 1
            end
            f.seek(size)
            f.write(bytes)
            total = size + bytes.bytesize - 8
            if riff.container == :riff
              raise ArgumentError, "#{path}: too large for metadata in a RIFF header" if total > 0xFFFFFFFF
              f.seek(4)
              f.write([total].pack('V'))
            else
              ds64 = riff.chunks.find { |id, _, _| id == 'ds64' } or raise ArgumentError, "#{path}: an RF64 file without a ds64 chunk"
              f.seek(ds64[1] + 8)
              f.write([total].pack('Q<'))
            end
          end
          path
        end

        # The MIDI meta events for +meta+ as [type, text] pairs (type 0x03
        # track name, 0x02 copyright, 0x01 text): the title as the track
        # name, the license, each note as a text event, then the whole
        # Hash as a text event starting with MIDI_PREFIX.  (mb-sound writes
        # no MIDI files yet; spec/support/midi_writer.rb writes these.)
        def midi_events(meta, title: nil, what: 'metadata')
          n = native(meta, title: title)
          out = []
          out << [0x03, n[:title]] if n[:title]
          out << [0x02, n[:license]] if n[:license]
          Value.of(meta).notes.each { |s| out << [0x01, s] }
          t = text(meta, what: what)
          out << [0x01, "#{MIDI_PREFIX}#{t}"] if t
          out
        end

        # The sidecar text for +meta+: one `meta` statement (Meta.statement),
        # with a comment line saying what it is.
        def sidecar_text(meta)
          m = Value.of(meta)
          ["# mb-sound metadata for the file beside it (plain values, read without running: MB::Sound::Meta::Formats.read_sidecar)",
           *Meta.statement(nil, m)].join("\n") + "\n"
        end

        # Writes +meta+ beside the file at +path+ (`path.meta.rb`; see
        # .sidecar_text), for files mb-sound doesn't write into.  Returns
        # the sidecar's path.
        def write_sidecar(path, meta)
          out = sidecar_path(path)
          File.write(out, sidecar_text(meta))
          out
        end

        ### Reading

        # The sidecar path of +path+.
        def sidecar_path(path) = "#{path}#{SIDECAR}"

        # The metadata of +path+'s sidecar (a Value), or nil when there is
        # none.  The sidecar passes GraphIO::FileGuard.sidecar (a regular
        # file, not a link, beside +path+, at most MAX_TEXT bytes); its one
        # `meta` statement is read from the syntax tree (Meta.literal), never
        # run.  A sidecar that breaks a rule is ignored with a warning.
        def read_sidecar(path)
          side = GraphIO::FileGuard.sidecar(sidecar_path(path.to_s)) or return nil
          # (a sidecar's facts, all of which the text interpreter describes)
          Facts.interpret(Facts.of_sidecar(parse_sidecar(File.read(side, encoding: 'UTF-8'), side)), TEXT).description
        rescue ArgumentError, SystemCallError => e
          warn "#{side || sidecar_path(path)}: metadata ignored (#{e.message})"
          nil
        end

        # The Value of sidecar text +src+ (see .read_sidecar).
        def parse_sidecar(src, label = 'sidecar')
          require 'prism'
          result = Prism.parse(src)
          raise ArgumentError, "#{label} doesn't parse as Ruby: #{result.errors.first.message}" unless result.errors.empty?
          body = result.value.statements.body
          call = body[0]
          unless body.length == 1 && call.is_a?(Prism::CallNode) && call.name == :meta && call.receiver.nil? && call.block.nil?
            raise ArgumentError, "#{label} holds one `meta` statement (meta notes: [\"...\"], source: { ... })"
          end
          args = call.arguments&.arguments || []
          h = {}
          args.each do |a|
            if a.is_a?(Prism::KeywordHashNode)
              a.elements.each do |el|
                raise ArgumentError, "#{label}: plain values only (no **)" unless el.is_a?(Prism::AssocNode)
                h[Meta.literal(el.key)] = Meta.literal(el.value)
              end
            else
              v = Meta.literal(a)
              raise ArgumentError, "#{label}: meta takes keywords or one Hash" unless v.is_a?(Hash)
              h.merge!(v)
            end
          end
          Value.of(h)
        end

        # The metadata ffmpeg tags +tags+ (a Hash, any key case) carry:
        # TAG's Ruby text, else the vocabulary from the native tags.  Text that isn't plain values is ignored (tags are data
        # from a file, never run).
        def from_tags(tags)
          by = tags.to_h { |k, v| [k.to_s.downcase, v] }
          h = {}
          FFMPEG_TAGS.each do |key, tag|
            v = by[tag]
            next if v.nil? || v.to_s.strip.empty?
            h[key] = key == :notes ? lines(v) : clean(v)
          end
          prefer(ruby_text(by[TAG.downcase]), h)
        end

        # The metadata of a WAV file's chunks: +info+ (Riff::Info#info, the
        # LIST INFO texts) and +text+ (its `mbmt` chunk): the Ruby text,
        # else the native texts.
        def from_riff(info, text)
          h = {}
          RIFF_INFO.each do |key, id|
            v = info[id]
            next if v.nil? || v.to_s.strip.empty?
            h[key] = case key
                     when :notes then lines(v)
                     when :tags then v.to_s.split(/\s*[;,]\s*/).reject(&:empty?).map { |s| clean(s) }
                     else clean(v)
                     end
          end
          prefer(ruby_text(text), h)
        end

        # The metadata of the WAV file at +path+ (+riff+: its Riff::Info if
        # already read), or EMPTY.
        def read_wav(path, riff = nil)
          riff ||= Sample::Riff.read(path)
          return EMPTY unless riff
          from_riff(riff.info, wav_text(path, riff))
        end

        # The `mbmt` chunk's text of the WAV file at +path+ (+riff+ its
        # Riff::Info), or nil.
        def wav_text(path, riff)
          row = riff.chunks.find { |id, _, _| id == CHUNK }
          return nil unless row && row[2] <= MAX_TEXT
          File.open(path, 'rb') { |f| f.pread(row[2], row[1] + 8) }
        end

        # The metadata of MIDI meta events: +events+ as [type, text] pairs
        # (type 0x03 track name, 0x02 copyright, 0x01 text, 0x06 marker;
        # markers with their times: [type, text, time] rows).  The first
        # track name is the title, copyright the license, other text events
        # notes, markers `markers: [[time, "text"], ...]`; a text event
        # starting with MIDI_PREFIX holds the whole Hash, read instead.
        def from_midi(events)
          h = {}
          ruby = nil
          notes = []
          markers = []
          events.each do |type, s, time|
            s = s.to_s.delete("\0")
            next if s.strip.empty?
            case type
            when 0x03 then h[:title] ||= clean(s)
            when 0x02 then h[:license] ||= clean(s)
            when 0x01
              if s.start_with?(MIDI_PREFIX)
                ruby = s.delete_prefix(MIDI_PREFIX)
              else
                notes << clean(s)
              end
            when 0x06 then markers << [time, clean(s)]
            end
          end
          h[:notes] = notes unless notes.empty?
          h[:markers] = markers unless markers.empty?
          prefer(ruby_text(ruby), h)
        end

        # The metadata of MIDI::MIDIFile +file+ (+track+: one track's index,
        # else the whole file's): its meta events' facts (Facts.of_midi of
        # MIDIFile#meta_events), the descriptive ones read by MIDI_TEXT
        # (.from_midi), the rest (instrument names, lyrics, cue points)
        # under `source: { fields: }`, and the file's sidecar over it all.
        def read_midi(file, track = nil)
          facts = Facts.of_midi(file.meta_events(track))
          r = Facts.interpret(facts, MIDI_TEXT)
          m = r.description
          if !r.consumed.any? { |k| k.include?('.text[') && facts[k].value.start_with?(MIDI_PREFIX) }
            src = { format: :mid, file: File.basename(file.filename.to_s), track: track }.compact
            fields = r.unconsumed.to_fields.first(64).to_h
            src[:fields] = fields unless fields.empty?
            m = m.merge(source: src) unless m.key?(:source)
          end
          side = read_sidecar(file.filename)
          side ? m.merge(side) : m
        end

        # The interpreter of a MIDI file's descriptive meta events: track
        # names (the first is the title), copyright, text, markers, and the
        # `mb-sound meta:` text (.from_midi).
        class MidiTextInterpreter
          include Facts::Interpreter

          def name = 'Meta::Formats (MIDI)'
          def consumes = ['track[*'].freeze
          def consumes?(key) = key.match?(/\Atrack\[\d+\]\.(name|copyright|text\[\d+\]|marker\[\d+\])\z/)

          def interpret(facts)
            mine = facts.select { |f| consumes?(f.key) }
            rows = mine.map do |f|
              case f.key
              when /\.name\z/ then [0x03, f.value]
              when /\.copyright\z/ then [0x02, f.value]
              when /\.marker\[/ then [0x06, f.value[1], f.value[0]]
              else [0x01, f.value]
              end
            end
            Facts::Interpretation.new(interpreter: name, consumed: mine.map(&:key), description: Formats.from_midi(rows))
          end
        end

        # The interpreter of a MIDI file's descriptive meta events.
        MIDI_TEXT = MidiTextInterpreter.new

        # The interpreter of a SoundFont's descriptive INFO texts
        # (.from_sf2).
        class Sf2TextInterpreter
          include Facts::Interpreter

          def name = 'Meta::Formats (SoundFont)'
          def consumes = @consumes ||= SF2_INFO.values.map { |id| "INFO.#{id}" }.freeze

          def interpret(facts)
            mine = facts.select { |f| consumes?(f.key) }
            info = mine.to_h { |f| [f.key.delete_prefix('INFO.'), f.value] }
            Facts::Interpretation.new(interpreter: name, consumed: mine.map(&:key), description: Formats.from_sf2(info))
          end
        end

        # The interpreter of a SoundFont's descriptive INFO texts.
        SF2_TEXT = Sf2TextInterpreter.new

        # The metadata of SoundFont INFO texts +info+ ({ 'INAM' => ..., ... }).
        def from_sf2(info)
          h = {}
          SF2_INFO.each do |key, id|
            v = info[id]
            next if v.nil? || v.to_s.strip.empty?
            h[key] = key == :notes ? lines(v) : clean(v)
          end
          native_value(h)
        end

        # (+v+ as metadata text: UTF-8, NULs and outer spaces removed)
        def clean(v)
          v.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?').delete("\0").strip.freeze
        end

        # (a comment as notes, one per line)
        def lines(v)
          clean(v).split(/\r?\n/).map(&:strip).reject(&:empty?)
        end

        # (the file's Ruby text when it has one: mb-sound wrote the native
        # tags from it, so it alone reads back exactly; else the native
        # texts +h+)
        def prefer(ruby, h)
          ruby.empty? ? native_value(h) : ruby
        end

        # (native texts as a Value, dropping what doesn't fit the vocabulary)
        def native_value(h)
          Value.of(h)
        rescue ArgumentError
          Value.of(h.slice(:title))
        end

        # (the Value of Ruby text from a file, or EMPTY for none or text that
        # isn't a Hash of plain values)
        def ruby_text(text)
          return EMPTY if text.nil? || text.to_s.strip.empty? || text.to_s.bytesize > MAX_TEXT
          Value.parse(text.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?'))
        rescue ArgumentError
          EMPTY
        end
      end
    end
  end
end

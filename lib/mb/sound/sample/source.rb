module MB
  module Sound
    class Sample
      # A Sample's carried metadata (source-meta-1; MB::Sound::Meta):
      # `sample.meta` holds what the library read from a loop file
      # (`:why`, `:smpl_loops`, see Sample#meta) and, beside those, plain
      # facts given with #with_meta, by convention where the sample came
      # from under `:source` (Meta::SOURCE_KEYS).
      #
      # A Sample read from a file brings the file's own `:source` (see
      # Source.of_file): its name and size, the rate it stores, and for a
      # WAV file the chunks Sample::Riff walked, where the audio sits, and
      # how many bytes sat in chunks mb-sound doesn't read.  Copies and
      # views (#with, #slice, #stretch, ...) keep the metadata; #save
      # keeps `:source` (a tag), so a sample saved into a bundle still
      # says where its audio came from.
      module Source
        # The tag source-meta-1's #save kept `meta[:source]` in (its Ruby
        # text), read from older files.  #save now writes the whole
        # metadata in the file's tags and as Ruby text (Meta::Formats:
        # MB_SOUND_META, a WAV's `mbmt` chunk).
        TAG = :"#{TAG_PREFIX}source"

        # Ogg file extensions (comments on the stream).
        OGG = %w[.ogg .oga .opus].freeze

        # The WAV chunks Sample::Riff reads ('strc' too once Riff reads
        # ACID's stretch markers); the others count as unread.
        READ_CHUNKS = ['fmt ', 'data', 'ds64', 'acid', 'smpl', 'cue ', 'LIST'].freeze

        # The most chunks listed (a file's first; `chunk_count` says how
        # many it has).
        CHUNKS_LISTED = 64

        # A copy with +values+ (a Hash, or keywords) merged into #meta by
        # top-level key (see Meta.merge; the library's own keys stay), e.g.
        # an importer's `source:`.
        #
        #     kick = Sample[data, name: 'kick'].with_meta(source: { format: :xm, kind: :sample, id: 4, at: 0x2a10, bytes: 9120 })
        #     kick.meta[:source][:id]            # => 4
        #     kick.reverse.meta[:source]         # views and edits keep it
        def with_meta(values = Meta::Carrier::NONE, **more)
          values = Meta::Carrier::NONE.equal?(values) ? more : Meta::Carrier.both(values, more)
          merged = meta.merge(values)
          with(meta: merged, lineage: [self, :with_meta, [], Meta.frozen(values)].freeze)
        end

        # A copy with one more note per argument (Strings) at the end of
        # `meta.notes` (Meta::Carrier#note), recorded in the lineage, so
        # documents print `Sample["x.wav"].note("...")`.
        def note(*texts)
          with(meta: meta.note(*texts), lineage: [self, :note, Meta.frozen(texts), {}].freeze)
        end

        class << self
          # Sample options +kw+ (as Sample.from_file gathered them) with
          # the file's metadata in their `meta:`: what the file carries
          # (.file_meta: a file saved by Sample#save brings back its whole
          # metadata), and a `:source` from .of_file when it brings none.
          # What the caller gave (`Sample[path, meta: { source: ... }]`)
          # wins.
          def add(kw, path, tags, found)
            given = Meta::Value.of(kw[:meta])
            file = file_meta(path, tags, found)
            src = given.key?(:source) || file.key?(:source) ? nil : (saved(tags) || of_file(path, found))
            # (the caller's keys first and winning, then the file's, then :source)
            meta = given.merge(file.to_h.reject { |k, _| given.key?(k) })
            meta = meta.merge(source: src) if src
            meta.empty? ? kw : kw.merge(meta: meta)
          end

          # The metadata the file at +path+ carries (Meta::Formats): its
          # native tags and Ruby text (a WAV's LIST INFO and `mbmt` chunk,
          # else +tags+, ffmpeg's), with its sidecar's over them.
          def file_meta(path, tags, found)
            wav = %w[.wav .wave .bwf .rf64].include?(File.extname(path).downcase)
            riff = found[:riff] || (Riff.read(path) if wav)
            if !riff && OGG.include?(File.extname(path).downcase) && tags.keys.none? { |k| k.to_s.casecmp?(Meta::Formats::TAG) }
              # (Ogg keeps its comments on the stream, which ffmpeg's
              # format tags leave out)
              tags = ((FFMPEGInput.parse_info(path).dig(:streams, 0, :tags) rescue nil) || {}).merge(tags)
            end
            m = riff ? Meta::Formats.read_wav(path, riff) : Meta::Formats.from_tags(tags)
            side = Meta::Formats.read_sidecar(path)
            side ? m.merge(side) : m
          end

          # The `:source` in a saved file's +tags+ (see TAG), or nil (also
          # for text that isn't plain values: tags are data, never run).
          def saved(tags)
            text = tags.find { |k, _| k.to_s.downcase == TAG.to_s }&.last
            return nil if text.nil? || text.to_s.empty?
            v = Meta.parse(text.to_s)
            v.is_a?(Hash) ? Meta.frozen(Meta.check(v, [:source])) : nil
          rescue ArgumentError
            nil
          end

          # The `:source` of the sound file at +path+ from what reading it
          # already found (+found+: the LoopInfo Entry under :entry and a
          # WAV's Riff::Info under :riff; nothing is read again): `format`,
          # `file` (the name, no folders), `bytes` (the file's size),
          # `sample_rate` (as stored), and for a WAV `container`,
          # `channels`, `bits`, `frames`, `data: { at:, bytes: }` (where the
          # audio sits), `chunks` ([id, offset, size] rows, sizes as
          # declared), `chunk_count`, `skipped` (ids of chunks mb-sound
          # doesn't read), and `unread` (their bytes, headers included).
          def of_file(path, found = {})
            entry = found[:entry]
            riff = found[:riff]
            ext = File.extname(path).delete_prefix('.').downcase
            format = riff ? :wav : (entry && entry.format != :other ? entry.format : (ext.empty? ? nil : ext.to_sym))
            src = { format: format, file: File.basename(path), bytes: File.size(path) }.compact
            rate = riff&.sample_rate || entry&.sample_rate
            src[:sample_rate] = rate if rate.is_a?(Integer) && rate > 0
            if riff
              src[:container] = riff.container
              src[:channels] = riff.channels if riff.channels
              src[:bits] = riff.format.bits if riff.format
              src[:frames] = riff.frames if riff.frames
              src[:data] = { at: riff.data_offset, bytes: riff.data_size } if riff.data_offset
              read = READ_CHUNKS + (riff.respond_to?(:strc) ? ['strc'] : [])
              rows = riff.chunks
              skipped = rows.reject { |id, _, _| read.include?(id) }
              src[:chunks] = rows.first(CHUNKS_LISTED).map { |id, at, size| [id, at, size] }
              src[:chunk_count] = rows.length
              src[:skipped] = skipped.map(&:first).uniq
              src[:unread] = skipped.sum { |_, at, size| [size + 8, src[:bytes] - at].min.clamp(0, nil) }
            end
            Meta.frozen(src)
          rescue SystemCallError
            nil
          end
        end
      end

      include Meta::Carrier
      prepend Source
    end
  end
end

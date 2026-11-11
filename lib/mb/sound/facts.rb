module MB
  module Sound
    # The raw layer of reading a file (metadata-2, round 2; the maintainer,
    # 2026-11-11: "Can there be a layered process where a raw file reader
    # only produces metadata, and then the layer above that converts some
    # to data, etc.?"):
    #
    # 1. A reader produces Facts: everything the file says, each with where
    #    it sits (record, byte offset, size), no opinion, frozen.
    # 2. Interpreters consume chosen facts into typed data (a Sample's
    #    loop, tempo, root, one-shot call; a clip's events; a document's
    #    rack constructor), each declaring the facts it may read
    #    (Interpreter#consumes) and reporting those it used, with a
    #    Provenance per data field.
    # 3. Whatever no interpreter consumed becomes description: the
    #    object's `meta[:source][:fields]` (fact key => value), next to
    #    what the reader didn't parse at all (`skipped`, `unread`).
    #
    #     facts = MB::Sound::Facts.of_riff(Sample::Riff.read('loop.wav'))
    #     facts['acid.tempo']            # => #<data Fact key="acid.tempo", value=120.0, record="acid", at=36, bytes=24>
    #     result = Facts.interpret(facts, Sample::LoopInfo::Interpreter.new(entry), Meta::Formats::WAV_TEXT)
    #     result.consumed                # => ["acid.tempo", "acid.flags", ...]
    #     result.unconsumed.to_fields    # => { "INFO.ISFT" => "Lavf61", "smpl.loop[1]" => [...] }
    #
    # Facts are read only by interpreters (meta_guard_spec.rb's raw layer):
    # typed data goes anywhere; description and provenance only to
    # printers and writers.  Fact keys and records name the format's own
    # words (`acid`, `smpl`, `INFO`, `track[2]`): format names stay at the
    # edges, in readers, interpreters, and provenance (format_words_spec.rb).
    class Facts
      include Enumerable

      # One fact: +key+ (a String: "acid.tempo", "INFO.ICMT",
      # "track[2].name", "graph.rack"), +value+ (plain Ruby, Meta's value
      # rule), +record+ (the chunk, block, track, or line it sits in),
      # +at+ (its byte offset in the file, or nil), +bytes+ (its size, or
      # nil).
      Fact = Data.define(:key, :value, :record, :at, :bytes) do
        def initialize(key:, value:, record: nil, at: nil, bytes: nil)
          super(key: key.to_s.freeze, value: Meta.frozen(value), record: record&.to_s&.freeze, at: at, bytes: bytes)
        end

        def to_s = "#{key} = #{RubyValue.to_ruby(value)}#{" (#{record}#{" at 0x#{at.to_s(16)}" if at})" if record}"
      end

      # What one interpreter made of facts: +interpreter+ (its name, a
      # String), +data+ ({ field => value }: typed data), +consumed+ (the
      # fact keys it used), +provenance+ ({ field => Provenance }), and
      # +description+ (a Meta::Value it made of facts that describe, e.g.
      # a file's title and comment).
      Interpretation = Data.define(:interpreter, :data, :consumed, :provenance, :description) do
        def initialize(interpreter:, data: {}, consumed: [], provenance: {}, description: Meta::EMPTY)
          super(interpreter: interpreter.to_s.freeze, data: data.freeze, consumed: consumed.map(&:to_s).uniq.freeze,
                provenance: provenance.freeze, description: Meta::Value.of(description))
        end
      end

      # What every interpreter made of facts (see Facts.interpret): the
      # interpretations, the fact keys consumed, the facts nobody consumed,
      # and the provenance and description of all.
      Result = Data.define(:facts, :interpretations, :consumed, :unconsumed) do
        def provenance = interpretations.map(&:provenance).reduce({}, :merge)
        def description = interpretations.map(&:description).reduce(Meta::EMPTY) { |a, d| a.merge(d) }
        def data = interpretations.map(&:data).reduce({}, :merge)
      end

      # An interpreter's contract: #name (a String for provenance),
      # #consumes (key patterns it may read: "acid.*", "INFO.ICMT"), and
      # #interpret(facts) returning an Interpretation whose consumed keys
      # it may read.  Facts.interpret checks the last.
      module Interpreter
        # True if +key+ is one this interpreter may read.
        def consumes?(key)
          Facts.match?(consumes, key)
        end
      end

      # An interpreter that consumes every present fact matching its
      # patterns, making no data of them (a Sample's audio decoded by
      # ffmpeg consumes its format and data facts).
      class Consumer
        include Interpreter

        attr_reader :name, :consumes

        def initialize(name, consumes)
          @name = name.to_s.freeze
          @consumes = consumes.freeze
          freeze
        end

        def interpret(facts)
          Interpretation.new(interpreter: @name, consumed: facts.select { |f| consumes?(f.key) }.map(&:key))
        end
      end

      class << self
        # True if +key+ matches one of +patterns+ ("acid.*" matches every
        # key starting "acid.", "INFO.ICMT" only itself).
        def match?(patterns, key)
          patterns.any? { |p| p.end_with?('*') ? key.start_with?(p.chomp('*')) : key == p }
        end

        # Runs +interpreters+ over +facts+: each interprets, and the facts
        # none consumed are the Result's +unconsumed+ (description).  Raises
        # ArgumentError when an interpreter reports a fact outside its
        # #consumes (an interpreter reading what it didn't declare).
        def interpret(facts, *interpreters)
          list = interpreters.compact.map do |i|
            r = i.interpret(facts)
            stray = r.consumed.reject { |k| i.consumes?(k) }
            raise ArgumentError, "#{r.interpreter} consumed #{stray.join(', ')}, which it doesn't declare (#consumes)" unless stray.empty?
            r
          end
          consumed = list.flat_map(&:consumed).uniq.freeze
          Result.new(facts: facts, interpretations: list.freeze, consumed: consumed, unconsumed: facts.reject_keys(consumed))
        end

        ### Readers: the raw layer of each format

        # The facts of a WAV file's chunks (+riff+: a Sample::Riff::Info;
        # +text+: its `mbmt` chunk's text if read): the format (`fmt.*`),
        # the audio (`data.bytes`), ACID's chunk (`acid.flags`,
        # `acid.root_note`, `acid.beats`, `acid.meter`, `acid.tempo`), the
        # sampler chunk (`smpl.unity_note`, `smpl.pitch_fraction`,
        # `smpl.loop[i]` as [start, stop, type]), cue points
        # (`cue.point[i]` as [position, label or nil]), LIST INFO texts
        # (`INFO.<id>`), the `mbmt` chunk, ACID's stretch markers
        # (`strc.count`, `strc.settings`, and `strc.entry[i]` as [flags,
        # position, pin, value] in file order, listed after the other
        # chunks' facts), and every other chunk by id (`chunk.<id>` as
        # [offset, size]).
        def of_riff(riff, text: nil)
          return new(format: :wav) unless riff
          at = ->(id) { riff.chunks.find { |c, _, _| c == id } }
          out = []
          out << Fact.new(key: 'riff.container', value: riff.container, record: 'RIFF', at: 0, bytes: 12)
          if (f = riff.format) && (c = at.('fmt '))
            { tag: f.tag, channels: f.channels, sample_rate: f.sample_rate, bits: f.bits, block_align: f.block_align }.each do |k, v|
              out << Fact.new(key: "fmt.#{k}", value: v, record: 'fmt ', at: c[1], bytes: c[2]) unless v.nil?
            end
          end
          out << Fact.new(key: 'data.bytes', value: riff.data_size, record: 'data', at: riff.data_offset, bytes: riff.data_size) if riff.data_offset
          if (a = riff.acid) && (c = at.('acid'))
            { flags: a.flags, root_note: a.root, beats: a.beats, meter: a.meter, tempo: a.tempo.finite? ? a.tempo.to_f : nil }.each do |k, v|
              out << Fact.new(key: "acid.#{k}", value: v, record: 'acid', at: c[1], bytes: c[2]) unless v.nil?
            end
          end
          if (s = riff.smpl) && (c = at.('smpl'))
            out << Fact.new(key: 'smpl.unity_note', value: s.unity_note, record: 'smpl', at: c[1], bytes: c[2])
            out << Fact.new(key: 'smpl.pitch_fraction', value: s.pitch_fraction, record: 'smpl', at: c[1], bytes: c[2])
            s.loops.each_with_index do |lp, i|
              out << Fact.new(key: "smpl.loop[#{i}]", value: [lp.start, lp.stop, lp.type], record: 'smpl', at: c[1] + 44 + 24 * i, bytes: 24)
            end
          end
          if (c = at.('cue '))
            riff.cues.each_with_index do |cue, i|
              out << Fact.new(key: "cue.point[#{i}]", value: [cue.position, cue.label], record: 'cue ', at: c[1], bytes: c[2])
            end
          end
          list = riff.chunks.select { |id, _, _| id == 'LIST' }
          riff.info.each do |id, t|
            out << Fact.new(key: "INFO.#{id}", value: t.to_s, record: 'LIST INFO', at: list.last&.[](1))
          end
          if (c = at.(Meta::Formats::CHUNK)) && text
            out << Fact.new(key: Meta::Formats::CHUNK, value: text.to_s, record: Meta::Formats::CHUNK, at: c[1], bytes: c[2])
          end
          known = ['fmt ', 'data', 'acid', 'smpl', 'cue ', 'LIST', Meta::Formats::CHUNK, 'ds64']
          marks = riff.strc && at.('strc')
          known << 'strc' if marks
          riff.chunks.each do |id, off, size|
            next if known.include?(id)
            out << Fact.new(key: "chunk.#{id}", value: [off, size], record: id, at: off, bytes: size)
          end
          if marks
            # (the entries last: a chunk nothing used lists up to hundreds,
            # and a description keeps a file's first facts)
            s = riff.strc
            out << Fact.new(key: 'strc.count', value: s.count, record: 'strc', at: marks[1], bytes: marks[2])
            out << Fact.new(key: 'strc.settings', value: s.settings, record: 'strc', at: marks[1], bytes: marks[2])
            s.entries.each_with_index do |e, i|
              out << Fact.new(key: "strc.entry[#{i}]", value: [e.flags, e.position, e.pin, e.value], record: 'strc', at: marks[1] + 8 + 28 + 32 * i, bytes: 32)
            end
          end
          new(format: riff.container == :riff ? :wav : riff.container, facts: out)
        end

        # The facts of a file's ffmpeg tags (+tags+: a Hash, any key case):
        # `tag.<name>` (lowercase).
        def of_tags(tags, format: nil)
          new(format: format, facts: tags.map { |k, v| Fact.new(key: "tag.#{k.to_s.downcase}", value: v.to_s, record: 'tags') })
        end

        # The facts of a MIDI file's meta events (+rows+: MIDIFile#meta_events
        # rows of [type, text, seconds, track]): per track `track[i].name`,
        # `track[i].copyright`, `track[i].text[n]`, `track[i].marker[n]` as
        # [seconds, text], `track[i].instrument`, `track[i].lyric[n]`,
        # `track[i].cue[n]`.
        def of_midi(rows, format: :mid)
          counts = Hash.new(0)
          out = rows.filter_map do |type, text, seconds, track|
            name = MIDI_TYPES[type] or next
            base = "track[#{track || 0}].#{name}"
            key = %w[name copyright instrument].include?(name) ? base : "#{base}[#{(counts[base] += 1) - 1}]"
            value = name == 'marker' ? [seconds, text.to_s] : text.to_s
            Fact.new(key: key, value: value, record: "track #{track || 0}")
          end
          new(format: format, facts: out)
        end

        # MIDI meta event types the facts name.
        MIDI_TYPES = { 0x01 => 'text', 0x02 => 'copyright', 0x03 => 'name', 0x04 => 'instrument', 0x05 => 'lyric', 0x06 => 'marker', 0x07 => 'cue' }.freeze

        # The facts of a SoundFont's INFO list (+info+: { 'INAM' => ... })
        # and version (+version+: [major, minor]).
        def of_sf2(info, version: nil)
          out = info.map { |id, t| Fact.new(key: "INFO.#{id}", value: t.to_s, record: 'INFO') }
          out << Fact.new(key: 'INFO.ifil', value: version.join('.'), record: 'INFO') if version
          new(format: :sf2, facts: out)
        end

        # The facts of a sidecar's `meta` statement (+value+: its Hash):
        # `sidecar.<key>`.
        def of_sidecar(value)
          new(format: :sidecar, facts: value.to_h.map { |k, v| Fact.new(key: "sidecar.#{k}", value: v, record: 'meta') })
        end

        # The facts of a graph document's `graph` line (+kwargs+, the
        # keywords as read; +offsets+: { key => byte offset }):
        # `graph.<key>`.
        def of_graph_line(kwargs, offsets: {})
          new(format: :mbg, facts: kwargs.map { |k, v| Fact.new(key: "graph.#{k}", value: v, record: 'graph line', at: offsets[k]) })
        end
      end

      # The format (a Symbol, e.g. :wav), and the facts by key.
      attr_reader :format

      def initialize(format: nil, facts: [])
        @format = format
        @by = facts.to_h { |f| [f.key, f] }.freeze
        freeze
      end

      # The Fact of +key+, or nil.
      def [](key) = @by[key.to_s]

      def key?(key) = @by.key?(key.to_s)
      def keys = @by.keys
      def size = @by.size
      def empty? = @by.empty?

      # Yields each Fact.
      def each(&block)
        return enum_for(:each) { size } unless block
        @by.each_value(&block)
        self
      end

      # The facts whose keys match +patterns+ (see Facts.match?).
      def select_keys(*patterns)
        Facts.new(format: @format, facts: @by.values.select { |f| Facts.match?(patterns, f.key) })
      end

      # The facts without +keys+.
      def reject_keys(keys)
        Facts.new(format: @format, facts: @by.values.reject { |f| keys.include?(f.key) })
      end

      # The facts as description: { key => value } (meta[:source][:fields]).
      def to_fields = @by.transform_values(&:value)

      def inspect = "#<MB::Sound::Facts #{@format} #{keys.first(8).join(', ')}#{" +#{size - 8}" if size > 8}>"
      alias to_s inspect
    end
  end
end

require_relative 'provenance'

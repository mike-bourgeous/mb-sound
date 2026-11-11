module MB
  module Sound
    # Where a typed data field came from (metadata-2, round 2: "D,
    # provenance on data"): +field+ (the data field, e.g. :bpm), +via+ (a
    # short word for its source: :acid, :smpl, :cue, :tags, :name,
    # :length, :decay, :detected, :saved, :header, ...), +fact+ (the
    # Facts key it came from, or nil), +format+ (the file format), +record+
    # (the chunk, block, track, or line), +at+ (the byte offset, or nil),
    # +interpreter+ (what turned the fact into data), and +why+ (in words).
    #
    #     sample.provenance(:bpm)   # => #<data Provenance field=:bpm, via=:acid, fact="acid.tempo", record="acid", at=36, ...>
    #     sample.why(:one_shot)     # => "acid chunk: the one-shot flag"
    #
    # Provenance is description: printers and writers read it (summaries,
    # the inspector, listings); behavior never does (meta_guard_spec.rb).
    # Format names belong here (`via: :acid`, `record: "acid"`): the edges
    # of the app, where the library's own vocabulary is general (loop,
    # one-shot, beats, root, stretch markers).
    Provenance = Data.define(:field, :via, :fact, :format, :record, :at, :interpreter, :why) do
      def initialize(field:, via: nil, fact: nil, format: nil, record: nil, at: nil, interpreter: nil, why: nil)
        super(field: field.to_sym, via: via&.to_sym, fact: fact&.to_s&.freeze, format: format&.to_sym, record: record&.to_s&.freeze,
              at: at, interpreter: interpreter&.to_s&.freeze, why: why&.to_s&.freeze)
      end

      # One line for listings, with text from files quoted (Meta.quote):
      # 'bpm: acid "acid.tempo" (wav acid chunk at 0x24, Sample::LoopInfo): "ACID tempo"'.
      def to_s
        where = [format, record && "#{record.strip}#{' chunk' if record.length == 4 && format == :wav}", at && "at 0x#{at.to_s(16)}"].compact.join(' ')
        parts = ["#{field}:", via&.to_s, fact && Meta.quote(fact)].compact.join(' ')
        detail = [where.empty? ? nil : where, interpreter].compact.join(', ')
        "#{parts}#{" (#{detail})" unless detail.empty?}#{": #{Meta.quote(why)}" if why}"
      end
    end

    # (constants defined in Data.define's block would land in MB::Sound)
    class Provenance
      # Lines for a set of provenance ({ field => Provenance }), one per
      # field.
      def self.lines(provenance)
        provenance.values.map(&:to_s)
      end

      # Gives +obj+ (an object with Readers) the provenance +fields+ ({
      # field => Provenance }), for importers that build objects (a MIDI
      # file's clips).  Returns +obj+.
      def self.attach(obj, fields)
        obj.instance_variable_set(:@provenance, fields.empty? ? nil : fields.freeze)
        obj
      end

      # Readers for objects that carry provenance in @provenance ({ field
      # => Provenance }, frozen; nil when there is none).
      module Readers
        # The Provenance of +field+, or the whole Hash with no field (empty
        # when there is none).
        def provenance(field = nil)
          all = @provenance || EMPTY
          field.nil? ? all : all[field.to_sym]
        end

        # Why +field+ is what it is, in words, or nil.
        def why(field)
          provenance(field)&.why
        end
      end

      EMPTY = {}.freeze
    end
  end
end
